#!/usr/bin/env python3
"""Build the signed Quest APK (arm64) from this checkout, in one command.

    python Tools/build_apk.py --side          # the test build (debug key, com.xenu.retroxr.side)
    python Tools/build_apk.py                 # the official signing
    python Tools/build_apk.py --steps export,check           # reuse a finished build
    python Tools/build_apk.py --java /usr/lib/sdk/openjdk17 --ndk ~/Downloads/android-ndk-r27d

No argument is needed for the toolchain or the secrets: everything below is looked for, and the
JDK and the NDK are downloaded into build_out/_sdk/ when the machine has none.

The same steps the `quest` job in `release.yml` runs, so a local APK is the one CI would sign:

  build     the arm64 GDExtensions, template_release (Tools/build.py android), and the
            Linux debug ones the editor loads so it knows the classes its scripts name
  import    Godot imports the project and fails on any script or shader error
  template  the Android build template under RetroXR/android/build, with the gradle lines CI
            adds, then the patched engine placed into it (Tools/place_engine.py)
  export    the "Quest" preset -> build_out/RetroXR-v<version>.apk, signed with the keystore
  check     aapt2 reads the versionCode/versionName back, and the natives must be present

Signing: the keystore is the one the workflow uses. The three values come, in this order, from
$GODOT_ANDROID_KEYSTORE_RELEASE_{PATH,USER,PASSWORD}; then from the gitignored files beside the
checkout (or beside the MAIN checkout, from a worktree): `retroxr-release.keystore` and
`retroxr-release.keystore.password`, the repository's secrets pasted as `NAME` / value pairs
(ANDROID_KEYSTORE_USER, ANDROID_KEYSTORE_PASSWORD, and ANDROID_KEYSTORE_BASE64 when the keystore
file itself is absent: it is then written, 0600, to the cache). The keystore is opened once with the
JDK's keytool before anything is built, so a wrong password fails in a second and not after the C++.

Java: Godot 4.7 reads the JDK from the EDITOR settings (`export/android/java_sdk_path`),
not from $JAVA_HOME, and a headless export refuses without it. The script writes the JDK path
there (and the Android SDK path, if empty) in $XDG_CONFIG_HOME/godot/, once. The JDK is --java,
$JAVA_HOME, the `java` on PATH, /usr/lib/jvm or /usr/lib/sdk, build_out/_sdk/jdk17, in that order,
and only a 17 counts; none -> Temurin 17 is downloaded (sha256 from Adoptium's API).

NDK: --ndk, $ANDROID_NDK_ROOT / $ANDROID_NDK_HOME, the SDK's ndk/ folder, ~/Downloads, then
build_out/_sdk/android-ndk-r27d; none -> r27d is downloaded (sha1 from Google's repository xml).

Output: build_out/RetroXR-v<version>.apk (build_out/ is gitignored).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import platform
import re
import shutil
import hashlib
import subprocess
import sys
import tarfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from contextlib import contextmanager
from pathlib import Path

import build_appimage  # beside this script: the Linux link workarounds (libstdc++, libvlc)

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "RetroXR"
BUILD_OUT = REPO / "build_out"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "retroxr-apk"
TEMPLATES = Path.home() / ".local/share/godot/export_templates"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
EDITOR_SETTINGS = CONFIG / "godot/editor_settings-4.7.tres"
KEYSTORE_DEFAULT = REPO / "retroxr-release.keystore"
DEBUG_KEYSTORE = Path.home() / ".android/debug.keystore"
SIDE_PACKAGE = "com.xenu.retroxr.side"
PRESET = "Quest"
TOOLCHAIN = BUILD_OUT / "_sdk"     # what this script downloads (build_out/ is gitignored)
JDK_MAJOR = 17
NDK_NAME = "android-ndk-r27d"
NDK_REPO = "https://dl.google.com/android/repository/"
ADOPTIUM = ("https://api.adoptium.net/v3/assets/latest/%d/hotspot"
            "?architecture=x64&image_type=jdk&os=linux&vendor=eclipse" % JDK_MAJOR)
STEPS = ("build", "import", "template", "export", "check")

# The natives the APK must carry, as release.yml's "Check the APK" step lists them.
NATIVES = ("liblibretro_godot", "libarchive_godot", "libverlet_rope", "libvlc_godot",
           "libgodot-pdfium", "libmetaxr-audio", "libgodotopenxrvendors", "libvlc.so",
           "libpdfium.so", "libMetaXRAudioUnity.so")

# What the import pass may print without it being our change (the same list as CI).
IMPORT_NOISE = ("xrCreateInstance", ".NET Sdk", "xr_staging_shim")
IMPORT_ERRORS = re.compile(
    r"SCRIPT ERROR|Parse Error|SHADER ERROR|Failed to load|Failed to instantiate")

# The gradle lines CI appends to the template so a stalled gradle is visible in the log.
GRADLE_PROPS = ("org.gradle.daemon=false", "org.gradle.console=plain")


def say(msg: str) -> None:
    print(f"[apk] {msg}", flush=True)


def die(msg: str) -> "None":
    print(f"[apk] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd: list[str], *, cwd: Path = REPO, env: dict | None = None,
        log: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    """Run a command, streaming to `log` when given (the import pass is very chatty)."""
    say("$ " + " ".join(str(c) for c in cmd))
    full_env = dict(os.environ, **(env or {}))
    # scons is installed with `pip install --user` / `uv tool install`, which put it in
    # ~/.local/bin: not always on PATH, and Tools/build.py wants it there.
    local_bin = str(Path.home() / ".local/bin")
    if local_bin not in full_env.get("PATH", "").split(os.pathsep):
        full_env["PATH"] = local_bin + os.pathsep + full_env.get("PATH", "")
    if log is not None:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("wb") as fh:
            proc = subprocess.run(cmd, cwd=cwd, env=full_env, stdout=fh,
                                  stderr=subprocess.STDOUT)
    else:
        proc = subprocess.run(cmd, cwd=cwd, env=full_env)
    if check and proc.returncode != 0:
        die(f"command failed (exit {proc.returncode}): {' '.join(str(c) for c in cmd)}"
            + (f"\n       log: {log}" if log else ""))
    return proc


# ── preconditions ───────────────────────────────────────────────────────────────

def find_godot(explicit: str | None) -> str:
    if explicit:
        if not Path(explicit).exists():
            die(f"--godot: no such file: {explicit}")
        return explicit
    env = os.environ.get("GODOT")
    if env and Path(env).exists():
        return env
    home = Path.home()
    candidates: list[Path] = []
    for folder in (home / "Godot", home / "Applications", home / ".local/bin"):
        if folder.is_dir():
            candidates += sorted(folder.glob("Godot_v4.7*linux*x86_64"), reverse=True)
    found = shutil.which("godot") or shutil.which("godot4")
    if found:
        candidates.append(Path(found))
    for c in candidates:
        if c.is_file():
            return str(c)
    die("could not find Godot 4.7. Pass --godot <path> or set $GODOT.")


def fetch(url: str, timeout: int):
    """urlopen with a plain client name (Adoptium answers urllib's default one with a 403)."""
    return urllib.request.urlopen(
        urllib.request.Request(url, headers={"User-Agent": "build-apk/1.0"}), timeout=timeout)


def download(url: str, dest: Path, algo: str, want: str) -> None:
    """Fetch `url` to `dest`, checked against the publisher's checksum, through a .part file
    so a dropped connection never leaves something that looks finished."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    say(f"downloading {url}")
    digest = hashlib.new(algo)
    try:
        with fetch(url, 60) as resp, part.open("wb") as fh:
            total = int(resp.headers.get("Content-Length") or 0)
            done, shown = 0, time.time()
            while chunk := resp.read(1 << 20):
                fh.write(chunk)
                digest.update(chunk)
                done += len(chunk)
                if time.time() - shown > 5:
                    shown = time.time()
                    say(f"  {done / 2**20:.0f} / {total / 2**20:.0f} MB")
    except OSError as e:
        part.unlink(missing_ok=True)
        die(f"download failed ({e}): {url}\n       no network? pass --java / --ndk instead")
    if digest.hexdigest() != want:
        part.unlink(missing_ok=True)
        die(f"{algo} of {url} is {digest.hexdigest()}, the publisher lists {want}")
    part.replace(dest)


def jdk_major(home: Path) -> int | None:
    """The JDK's major version from its `release` file (None when it has none)."""
    try:
        m = re.search(r'^JAVA_VERSION="(\d+)', (home / "release").read_text(), re.M)
    except OSError:
        return None
    return int(m.group(1)) if m else None


def jdk_candidates() -> list[Path]:
    found: list[Path] = []
    if os.environ.get("JAVA_HOME"):
        found.append(Path(os.environ["JAVA_HOME"]))
    for tool in ("keytool", "java"):
        on_path = shutil.which(tool)
        if on_path:
            found.append(Path(on_path).resolve().parent.parent)
    for folder in ("/usr/lib/jvm", "/usr/lib/sdk"):
        if Path(folder).is_dir():
            found += sorted(p for p in Path(folder).iterdir() if "17" in p.name)
    found.append(TOOLCHAIN / "jdk17")
    return found


def find_java(explicit: str | None) -> Path:
    if explicit:
        home = Path(explicit).expanduser().resolve()
        if not (home / "bin/keytool").is_file():
            die(f"--java {explicit}: no bin/keytool there (give the JDK home)")
        return home
    for home in jdk_candidates():
        if (home / "bin/keytool").is_file() and jdk_major(home) == JDK_MAJOR:
            say(f"JDK {JDK_MAJOR}: {home}")
            # Absolute: it is written into Godot's editor settings, and Godot resolves it
            # from its own working directory (a relative path was "Missing 'bin' directory").
            return home.resolve()
    return fetch_jdk()


def fetch_jdk() -> Path:
    say(f"no JDK {JDK_MAJOR} on this machine: fetching Temurin into {TOOLCHAIN / 'jdk17'}")
    try:
        with fetch(ADOPTIUM, 30) as resp:
            pkg = json.load(resp)[0]["binary"]["package"]
    except (OSError, ValueError, KeyError, IndexError) as e:
        die(f"could not ask Adoptium for a JDK {JDK_MAJOR} ({e}); pass --java <JDK home>")
    archive = TOOLCHAIN / pkg["name"]
    download(pkg["link"], archive, "sha256", pkg["checksum"])
    staging = TOOLCHAIN / "_jdk_unpack"
    shutil.rmtree(staging, ignore_errors=True)
    with tarfile.open(archive) as tar:
        tar.extractall(staging, filter="data")
    roots = [p for p in staging.iterdir() if (p / "bin/keytool").is_file()]
    if not roots:
        die(f"{archive} holds no JDK (no bin/keytool)")
    home = TOOLCHAIN / "jdk17"
    shutil.rmtree(home, ignore_errors=True)
    roots[0].replace(home)
    shutil.rmtree(staging, ignore_errors=True)
    archive.unlink(missing_ok=True)
    return home.resolve()


def find_sdk() -> Path:
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(var) and Path(os.environ[var]).is_dir():
            return Path(os.environ[var])
    sdk = Path.home() / "Android/Sdk"
    if sdk.is_dir():
        return sdk
    die("no Android SDK: set $ANDROID_HOME")


def is_ndk(path: Path) -> bool:
    return (path / "source.properties").is_file() and (path / "toolchains").is_dir()


def find_ndk(explicit: str | None, sdk: Path) -> str:
    if explicit:
        if not is_ndk(Path(explicit).expanduser()):
            die(f"--ndk {explicit}: not an NDK (no source.properties)")
        return str(Path(explicit).expanduser().resolve())
    candidates = [Path(os.environ[v]) for v in ("ANDROID_NDK_ROOT", "ANDROID_NDK_HOME")
                  if os.environ.get(v)]
    # r27 only: the build is measured with it, and a newer NDK has changed its clang before.
    candidates += sorted((sdk / "ndk").glob("27.*"), reverse=True)
    candidates += [Path.home() / "Downloads" / NDK_NAME, TOOLCHAIN / NDK_NAME]
    for c in candidates:
        if is_ndk(c):
            say(f"NDK: {c}")
            return str(c.resolve())
    return fetch_ndk()


def fetch_ndk() -> str:
    say(f"no NDK on this machine: fetching {NDK_NAME} into {TOOLCHAIN / NDK_NAME}")
    archive_name = f"{NDK_NAME}-linux.zip"
    try:
        with fetch(NDK_REPO + "repository2-3.xml", 60) as resp:
            tree = ET.parse(resp)
    except (OSError, ET.ParseError) as e:
        die(f"could not read Google's repository list ({e}); pass --ndk <path>")
    sha1 = None
    for arc in tree.iter("archive"):
        if (arc.findtext("complete/url") or "") == archive_name:
            sha1 = arc.find("complete/checksum").text.strip()
    if not sha1:
        die(f"{archive_name} is not in Google's repository list; pass --ndk <path>")
    archive = TOOLCHAIN / archive_name
    download(NDK_REPO + archive_name, archive, "sha1", sha1)
    staging = TOOLCHAIN / "_ndk_unpack"
    shutil.rmtree(staging, ignore_errors=True)
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            target = Path(z.extract(info, staging))
            mode = info.external_attr >> 16        # zipfile drops the unix mode: clang needs it
            if mode and not info.is_dir():
                target.chmod(mode & 0o777)
    roots = [p for p in staging.iterdir() if is_ndk(p)]
    if not roots:
        die(f"{archive} holds no NDK")
    home = TOOLCHAIN / NDK_NAME
    shutil.rmtree(home, ignore_errors=True)
    roots[0].replace(home)
    shutil.rmtree(staging, ignore_errors=True)
    archive.unlink(missing_ok=True)
    return str(home.resolve())


def check_templates(godot: str) -> Path:
    """The template folder of THIS binary's version (4.7.2.stable, not the newest 4.7*)."""
    text = subprocess.run([godot, "--version"], capture_output=True, text=True).stdout
    m = re.match(r"(\d+\.\d+(?:\.\d+)?\.\w+)", text.strip())
    if not m:
        die(f"could not read the version of {godot}: {text.strip()!r}")
    folder = TEMPLATES / m.group(1)
    if not (folder / "android_source.zip").is_file():
        die(f"no export templates for Godot {m.group(1)} under {TEMPLATES}; install them "
            f"from the editor (Editor > Manage Export Templates) before exporting")
    return folder


def secret_dirs() -> list[Path]:
    """This checkout, then the MAIN one when this is a worktree (the secrets are gitignored,
    so a worktree never has them)."""
    dirs = [REPO]
    common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            cwd=REPO, capture_output=True, text=True).stdout.strip()
    if common and Path(common).parent != REPO:
        dirs.append(Path(common).parent)
    return dirs


