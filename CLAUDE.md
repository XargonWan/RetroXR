# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RetroXR is a VR retro-gaming room in Godot 4.7. Its core is `libretro-godot`, a GDExtension (C++, submodule, forked from SKurdt's SK.Libretro.Godot) that runs libretro emulator cores inside Godot and bridges Godot's scene system to the libretro API.

The app is `RetroXR`, package `com.xenu.retroxr`. The Godot project folder is `RetroXR/`,
and the desktop data root stays `~/retroxr/{roms,books,videos,…}` — it holds user ROMs, so
it is deliberately not renamed.

The Godot project in this repo:
- `RetroXR/` — VR arcade room (primary development target, godot-xr-tools based)

## Git Workflow

**Commit directly to `master` unless the user says otherwise.** This is a solo repo —
do not branch-per-feature by default; commit and (when asked) push straight to `master`.
Branch only when the user explicitly requests it.

## Build Commands

Requires SCons and MSVC (Windows), GCC/Clang (Linux), Xcode command-line tools (macOS),
or Android NDK (Android). The godot-cpp submodule must be initialized first:
```bash
git submodule update --init --recursive
```

### One command for every extension

`Tools/build.py` builds all six GDExtensions for one platform, sequentially (they
cannot share a scons invocation — see below). Prefer it over the per-extension
recipes further down, which are kept because they document each build's quirks.

```bash
python Tools/build.py windows              # both template_debug and template_release
python Tools/build.py android --target release
python Tools/build.py linux --only vlc-godot
python Tools/build.py macos                    # host architecture, macOS 13.0 minimum
python Tools/build.py macos --arch x86_64      # Intel Mac binaries
python Tools/build.py windows --jobs 8 -- verbose=yes    # extra args go to scons
```

Asking for `linux` **from Windows** re-invokes the script inside WSL (`--distro`,
default `Ubuntu`), resetting HOME and PATH — WSL inherits the Windows environment,
whose PATH contains spaces and breaks a bare `export PATH="$HOME/.local/bin:$PATH"`.
Asking for it from Linux just builds. This replaced `Tools/build_linux.sh`.
It reports a per-extension pass/fail table and exits non-zero if anything failed.

**Not all six ship everywhere.** `metaxr-audio` is windows/android only — it wraps
Meta's `MetaXRAudioUnity` blob, which Meta publishes for win-x64 and android-arm64
alone, and `metaxr_audio.gdextension` has no Linux or macOS entry. The C++ compiles for
Linux perfectly well (the loader just finds nothing and `is_available()` returns
false), so the skip is a shipping decision, not a compile failure. A whole-platform
run skips it with a note; `--only metaxr-audio` on Linux or macOS is an error.
`vlc-godot` is also skipped on macOS because no redistributable libVLC runtime/plugin
tree is vendored yet.

**scons is not installed system-wide in either WSL distro** (`Ubuntu` has g++ but no
scons; `FedoraLinux-44` has neither on PATH). Install it into the distro first.
On the native CachyOS box there is no `pip` on PATH at all (Python 3.14, externally
managed) — `uv tool install scons` is the one that works there, and it lands in
`~/.local/bin` just the same.

Build from the **workspace root** (not `-C Temp`):
```bash
# Windows (PowerShell)
$scons = "$env:APPDATA\Python\Python314\Scripts\scons.exe"   # pip install --user scons
& $scons platform=windows arch=x86_64 target=template_debug dev_build=yes
& $scons platform=windows arch=x86_64 target=template_release

# Android / Quest (bash — requires ANDROID_NDK_ROOT)
ANDROID_NDK_ROOT="C:/android/android-ndk-r27d" ANDROID_HOME="" \
  scons platform=android arch=arm64 target=template_debug ANDROID_HOME=""

# Linux desktop x86_64 (bash — GCC/Clang; SCons via `uv tool install scons`)
scons platform=linux arch=x86_64 target=template_debug
scons platform=linux arch=x86_64 target=template_release

# macOS (build arm64 and x86_64 separately; PDFium requires macOS 13.0)
scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
scons platform=macos arch=x86_64 target=template_release macos_deployment_target=13.0
```

The `SConstruct` is at the workspace root; `Temp/SConscript` does the actual build logic.
Output libraries go to `RetroXR/libretro-godot/`.

The Linux build links `libvulkan.so.1`, `libSDL3.so.0`, and `libGL.so.1` by soname (no
`-dev`/`-devel` packages needed). All three render paths work on Linux: software, Vulkan
HW-render, and OpenGL HW-render (SDL3-created hidden GL window — needs a display server at
runtime). Desktop Linux support was added 2026-07-13 (Windows x86_64 + Android arm64 were
the original targets).

