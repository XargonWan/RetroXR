#!/usr/bin/env python3
"""Build every RetroVR GDExtension for one platform, in one command.

    python Tools/build.py windows
    python Tools/build.py android --target release
    python Tools/build.py linux --only vlc-godot

Four extensions live in this workspace and each needs its OWN scons invocation:
they share the `godot-cpp` submodule, and godot-cpp's SConstruct can only be run
once per process, so a single scons run cannot cover two of them. Each also has
its own `VariantDir('Temp')`, which is why each builds from its own directory —
except libretro-godot, whose SConstruct is the workspace root's.

Asking for `linux` from Windows re-invokes this script inside WSL. Asking for it
from Linux just builds. (Replaces the old Tools/build_linux.sh, which did the
WSL half by hand for one extension.)
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# name, directory scons runs in (relative to REPO), where the artifacts land.
# Order matters only for readability of the log; there are no interdependencies.
EXTENSIONS = [
    ("libretro-godot", ".", "RetroVR/libretro-godot"),
    ("verlet-rope", "verlet-rope", "RetroVR/verlet-rope"),
    ("vlc-godot", "vlc-godot", "RetroVR/vlc-godot"),
    ("godot-pdfium", "godot-pdfium", "RetroVR/godot-pdfium"),
    ("metaxr-audio", "metaxr-audio-godot", "RetroVR/metaxr-audio"),
]

ARCH = {"windows": "x86_64", "linux": "x86_64", "android": "arm64"}

TARGETS = {"debug": ["template_debug"],
           "release": ["template_release"],
           "both": ["template_debug", "template_release"]}

# Only used when scons isn't already on PATH — pip --user installs land here and
# Windows does not add that Scripts dir to PATH by default.
WINDOWS_SCONS_FALLBACKS = [
    Path(os.environ.get("APPDATA", "")) / "Python/Python314/Scripts/scons.exe",
    Path.home() / "AppData/Roaming/Python/Python314/Scripts/scons.exe",
]

DEFAULT_NDK = "C:/android/android-ndk-r27d"
DEFAULT_DISTRO = "Ubuntu"


def find_scons() -> str:
    found = shutil.which("scons")
    if found:
        return found
    if sys.platform == "win32":
        for p in WINDOWS_SCONS_FALLBACKS:
            if p.is_file():
                return str(p)
    sys.exit(
        "scons not found on PATH.\n"
        "  Windows: pip install --user scons\n"
        "  Linux:   pip install --user scons   (then ensure ~/.local/bin is on PATH)"
    )


def build_env(platform: str, ndk: str) -> dict[str, str]:
    env = os.environ.copy()
    if platform != "android":
        return env
    if not Path(ndk).is_dir():
        sys.exit(f"android: NDK not found at {ndk} (pass --ndk)")
    env["ANDROID_NDK_ROOT"] = ndk
    # Deliberately EMPTY, not unset. godot-cpp prefers ANDROID_HOME when it is
    # set and then wants a full SDK; blanking it forces the NDK path instead.
    env["ANDROID_HOME"] = ""
    return env


def run_one(name: str, subdir: str, platform: str, arch: str, target: str,
            scons: str, env: dict[str, str], jobs: int, extra: list[str]) -> tuple[bool, float]:
    cwd = REPO / subdir
    cmd = [scons, f"platform={platform}", f"arch={arch}", f"target={target}", f"-j{jobs}"]
    if platform == "android":
        cmd.append("ANDROID_HOME=")
    cmd += extra
    print(f"\n=== {name}  [{platform} {arch} {target}] ===", flush=True)
    print(f"    {cwd}$ {' '.join(cmd)}", flush=True)
    t0 = time.monotonic()
    rc = subprocess.run(cmd, cwd=cwd, env=env).returncode
    return rc == 0, time.monotonic() - t0


def to_wsl_path(p: Path) -> str:
    """C:\\Users\\x\\repo -> /mnt/c/Users/x/repo"""
    s = str(p).replace("\\", "/")
    if len(s) > 1 and s[1] == ":":
        return f"/mnt/{s[0].lower()}{s[2:]}"
    return s


def dispatch_to_wsl(argv: list[str], distro: str) -> int:
    """Re-run this script inside WSL.

    WSL inherits the Windows environment, so HOME and PATH both arrive wrong —
    the inherited PATH contains spaces and Windows directories, which breaks a
    bare `export PATH="$HOME/.local/bin:$PATH"`. Reset both. HOME is read from
    passwd rather than hardcoded so this doesn't assume a username.
    """
    if not shutil.which("wsl"):
        sys.exit("linux builds from Windows need WSL, which was not found on PATH.")
    inner = (
        'export HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"; '
        'export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; '
        f'cd "{to_wsl_path(REPO)}" || exit 1; '
        f'exec python3 Tools/build.py {" ".join(argv)}'
    )
    print(f"[build] host is Windows; dispatching linux build into WSL ({distro})", flush=True)
    return subprocess.run(["wsl", "-d", distro, "--", "bash", "-c", inner]).returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("platform", choices=["windows", "linux", "android"])
    ap.add_argument("--target", choices=list(TARGETS), default="both",
                    help="which build target(s) to produce (default: both)")
    ap.add_argument("--arch", help="override the per-platform default")
    ap.add_argument("--only", help="comma-separated subset of: "
                                   + ", ".join(n for n, _, _ in EXTENSIONS))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_ROOT") or DEFAULT_NDK)
    ap.add_argument("--distro", default=DEFAULT_DISTRO, help="WSL distro for linux-from-Windows")
    ap.add_argument("scons_args", nargs="*", help="extra args passed through to scons")
    args = ap.parse_args()

    # linux asked for from Windows -> hand the whole thing to WSL and stop here.
    if args.platform == "linux" and sys.platform == "win32":
        passthrough = [a for a in sys.argv[1:] if not a.startswith("--distro")]
        return dispatch_to_wsl(passthrough, args.distro)

    if args.platform == "windows" and sys.platform != "win32":
        sys.exit("windows builds need MSVC; run this from Windows.")

    exts = EXTENSIONS
    if args.only:
        wanted = {s.strip() for s in args.only.split(",")}
        known = {n for n, _, _ in EXTENSIONS}
        if unknown := wanted - known:
            sys.exit(f"unknown extension(s): {', '.join(sorted(unknown))}")
        exts = [e for e in EXTENSIONS if e[0] in wanted]

    arch = args.arch or ARCH[args.platform]
    scons = find_scons()
    env = build_env(args.platform, args.ndk)

    print(f"[build] {args.platform}/{arch}  targets={','.join(TARGETS[args.target])}  "
          f"jobs={args.jobs}\n[build] scons: {scons}")

    results: list[tuple[str, str, bool, float]] = []
    for target in TARGETS[args.target]:
        for name, subdir, _out in exts:
            ok, secs = run_one(name, subdir, args.platform, arch, target,
                               scons, env, args.jobs, args.scons_args)
            results.append((name, target, ok, secs))

    print("\n" + "=" * 62)
    for name, target, ok, secs in results:
        print(f"  {'OK  ' if ok else 'FAIL'}  {name:<16} {target:<18} {secs:6.1f}s")
    failed = [f"{n} ({t})" for n, t, ok, _ in results if not ok]
    if failed:
        print(f"\n{len(failed)} of {len(results)} builds FAILED: {', '.join(failed)}")
        return 1
    print(f"\nall {len(results)} builds OK -> RetroVR/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