def read_secrets() -> dict[str, str]:
    """`retroxr-release.keystore.password`: the repository secrets as NAME line, value line,
    blank line (the file is gitignored; nothing in it is ever printed)."""
    for folder in secret_dirs():
        f = folder / "retroxr-release.keystore.password"
        if f.is_file():
            lines = [ln.strip() for ln in f.read_text().splitlines()]
            found = {k: v for k, v in zip(lines, lines[1:])
                     if re.fullmatch(r"ANDROID_KEYSTORE_[A-Z0-9_]+", k) and v}
            say(f"signing secrets: {f} ({', '.join(sorted(found)) or 'nothing usable'})")
            return found
    return {}


def find_release_keystore(secrets: dict[str, str]) -> str:
    if os.environ.get("GODOT_ANDROID_KEYSTORE_RELEASE_PATH"):
        return os.environ["GODOT_ANDROID_KEYSTORE_RELEASE_PATH"]
    for folder in secret_dirs():
        if (folder / "retroxr-release.keystore").is_file():
            return str(folder / "retroxr-release.keystore")
    if secrets.get("ANDROID_KEYSTORE_BASE64"):
        path = CACHE / "release.keystore"
        CACHE.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600)
        path.write_bytes(base64.b64decode(secrets["ANDROID_KEYSTORE_BASE64"]))
        say(f"keystore decoded from ANDROID_KEYSTORE_BASE64 to {path}")
        return str(path)
    die("no release keystore: put retroxr-release.keystore (or the .password file with "
        "ANDROID_KEYSTORE_BASE64) beside the checkout, or set $GODOT_ANDROID_KEYSTORE_RELEASE_PATH")