Linux build internals worth knowing: SCons isn't system-wide here — it's `pip install
--user scons` (lands in `~/.local/bin`, so prefix commands with `PATH="$HOME/.local/bin:$PATH"`).
`CallbackTrampolines.cpp` has a dedicated `EmitTrampolineSysV` (x86-64 System V ABI:
RDI/RSI/RDX/RCX/R8/R9 + XMM0-7 + AL) — the Windows `EmitTrampolineX64` uses the wrong ABI, so
Linux/Windows/Android each need their own trampoline. GDScript platform logic used to be
"Android-vs-else(=Windows)"; several files (`core_download_manager.gd`, `download_manifest.gd`,
`spawn_menu.gd`, `rom_library.gd`) were made explicitly Linux-aware (buildbot URL
`nightly/linux/x86_64/latest/`, `.so` ext, `$HOME/retroxr/...` roots). Runtime emulation of a
real core on Linux is only lightly verified — build + extension-load + type-resolution are proven.

The macOS libretro build currently supports software-rendered cores only: Vulkan needs
MoltenVK and the OpenGL path needs a packaged SDL3 runtime. Core downloads use libretro's
`nightly/apple/osx/<arch>/latest/` dylibs, and desktop data remains under `~/retroxr`.
Both extension architectures target macOS 13.0. An official arm64 2048 core was exercised
for 168 frames in a three-second runtime probe; VLC, Meta XR Audio and a signed/notarized
macOS export preset remain future packaging work.

A hardened Mac export will need library validation disabled for downloaded unsigned cores
and unsigned executable memory for callback trampolines; dynarec cores may also need the
JIT entitlement.

### Sibling GDExtensions (archive-godot, verlet-rope, vlc-godot, godot-pdfium, metaxr-audio)

Five other C++ GDExtensions live beside libretro-godot, each with the same layout (repo-root
`<name>/` with `SConstruct` + `src/`, reusing `../libretro-godot/godot-cpp`, deploying to
`RetroXR/<name>/`). Build each **from its own directory** (each has its own `VariantDir('Temp')`),
or all at once with `Tools/build.py`:

- **archive-godot** — `RommArchiveExtractor`, a bounded-memory ZIP reader used by RomM
  downloads. It streams archive members directly to temporary files, validates their sizes
  and CRCs, then promotes them into place. It is pure godot-cpp and deliberately separate
  from the libretro emulator bridge.
  ```bash
  cd archive-godot && scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```