def ensure_debug_keystore(java: Path) -> None:
    """The `.side` build's key. Android Studio makes it; with none, make the standard one."""
    if DEBUG_KEYSTORE.is_file():
        return
    say(f"no {DEBUG_KEYSTORE}: creating the standard Android debug key")
    DEBUG_KEYSTORE.parent.mkdir(parents=True, exist_ok=True)
    run([str(java / "bin/keytool"), "-genkeypair", "-keystore", str(DEBUG_KEYSTORE),
         "-alias", "androiddebugkey", "-storepass", "android", "-keypass", "android",
         "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
         "-dname", "CN=Android Debug,O=Android,C=US"])


def keystore_env(java: Path, side: bool) -> dict[str, str]:
    """The three variables Godot signs with, checked against the keystore itself. The
    `.side` test build signs with the Android debug key, as the installed one was signed."""
    if side:
        ensure_debug_keystore(java)
        path = str(DEBUG_KEYSTORE)
        user, password = "androiddebugkey", "android"
    else:
        secrets = read_secrets()
        path = find_release_keystore(secrets)
        user = (os.environ.get("GODOT_ANDROID_KEYSTORE_RELEASE_USER")
                or secrets.get("ANDROID_KEYSTORE_USER"))
        password = (os.environ.get("GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD")
                    or secrets.get("ANDROID_KEYSTORE_PASSWORD"))
    if not Path(path).is_file():
        die(f"no keystore at {path} (set $GODOT_ANDROID_KEYSTORE_RELEASE_PATH)")
    if not user or not password:
        die("no alias/password for the keystore: set GODOT_ANDROID_KEYSTORE_RELEASE_USER and "
            "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD, or fill ANDROID_KEYSTORE_USER / "
            "ANDROID_KEYSTORE_PASSWORD in retroxr-release.keystore.password")
    # keytool's `:env` form keeps the password out of the process list.
    listed = subprocess.run(
        [str(java / "bin/keytool"), "-list", "-keystore", path, "-alias", user,
         "-storepass:env", "KEYSTORE_PASSWORD"],
        env=dict(os.environ, KEYSTORE_PASSWORD=password), capture_output=True, text=True)
    if listed.returncode != 0:
        die(f"keytool could not open alias '{user}' in {path} with that password: "
            f"{listed.stderr.strip() or listed.stdout.strip()}")
    say(f"signing with {path} (alias {user})")
    return {
        "GODOT_ANDROID_KEYSTORE_RELEASE_PATH": path,
        "GODOT_ANDROID_KEYSTORE_RELEASE_USER": user,
        "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD": password,
    }


def ensure_editor_java(java: Path, sdk: Path) -> None:
    """Godot reads the JDK and SDK from the editor settings; set them once, if blank."""
    if not EDITOR_SETTINGS.is_file():
        die(f"no Godot 4.7 editor settings at {EDITOR_SETTINGS}: open the editor once")
    text = EDITOR_SETTINGS.read_text()
    wanted = {"export/android/java_sdk_path": str(java),
              "export/android/android_sdk_path": str(sdk)}
    for key, value in wanted.items():
        line = f'{key} = "{value}"'
        if line in text:
            continue
        pattern = re.compile(rf'^{re.escape(key)} = ".*"$', re.MULTILINE)
        if not pattern.search(text):
            die(f"{EDITOR_SETTINGS} has no `{key}` line to set")
        text = pattern.sub(line, text, count=1)
        say(f"set {key} in the editor settings")
    EDITOR_SETTINGS.write_text(text)


# ── build ───────────────────────────────────────────────────────────────────────

def step_build(jobs: int, ndk: str) -> None:
    base = [sys.executable, str(REPO / "Tools/build.py")]
    run(base + ["android", "--target", "release", "--ndk", ndk, "--jobs", str(jobs)])
    # The editor cannot register the classes its scripts name without host-side builds
    # (metaxr-audio has none on Linux, and build.py skips it there with a note).
    # A distro without the static libstdc++ or the libvlc development link (Fedora) fails every
    # one of them at the link, and the import then reports hundreds of unknown classes:
    # build_appimage.py already works around both, and these are the same builds.
    linux = base + ["linux", "--target", "debug", "--jobs", str(jobs)]
    if not build_appimage.has_static_libstdcxx():
        say("no static libstdc++ here: linking dynamically (use_static_cpp=no)")
        linux += ["--", "use_static_cpp=no"]
    if build_appimage.libvlc_dev_present():
        run(linux, check=False)
        return
    stub = build_appimage.make_vlc_stub()
    if stub is None:
        say("WARNING: no libvlc development link (install vlc-devel); vlc-godot will fail to link")
        run(linux, check=False)
        return
    with build_appimage.VlcLinkPatch(stub):
        run(linux, check=False)