- **verlet-rope** — `Xenu::VerletRope`, the simulated cable hanging off every controller and
  A/V plug. Lived inside `libretro-godot` until 2026-08-02 and was moved out (and purged from
  that submodule's history) because it never belonged there: it includes nothing from libretro
  and libretro includes nothing from it. Pure godot-cpp, no third-party dependency, so it is
  one of the simplest extensions to build.
  ```bash
  cd verlet-rope && scons platform=windows arch=x86_64 target=template_debug
  cd verlet-rope && scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```

- **vlc-godot** — libVLC-backed `VlcPlayer`, used by both the DVD player **and** the VHS/VCR
  (the old `eirteam.ffmpeg` addon was dropped 2026-07-14 — libVLC is the single video backend;
  it also handles x265/HEVC, which eirteam.ffmpeg did not).
  ```bash
  cd vlc-godot
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_debug
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_release
  ```
  Linux links the system `libvlc` (Fedora `vlc-devel` provides `/lib64/libvlc.so` + headers;
  runtime needs `vlc-libs`). HEVC works out of the box via VLC's system plugin dir — no plugin
  bundling on Linux. Output: `RetroXR/vlc-godot/libvlc_godot.linux.template_{debug,release}.x86_64.so`.

- **godot-pdfium** — `PDFRenderer` (opens a PDF, renders a page to a Godot `Image`), backed by
  the bblanchon/pdfium-binaries `libpdfium`. Every platform's prebuilt is committed, so a fresh
  clone needs no fetch; `Tools/download_pdfium.sh` refreshes them when you do (it replaced the
  PowerShell script, which only knew win-x64 + android-arm64):
  ```bash
  Tools/download_pdfium.sh -p linux     # just this platform's lib; include/ untouched
  Tools/download_pdfium.sh -p mac       # macOS arm64 (`mac-x64` for Intel)
  cd godot-pdfium
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_debug
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_release
  scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```
  On macOS, the two runtime dylibs coexist under `mac-arm64/` and `mac-x64/`; each extension
  uses an architecture-specific `@loader_path` load command. **Linux rpath gotcha:** the
  shipped `libpdfium.so` shares its SONAME with the Android arm64 copy
  that sits in the output-dir root (tracked in git, referenced by the android `[dependencies]`
  block). An x86_64 lib with the same name would clobber it and break Quest exports, so the
  Linux lib installs to a `linux-x64/` **subdir** and the SConscript adds
  `LINKFLAGS=["-Wl,-R,'$$ORIGIN/linux-x64'"]` (quote exactly like godot-cpp's `tools/linux.py` —
  an unquoted `$$ORIGIN` collapses to a bare `/linux-x64` under this SCons). godot-cpp already
  injects a bare `$ORIGIN` entry, so final RUNPATH is `$ORIGIN:$ORIGIN/linux-x64`; the loader
  skips the arch-mismatched arm64 lib and falls through to the x86_64 subdir. Verify with
  `objdump -p …so | grep RUNPATH` and `ldd …so | grep pdfium` (must resolve, not "not found").
  Added 2026-07-15.

## Headless Testing & Validation

There is no formal test framework. The project is validated by running the Godot editor
**headless** for compile/scene checks, plus small throwaway "probe" scenes for functional
tests. This works without a VR headset (desktop fallback) and without a display.

**`RetroXR/Tests/` is the exception, and the bar for living there is exact:** a scene
that checks itself, runs unattended with no ROM, core, headset or device, and **exits
non-zero on failure**, so it can gate a commit. Four so far — the A/V suite in §2c, the
RomM and scene-management ones below, and `system_tests` over the machine controller's
port, pad, save and disc rules. Everything else is a probe and stays in `RetroXR/Tools/`, including
the ones that assert: they want real cores and ROMs (`azahar_probe`, `sram_probe`,
`vb_probe`, `nds_probe`, `handheld_probe`, `gl_video_probe`), a headset or a Quest
(`netplay_spike`), or they are reproductions of open bugs and report failures BY DESIGN
(`three_plug_probe`). Moving one of those into `Tests/` would make a red run meaningless.

`RetroXR/Tests/romm_tests.tscn` asserts the pure-logic half of the RomM stack — pair-QR
parsing, slug mapping and systemid collision, the sync fingerprint, cache path safety,
and the `scan_roms` disk walk. No server, no headset, no network, ~2 s.
```bash
"$godot" --headless --path RetroXR res://Tests/romm_tests.tscn 2>&1 | grep -a "\[test\]"
```
Every case in it is a bug that actually shipped, so it doubles as the regression record —
add to it when you fix something in that layer rather than starting a new probe. It uses a
scratch `__romm_selftest` system folder under the real roms root (the path is derived from
the systemid and cannot be pointed elsewhere) and removes it at both ends.

`RetroXR/Tests/scene_tests.tscn` covers SceneManager and the save gates around it — which
rooms keep slots, the per-room active slot and its prefs round-trip (including the legacy
single-room key), the `is_room_ready` / `is_scene_content_ready` boundaries, the transition
state machine's coalescing, the periodic autosave, clearing and reloading the room you are
standing in, two restores racing into one room, the video decks' teardown contract, and
slot-manifest CRUD. 72 cases, ~25 s.
```bash
"$godot" --headless --path RetroXR res://Tests/scene_tests.tscn
"$godot" --headless --path RetroXR res://Tests/scene_tests.tscn -- --only=autosave
```
It deliberately does **not** drive a real transition: `change_scene()` loads MainScene.tscn,
whose SubViewports render every frame, and a headless run has no GPU to service them — that
hangs rather than fails (see the SubViewport gotcha below). The cases drive `_transitioning`
and `_pending_scene_id` directly and assert the decisions made from them.

Two traps it hit that the next case will hit too. A spawned system also registers its
captive cable in the `"spawned"` group, so the group is always bigger than the entry list —
measure a baseline rather than hardcoding a count. And tear a group's room down with
`clear_scene()`, not by freeing the systems: freeing only those leaves the cables standing
in the next group's room.

It writes to the player's real `user://scenes` — the slot dir is derived from the room id
and cannot be pointed elsewhere — so it snapshots `prefs.json`, the arcade manifest and the
active slots up front and restores them byte-for-byte at the end. Restoring the manifest
matters beyond deleting the test's own entry: any rewrite round-trips it through JSON, which
turns its version int into `1.0`.

**For anything visual, a photo (or a VIDEO if it's animated — mp4 preferred over
animated GIF) is the preferred proof of validation, delivered inline in the chat.**
Headless runs catch parse/scene/shader errors but cannot confirm how something *looks*
(glyphs, layout, colors, animation). When a change is visual, capture a screenshot or
short recording and surface it inline — don't just report that the headless import
passed. To encode mp4 from probe PNG frames: `imageio` + `imageio-ffmpeg` are pip-installed
(`imageio.get_writer("out.mp4", fps=15, codec="libx264", pixelformat="yuv420p")`).

Godot binary (Windows) — use **Godot 4.7** (the project targets 4.7):
```
C:\Program Files\Godot\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe
```
Use the `_console.exe` variant so stdout/stderr is captured. `$proj` below is the
`RetroXR/` folder inside your checkout.

Godot binary (Linux): `~/Godot/Godot_v4.7-stable_linux.x86_64`
(the project targets Godot 4.7 — see `project.godot config/features`; `Godot_v4.6.3` also
sits in that dir). `$proj` on Linux is `<checkout>/RetroXR`. Note Godot
4.7 promoted "Not all code paths return a value" to a hard parse error for `Variant`-returning
virtual overrides (bit two `_property_get_revert` overrides in godot-xr-tools — fixed with a
trailing `return null`).

### 1. Compile / import check (catches parse, shader & scene-load errors)
```bash
"$godot" --headless --path "$proj" --editor --quit
```
This reimports resources, recompiles every GDScript, compiles shaders, and (critically)
**regenerates the global `class_name` cache**. Run it after adding or renaming any
`class_name`, or a probe that references the new class will fail with
`Could not find type "X" in the current scope`. Filter output for
`SCRIPT ERROR|Parse Error|SHADER ERROR|Failed to load|Failed to instantiate`.

### 2. Functional probe (exercises real code paths)
Write a tiny `probe.gd` (`extends Node`) + `probe.tscn`, run it, print `[probe] ...`
lines, then `get_tree().quit(0)`:
```bash
"$godot" --headless --path "$proj" res://probe.tscn 2>&1 | grep -a "\[probe\]"
```
Always **delete the probe `.gd`/`.tscn` (and generated `.uid`/`.import`) when done.**
Include a `get_tree().create_timer(5.0).timeout.connect(...quit)` safety net so a probe
can never hang the run.

### Gotchas
- **Warnings are treated as errors** for some warnings — notably inferring a `:=`
  variable from a `Variant` (e.g. `var x := ClassDB.instantiate(...)`). Use an explicit
  type (`var x: Object = ...`). `unsafe_method_access` (calling a method not on the
  static type, i.e. duck typing) is **not** an error, so it's fine.
- **A `SubViewport` with `render_target_update_mode = ALWAYS` hangs a headless run**
  (no GPU to service the render target). It renders fine in a real session — just don't
  drive extra `await process_frame`s over such a viewport in a headless probe; test the
  logic/wiring instead and eyeball the visual on-device.
- **Known headless noise to filter out** (pre-existing, not your change): OpenXR
  `xrCreateInstance failed`, missing GDExtension DLLs in the `template_debug` path
  (`libgodotopenxrvendors`, `godot-pdfium`, `libretro_godot`), `.NET Sdk not found`, and
  `xr_staging_shim.gd ... is_xr_class ... placeholder instance`. Grep these out.
- **PowerShell buffers `& $godot ... | Out-String` until the process exits**, so a
  backgrounded run shows an empty output file until it finishes. The Bash tool with
  `timeout 90 "$godot" ... 2>&1 | grep` streams and bounds the run — prefer it.

No compiled C++ test harness exists; GDExtension changes are validated by rebuilding
(above) and loading in the headless editor.

### 2b. The bedroom's saved visual probe

`RetroXR/Tools/bedroom_probe.tscn` — do NOT hand-roll another one. It carries the
still framings for that room (overview, bed, desk, window, TV corner, bookcases,
wardrobe, light switch) plus a flythrough: 360 deg in place at the room centre,
then a lap walking forward round a circle sized to clear the furniture.

```bash
"$godot" --path RetroXR --resolution 320x240 --position 20,20     res://Tools/bedroom_probe.tscn -- --mode=stills      # or flythrough, both
```

Windowed, not `--headless` — the dummy renderer returns a blank image. PNGs land
in `res://probe_out/` (gitignored). Encode a flythrough at 24 fps with imageio and
**pass `-crf 24`**: the default quality puts an 11 s clip at 21 MB, CRF 24 at 2 MB
with no visible difference.

It forces the ceiling-light energy to 0.6 on purpose. The scene authors 1.2 and
`QualityManager._adjust_lights` has not run that early, so a naive probe renders
the room brighter than any player sees it.

**Overwriting a texture in place needs a reimport.** A game run keeps serving the
cached `.ctex`, so two successive recolours of the bed's atlas appeared to do
nothing at all. Run `--editor --quit` between the overwrite and the render.

### 2c. The A/V suite — the one thing here that is an actual test suite

`RetroXR/Tests/av_suite.tscn` — 23 cases over what reaches a television's inputs and
what it shows. Headless, ~90 s, **exits non-zero on failure**, so it is the one probe
that can be run as a gate rather than read.

```bash
"$godot" --headless --path RetroXR res://Tests/av_suite.tscn
"$godot" --headless --path RetroXR res://Tests/av_suite.tscn -- --only=display
```

Groups: `routing/` (real TV + VCR + composite leads — cords into the wrong sockets, a
crossed pair, two leads on one deck, a cord pulled), `display/` (which input is shown,
what a blank input paints, a source that stops, a set switched off, snow on an
untuned aerial channel, a VGA monitor with no phono row, a source's own shader
stage, two sets sharing one machine), `guard/` (`can_paint` / `paint_screen` /
`release_screen`) and `audio/` (only the selected input is heard; a machine wired to
nothing is silent). Every case is a bug that shipped at least once.

Three things it took to make routing cases behave, all of them real behaviour rather
than test scaffolding:
- **Pulling a plug needs the whole panel shut.** Dropping one leaves it standing in a
  60 mm grab zone with four video sockets 18 mm apart around it, and the log reads
  `pulled VIDEO on TV` immediately followed by `seated VIDEO on TV`. `_unplug()` shuts
  every RcaPort in the room for the move.
- **And the plug frozen.** A live one falls back down past the panel and is caught by a
  socket on the way, ending up a perfectly good picture cord in the wrong input.
- **The phosphor accumulator hides the source.** With persistence on, the CRT material's
  `source_tex` is the ping-pong buffer, so the oracle is the set's own `_crt_source_tex`.

It is mutation-tested: reverting the deck to reading one cable, disabling the paint
guard, or restoring the frozen-frame bug each fails exactly the cases that name them.
Adding a case that cannot fail is worse than no case, so break the code and watch it go
red before believing a new one.

### 3. Capturing a real screenshot on Linux (for visual validation)
`--headless` uses the dummy renderer — it **cannot** produce a screenshot (a probe that awaits
`RenderingServer.frame_post_draw` just hangs; `get_image()` is blank). To actually render a
RetroXR scene on this box, run Godot **on the real display** (`DISPLAY=:0`, NVIDIA RTX 3080,
Vulkan Forward+ — a window briefly appears on the desktop, ok'd for validation) and draw into a
**`SubViewport`**, not the window viewport (the uncomposited window swapchain reads back as
clear-colour only). Xvfb does not work here (bwrap/glycin abort in the sandbox). Recipe:
```gdscript
var sv := SubViewport.new()
sv.size = Vector2i(1000, 750)
sv.own_world_3d = true
sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
add_child(sv)   # add WorldEnvironment + DirectionalLight3D + your scene + Camera3D as children
cam.current = true              # make_current() does NOT work inside a SubViewport
for i in range(8): await get_tree().process_frame
await RenderingServer.frame_post_draw
await get_tree().process_frame
sv.get_texture().get_image().save_png("res://shot.png")
```
Run `DISPLAY=:0 "$godot" --path "$proj" res://shot.tscn` (import first with `--headless … --import`).
Then **surface the PNG inline via the Read tool** — the user sees it through the Claude app (the
terminal itself doesn't paint it). Don't save renders to a folder; delete the probe + PNG when done.

## On-Device Testing (Quest over adb, nobody wearing the headset)

The Quest 3 usually sits on the desk on USB (`adb devices` → authorized; USB keeps it
charged). RetroXR can be exported, installed, launched, and probed on it fully
unattended. Verified end-to-end 2026-07-06 (x64↔arm64 netplay determinism run).

In Git Bash, `export MSYS_NO_PATHCONV=1` first or `/sdcard/...` args get mangled into
`C:/Program Files/Git/sdcard/...`.

### Export + install
```bash
"$godot" --headless --path "$proj" --export-debug "Quest" out.apk
adb install -r out.apk        # -r keeps app data
```
- **Stale-script trap**: the gradle export can silently ship an old compiled script —
  `RetroXR/android/build/src/main/assets/**.gdc` is not always re-staged after a source
  edit. If an on-device change doesn't take: `rm -rf RetroXR/android/build/src/main/assets
  RetroXR/android/build/build/intermediates/assets` and re-export. To verify before
  installing: a `.gdc` is a 12-byte `GDSC` header + zstd; decompress with Python 3.14's
  `compression.zstd` and grep the payload for a string you just added.
- `FileAccess.file_exists("res://….tscn")` is **false in exported builds** (paths are
  remapped into the pck) — use `ResourceLoader.exists()`.

### Launching with no one wearing it — ALL three are required
```bash
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close   # fake "worn"
adb shell setprop debug.oculus.guardian_pause 1                  # else a Guardian dialog blocks
adb shell monkey -p com.xenu.retroxr 1                           # GodotApp isn't exported; am start = Permission Denial
```
- The manifest must declare `oculus.software.handtracking` or the shell blocks with a
  controllers-required dialog (controllers are off/dead). That needs BOTH the export
  preset `meta_xr_features/hand_tracking=1` AND project.godot
  `xr/openxr/extensions/hand_tracking=true` — the vendors plugin only injects the
  manifest feature when the OpenXR project setting is on (enabled since b9f1481).
- If an OS dialog is showing, the launch is **cached** and fires once it clears
  (`adb shell input keyevent KEYCODE_BACK` can dismiss).
- Cleanup when done: `guardian_pause 0`, broadcast `prox_open`, `am force-stop`.

### Paths on device
- `user://` = **internal** `/data/user/0/com.xenu.retroxr/files/` — readable/writable via
  `run-as com.xenu.retroxr` (debug builds). Cores + system dirs live there
  (`files/libretro/…`, populated by the in-app CoreDownloadManager).
- ROMs/books/videos live on the **external** dir `/sdcard/Android/data/com.xenu.retroxr/files/`
  (plain `adb push`/`ls` works there).
- **Never `adb push` over a file, or into a directory, that the app itself writes.** The
  app is `other` for everything `shell` creates in its own tree, and no chmod fixes that
  sanely. Confirm the group list before theorising — `cat /proc/$(pidof
  com.xenu.retroxr)/status` reports `Groups: 3003 9997 20198 50198`, i.e. `inet`,
  `everybody`, `<uid>_cache` and `all_a<uid>`. **`ext_data_rw` (1078) is not among them**,
  and it is the group on every `adb`-created file and directory here. Owner is `shell`,
  group is unreachable, so only the `other` bits apply:
  - `adb push` lands a file `0644` — other `r--`. The app can read it forever and can
    never overwrite it. Fine for ROMs, fatal for state files.
  - `adb` creates directories `0770` — other `---`. The app cannot create anything inside
    one, so a system folder made by push gets no `.romm/` index. `romm_catalog.gd` ignores
    the return of `make_dir_recursive_absolute`, so this surfaces one line later and one
    level down as "Cannot write to …/nintendo_64/.romm".
  - Granting the app access through the bits alone would mean `0666` on files and `0777`
    on directories, because the group is useless to it. Don't. Let the app own what it
    writes: delete the pushed copy and let it be recreated in-app.
  - **`chmod 660` is actively harmful here** — it clears the `other` read bit the app was
    relying on, and grants write to a group the app is not in. A config the app can no
    longer read looks exactly like a config that was wiped.
  - Diagnose by owner, not by logs, and never with `run-as com.xenu.retroxr test -w …` —
    that shell does not get the app's storage mount view and reports NOT-WRITABLE for
    files the app demonstrably just wrote. The reliable tell is that every `.romm/` on the
    device is owned by the same uid as its parent directory, never a mix.
- Extra cores: same source the app uses (core_download_manager.gd) —
  `buildbot.libretro.com/nightly/android/latest/arm64-v8a/<core>_libretro_android.so.zip`.

### Running the netplay determinism spike on-device
NetworkManager boots `Tools/netplay_spike.tscn` at startup when `user://spike.cfg`
exists (the spike deletes the cfg immediately, so a crash can't wedge the app):
```bash
printf -- '--spike-core=fceumm\n--spike-rom=/sdcard/Android/data/com.xenu.retroxr/files/roms/nes/ROM.nes\n--spike-root=/data/user/0/com.xenu.retroxr/files/libretro\n' > spike.cfg
adb push spike.cfg /data/local/tmp/
adb shell "cat /data/local/tmp/spike.cfg | run-as com.xenu.retroxr sh -c 'cat > files/spike.cfg'"
```
Then launch (above) and compare the `[crc]` lines against a Windows spike run.

### Log capture
The logcat ring buffer rotates away in **under a minute** (VrApi spam) — poll-grepping
loses boot output. Stream from before the launch instead:
```bash
adb logcat -c && adb logcat -s godot:* > quest.log &
```

## Architecture

### Multi-Instance Design (post-refactor)
Each `Libretro` GDExtension Node owns its own `Wrapper` instance and emulation thread. Multiple `Libretro` nodes can run simultaneously in the same scene, each with a different core/content. This replaced an earlier singleton design.

### Threading Model
Emulation runs on a dedicated `std::thread` owned by `Wrapper`. The main Godot thread communicates with it via a lock-free `ReaderWriterQueue` using a **command pattern** (`ThreadCommand` subclasses: `ThreadCommandCreateTexture`, `ThreadCommandInitAudio`, `ThreadCommandUpdateTexture`). The `Libretro` node's `_process()` drains this queue each frame.

Because libretro callbacks are static C functions, the correct `Wrapper*` is found via a `thread_local` pointer:
```cpp
// Set at emulation thread start, cleared at end:
thread_local Wrapper* t_current_wrapper = nullptr;

// All handlers and Core call:
Wrapper* w = Wrapper::GetCurrentThreadWrapper();
```
ThreadCommands that execute on the main thread carry an explicit `Wrapper*` and call `SetCurrentThreadWrapper` around their work so handler callbacks invoked during Execute() can also resolve the right instance.

### Key Classes (libretro-godot/src/)

- **Wrapper** — Per-instance emulation orchestrator. Owns the emulation thread, all handlers, the command queue, and a back-pointer `Libretro* m_libretro_node`. Exposes `GetCurrentThreadWrapper()` / `SetCurrentThreadWrapper(Wrapper*)` as static helpers for the thread-local pattern.
- **Core** — Dynamically loads a libretro core (`.dll` on Windows, `.so` on Linux/Android,
  `.dylib` on macOS) via `DynLib.hpp`, copies it to a temp directory for isolation, and
  binds all libretro callback function pointers. All callbacks resolve the current wrapper
  via `GetCurrentThreadWrapper()`.
- **Libretro** — The GDExtension Node exposed to GDScript. Instance methods only (`StartContent`, `StopContent`, `SetCoreOption`). Owns a `std::unique_ptr<Wrapper> m_wrapper`. Emits the `options_ready` signal via `NotifyOptionsReady()` (called from Wrapper across the thread boundary using `call_deferred`).

### Handler Subsystems
Each handler is owned by a `Wrapper` instance and manages one libretro subsystem:
- **VideoHandler** — Texture creation/updates, hardware rendering, rotation
- **AudioHandler** — Audio stream generation and playback
- **InputHandler** — Input polling, joypad/mouse/keyboard mapping (Godot keycodes ↔ libretro keycodes). Currently reads the global Godot `Input` singleton — all active instances see the same controller state.
- **EnvironmentHandler** — Libretro environment callbacks (system dirs, VFS, disk control)
- **OptionsHandler** — Core option parsing (v1/v2 formats), categorization, persistence
- **MessageHandler** — Notification/message interface
- **LogHandler** — Log callback forwarding

### Data Flow
```
GDScript UI → Libretro Node (instance) → Wrapper (per-node) → Core + Handlers → Libretro Core (.dll/.so/.dylib)
                                               ↑ ThreadCommand queue (ReaderWriterQueue) ↓
                                         Main thread (_process drains queue)
```

### GDScript Side
- `RetroXR/Scripts/libretro.gd` — Main controller script. Uses `@export var libretro_node: Libretro` to reference the `Libretro` node; falls back to `find_child("Libretro")` if unset.
- `RetroXR/Scripts/Objects/systems/system.gd` — Per-arcade-cabinet controller. Has `@onready var _libretro: Libretro = $Libretro` wired to a child `Libretro` node in the scene tree.
- `RetroXR/Scenes/Objects/system.tscn` — Cabinet scene. Contains a `Libretro` child node (unique_id `4000000010`).
- GDExtension registration at `MODULE_INITIALIZATION_LEVEL_SCENE`.

## Dependencies

- **godot-cpp** (submodule, 4.5 branch) — Godot C++ bindings
- **SDL3** — On Windows: core DLL loading (`DynLib.hpp`) + the OpenGL HW-render window. On Linux: the OpenGL HW-render window only (core loading uses `dlopen`); linked against the system `libSDL3.so.0` by soname, headers from `libretro-godot/external/SDL3/`. Not used on Android (`dlopen` + EGL via `DynLib.hpp`).
- **libretro-common** — Reference implementations for VFS, audio conversion, etc. (`libretro-godot/external/libretro-common/`)
- **moodycamel::ReaderWriterQueue** — Lock-free SPSC queue for cross-thread communication
- **godot-xr-tools v4.5.1** — VR locomotion, interactions, finger poses (`RetroXR/addons/godot-xr-tools/`)
- **vlc-godot** (libVLC) — the `VlcPlayer` GDExtension; single video backend for both the DVD
  player and the VHS/VCR. Replaced `eirteam.ffmpeg` (dropped 2026-07-14; libVLC also does x265).
- **godot-pdfium** (PDFium) — the `PDFRenderer` GDExtension for rendering PDF pages (books) to
  Godot `Image`s. Prebuilt `libpdfium` from bblanchon/pdfium-binaries.

## Code Conventions

- C++latest standard (MSVC on Windows), C++20 (GCC/Clang/NDK elsewhere)
- Debug logging via `Log`, `LogOK`, `LogWarning`, `LogError` macros
- Libretro option data exposed to GDScript as `LibretroOptionCategory`, `LibretroOptionDefinition`, `LibretroOptionValue` objects
- Callback-based design throughout (video_refresh, audio_sample, input_poll, environment)
- All static libretro callbacks resolve their `Wrapper*` via `Wrapper::GetCurrentThreadWrapper()` — never store a raw global pointer
- `call_deferred` used when Wrapper needs to signal back to the `Libretro` node on the main thread (e.g. `NotifyOptionsReady`)

## Tools

Reusable, out-of-band scripts live in the repo-root `Tools/` (distinct from `RetroXR/Tools/`,
which holds in-editor probe scenes like `netplay_spike`).

`RetroXR/imported-assets/` holds the CC BY / CC0 room and prop assets, which carry
LICENSE files and are credited in the About panel. The hardware wears the procedural
stand-ins in `RetroXR/Scenes/Objects/system_models/`.

**Only add 3D assets this project has the right to ship.** Everything in the repo must
be either our own work or licensed for redistribution, with its licence and attribution
carried alongside it.
- **`Tools/download_pdfium.sh`** — fetches prebuilt PDFium from bblanchon/pdfium-binaries into
  `godot-pdfium/external/pdfium/`. All five packages by default (`-p
  linux|win|mac|mac-x64|android` for one, `-r <tag>` to pin a release, `-n` to dry-run).
  Bash, so it runs on Linux, WSL, macOS and Git Bash; it replaced
  `download_pdfium.ps1`, which had no Linux or macOS platform at all. The
  `include/` headers are shared by all packages, so a **partial** run leaves them alone by
  default (`--headers` to force) — new declarations against an unrefreshed binary is how you
  get a link error on the platform you weren't building. Each `lib/<plat>/` carries a `VERSION`
  stamp of the release it came from, and the top-level one belongs to `include/`; they are
  allowed to differ, and the script prints them so you can see when they do.
- **`Tools/glb/decimate_glb.py`** — Blender-headless triangle reduction for a downloaded shell.
  Sketchfab assets arrive subdivided for renders: the Atari 2600 console shipped 1,080,733
  triangles and 57.7 MB, against 27,893 for the NES. **Weld first** — these exports are
  triangle soup (that console was 230,787 disconnected islands, median one triangle), and
  Collapse cannot reduce an isolated triangle, so without the weld the body floors at 54 k
  however low you aim. Also drop the custom split normals and re-derive shading by angle:
  carried through a 98% cut they describe a surface that is gone, which showed up as a smeared
  cartridge slot and starburst facets across flat panels.
  ```bash
  "/c/Program Files/Blender Foundation/Blender 5.1/blender.exe" --background \
    --python Tools/glb/decimate_glb.py -- --in <src>.glb --out <dst>.glb --target 25000
  ```
  `Tools/glb/glb_report.py` dumps a GLB's node tree, world AABBs and triangle budget;
  `Tools/glb/glb_diff.py` compares two and is the check that matters — every model's seat,
  port and jack constant is a hand-measured position in the GLB's frame, so a round trip has
  to preserve names, hierarchy, world placement and image names. Note the GLBs are **Git LFS**,
  so `git show HEAD:<path>` yields a pointer: pipe it through `git lfs smudge` to get a
  baseline to diff against.