# ── import / template / export ──────────────────────────────────────────────────

def step_import(godot: str) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    base = [godot, "--headless", "--path", str(PROJECT)]
    # See release.yml: `--import` is the only mode that waits for the scan, and only the
    # last --editor pass is an oracle for script errors.
    run(base + ["--import"], log=CACHE / "import.log", check=False)
    run(base + ["--editor", "--quit"], log=CACHE / "editor1.log", check=False)
    run(base + ["--editor", "--quit"], log=CACHE / "editor2.log", check=False)
    text = (CACHE / "editor2.log").read_text(errors="replace")
    errors = [ln for ln in text.splitlines()
              if IMPORT_ERRORS.search(ln) and not any(n in ln for n in IMPORT_NOISE)]
    if errors:
        print("\n".join(errors[:25]))
        die(f"the import reported {len(errors)} script/shader error(s) "
            f"(full log: {CACHE / 'editor2.log'})")
    say("import clean")


def step_template(godot: str, templates: Path) -> None:
    # Always a fresh template, as CI has one: an export over the last run's res/ fails in
    # the resource merger (Godot leaves .webp.import sidecars there). Generated, gitignored.
    build = PROJECT / "android/build"
    shutil.rmtree(build, ignore_errors=True)
    if not (build / "build.gradle").is_file():
        # The CLI install usually does nothing and segfaults on exit; the zip is the real
        # path, the same one release.yml unpacks when the CLI leaves nothing behind.
        run([godot, "--headless", "--path", str(PROJECT),
             "--install-android-build-template", "--quit"],
            log=CACHE / "template.log", check=False)
    if not (build / "build.gradle").is_file():
        say(f"unpacking {templates.name}/android_source.zip into {build}")
        build.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(templates / "android_source.zip") as z:
            z.extractall(build)
        (PROJECT / "android/.build_version").write_text(templates.name + "\n")
    # Godot's own installer writes this; the zip path above does not. Without it the editor
    # scans the gradle output as part of the project (every .gdextension it staged, with no
    # .so beside it) and the next Linux import/export fails on them.
    (build / ".gdignore").touch()
    # zipfile drops the unix mode, and Godot runs gradlew directly ("Permesso negato").
    gradlew = build / "gradlew"
    if gradlew.is_file() and not os.access(gradlew, os.X_OK):
        gradlew.chmod(0o755)
    # A cached gradle dir can re-serve a stale .gdc; the assets staging dirs are never
    # worth keeping between runs.
    for stale in ("src/main/assets", "build/intermediates/assets"):
        shutil.rmtree(build / stale, ignore_errors=True)
    props = build / "gradle.properties"
    text = props.read_text() if props.is_file() else ""
    missing = [p for p in GRADLE_PROPS if p not in text.splitlines()]
    if missing:
        props.write_text(text + "".join(p + "\n" for p in missing))
    # The patched engine must be in the template, or the APK runs stock (and deadlocks on
    # the loading screen). Never `--restore` the template to tidy up after a probe.
    run([sys.executable, str(REPO / "Tools/place_engine.py"), "--target", "release"])


def quest_options(text: str) -> re.Match:
    """The [preset.N.options] section of the Quest preset. Godot writes each preset as two
    sections: [preset.N] holds the name, and [preset.N.options] holds the package and the
    version."""
    index = None
    for sect in re.finditer(r"^\[preset\.(\d+)\]\n(.*?)(?=^\[|\Z)", text, re.M | re.S):
        if re.search(rf'^name="{PRESET}"$', sect.group(2), re.M):
            index = sect.group(1)
    if index is None:
        die(f"no export preset named {PRESET!r} in RetroXR/export_presets.cfg")
    options = re.search(rf"^\[preset\.{index}\.options\]\n(.*?)(?=^\[|\Z)", text,
                        re.M | re.S)
    if options is None:
        die(f"preset {PRESET!r} has no options section")
    return options


def preset_version() -> str:
    m = re.search(r'^version/name="([^"]+)"', quest_options(
        (PROJECT / "export_presets.cfg").read_text()).group(1), re.M)
    if not m:
        die(f"preset {PRESET!r} has no version/name")
    return m.group(1)


@contextmanager
def side_package(enabled: bool):
    """The `.side` test build: the Quest preset exports as com.xenu.retroxr.side for the
    length of the run, then the file is put back, even when a step fails. (The official
    com.xenu.retroxr holds the player's data and must never be overwritten by a test.)"""
    cfg = PROJECT / "export_presets.cfg"
    if not enabled:
        yield
        return
    original = cfg.read_text()
    options = quest_options(original)
    block = re.sub(r'^package/unique_name=".*"$', f'package/unique_name="{SIDE_PACKAGE}"',
                   options.group(0), count=1, flags=re.M)
    cfg.write_text(original[:options.start()] + block + original[options.end():])
    say(f"exporting as {SIDE_PACKAGE} (export_presets.cfg restored after)")
    try:
        yield
    finally:
        cfg.write_text(original)


def step_export(godot: str, out: Path, env: dict[str, str]) -> None:
    BUILD_OUT.mkdir(exist_ok=True)
    if out.exists():
        out.unlink()
    run([godot, "--headless", "--path", str(PROJECT), "--export-release", PRESET, str(out)],
        env=env, log=CACHE / "export.log")
    if not out.is_file() or out.stat().st_size < 100 * 2**20:
        die(f"the export did not produce a usable {out.name} (log: {CACHE / 'export.log'})")
    say(f"exported {out} ({out.stat().st_size / 2**20:.0f} MB)")


# ── check ───────────────────────────────────────────────────────────────────────

def step_check(apk: Path, sdk: Path, want_name: str, want_package: str) -> None:
    if not apk.is_file():
        die(f"{apk} is missing: run the export step first")
    aapt2s = sorted((sdk / "build-tools").glob("*/aapt2"))
    if not aapt2s:
        die(f"no aapt2 under {sdk / 'build-tools'}")
    badging = subprocess.run([str(aapt2s[-1]), "dump", "badging", str(apk)],
                             capture_output=True, text=True).stdout
    package = re.search(r"package: name='([^']*)'", badging)
    if not package or package.group(1) != want_package:
        die(f"package {package and package.group(1)} != {want_package}")
    name = re.search(r"versionName='([^']*)'", badging)
    code = re.search(r"versionCode='([0-9]+)'", badging)
    say(f"apk: versionCode={code and code.group(1)} versionName={name and name.group(1)}")
    if not name or name.group(1) != want_name:
        die(f"versionName {name and name.group(1)} != preset {want_name}")
    with zipfile.ZipFile(apk) as z:
        entries = z.namelist()
    missing = [n for n in NATIVES if f"lib/arm64-v8a/{n}" not in entries
               and not any(e.startswith(f"lib/arm64-v8a/{n}") for e in entries)]
    if missing:
        die("the APK is missing native(s): " + ", ".join(missing))
    say(f"all {len(NATIVES)} expected natives present")


# ── main ────────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="Build the signed Quest APK (arm64).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--steps", default=",".join(STEPS),
                    help=f"comma list of {', '.join(STEPS)} (default: all)")
    ap.add_argument("--godot", help="Godot 4.7 binary (default: $GODOT, then ~/Godot, "
                                    "~/Applications, PATH)")
    ap.add_argument("--ndk", help="Android NDK r27d (default: found, else downloaded to "
                                  "build_out/_sdk)")
    ap.add_argument("--java", help="JDK 17 home holding bin/keytool (default: found, else "
                                   "downloaded to build_out/_sdk)")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2),
                    help="parallel compile jobs for the C++ (default: half the cores)")
    ap.add_argument("--side", action="store_true",
                    help=f"the test build: package {SIDE_PACKAGE}, debug-key signed, so it "
                         f"installs over the last .side build (never over the official app)")
    args = ap.parse_args()

    steps = [s.strip() for s in args.steps.split(",") if s.strip()]
    bad = [s for s in steps if s not in STEPS]
    if bad:
        die(f"unknown step(s): {', '.join(bad)} (known: {', '.join(STEPS)})")
    if platform.system() != "Linux":
        die("this builds the APK on Linux; on Windows use the quest job in release.yml")

    started = time.time()
    version = preset_version()
    out = BUILD_OUT / (f"RetroXR-v{version}-side.apk" if args.side else f"RetroXR-v{version}.apk")
    package = SIDE_PACKAGE if args.side else "com.xenu.retroxr"
    needs_godot = any(s in steps for s in ("import", "template", "export"))
    godot = find_godot(args.godot) if needs_godot else ""
    # keytool is also what checks the keystore, so an export needs the JDK too.
    java = find_java(args.java) if needs_godot or "export" in steps else Path()
    sdk = find_sdk()
    if needs_godot:
        say(f"Godot: {godot}")
        ensure_editor_java(java, sdk)
    env = keystore_env(java, args.side) if "export" in steps else {}

    if "build" in steps:
        step_build(args.jobs, find_ndk(args.ndk, sdk))
    if "import" in steps:
        step_import(godot)
    if "template" in steps:
        step_template(godot, check_templates(godot))
    if "export" in steps:
        check_templates(godot)
        with side_package(args.side):
            step_export(godot, out, env)
    if "check" in steps:
        step_check(out, sdk, version, package)
    say(f"done in {time.time() - started:.0f} s" + (f": {out}" if out.is_file() else ""))


if __name__ == "__main__":
    main()
