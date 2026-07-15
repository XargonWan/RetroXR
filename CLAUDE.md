# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SK.Libretro.Godot is a GDExtension (C++) that runs libretro emulator cores inside Godot 4.5+. It bridges Godot's scene system with the libretro API, enabling retro game emulation within Godot projects.

The Godot project in this repo:
- `RetroVR/` — VR arcade room (primary development target, godot-xr-tools based)

## Git Workflow

**Commit directly to `master` unless the user says otherwise.** This is a solo repo —
do not branch-per-feature by default; commit and (when asked) push straight to `master`.
Branch only when the user explicitly requests it.

## Build Commands

Requires SCons and MSVC (Windows), GCC/Clang (Linux), or Android NDK (Android). The godot-cpp submodule must be initialized first:
```bash
git submodule update --init --recursive
```

Build from the **workspace root** (not `-C Temp`):
```bash
# Windows (PowerShell)
$scons = "C:\Users\user\AppData\Roaming\Python\Python314\Scripts\scons.exe"
& $scons platform=windows arch=x86_64 target=template_debug dev_build=yes
& $scons platform=windows arch=x86_64 target=template_release

# Android / Quest (bash — requires ANDROID_NDK_ROOT)
ANDROID_NDK_ROOT="C:/android/android-ndk-r27d" ANDROID_HOME="" \
  scons platform=android arch=arm64 target=template_debug ANDROID_HOME=""

# Linux desktop x86_64 (bash — GCC/Clang; SCons via `pip install --user scons`)
scons platform=linux arch=x86_64 target=template_debug
scons platform=linux arch=x86_64 target=template_release
```

The `SConstruct` is at the workspace root; `Temp/SConscript` does the actual build logic.
Output libraries go to `RetroVR/libretro-godot/`.

The Linux build links `libvulkan.so.1`, `libSDL3.so.0`, and `libGL.so.1` by soname (no
`-dev`/`-devel` packages needed). All three render paths work on Linux: software, Vulkan
HW-render, and OpenGL HW-render (SDL3-created hidden GL window — needs a display server at
runtime). Desktop Linux support was added 2026-07-13 (Windows x86_64 + Android arm64 were
the original targets).

## Headless Testing & Validation

There is no formal test suite. The project is validated by running the Godot editor
**headless** for compile/scene checks, plus small throwaway "probe" scenes for functional
tests. This works without a VR headset (desktop fallback) and without a display.

Godot binary (Windows) — use **Godot 4.7** (the project targets 4.7):
```
C:\Program Files\Godot\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe
```
Use the `_console.exe` variant so stdout/stderr is captured. `$proj` below is
`C:\Users\user\SK.Libretro.Godot\RetroVR`.

Godot binary (Linux): `/home/user/Godot/Godot_v4.7-stable_linux.x86_64`
(the project targets Godot 4.7 — see `project.godot config/features`; `Godot_v4.6.3` also
sits in that dir). `$proj` on Linux is `/home/user/retrovr/RetroVR`. Note Godot
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

## On-Device Testing (Quest over adb, nobody wearing the headset)

The Quest 3 usually sits on the desk on USB (`adb devices` → authorized; USB keeps it
charged). RetroVR can be exported, installed, launched, and probed on it fully
unattended. Verified end-to-end 2026-07-06 (x64↔arm64 netplay determinism run).

In Git Bash, `export MSYS_NO_PATHCONV=1` first or `/sdcard/...` args get mangled into
`C:/Program Files/Git/sdcard/...`.

### Export + install
```bash
"$godot" --headless --path "$proj" --export-debug "Quest" out.apk
adb install -r out.apk        # -r keeps app data
```
- **Stale-script trap**: the gradle export can silently ship an old compiled script —
  `RetroVR/android/build/src/main/assets/**.gdc` is not always re-staged after a source
  edit. If an on-device change doesn't take: `rm -rf RetroVR/android/build/src/main/assets
  RetroVR/android/build/build/intermediates/assets` and re-export. To verify before
  installing: a `.gdc` is a 12-byte `GDSC` header + zstd; decompress with Python 3.14's
  `compression.zstd` and grep the payload for a string you just added.
- `FileAccess.file_exists("res://….tscn")` is **false in exported builds** (paths are
  remapped into the pck) — use `ResourceLoader.exists()`.

### Launching with no one wearing it — ALL three are required
```bash
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close   # fake "worn"
adb shell setprop debug.oculus.guardian_pause 1                  # else a Guardian dialog blocks
adb shell monkey -p com.xenu.retrovr 1                           # GodotApp isn't exported; am start = Permission Denial
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
- `user://` = **internal** `/data/user/0/com.xenu.retrovr/files/` — readable/writable via
  `run-as com.xenu.retrovr` (debug builds). Cores + system dirs live there
  (`files/libretro/…`, populated by the in-app CoreDownloadManager).
- ROMs/books/videos live on the **external** dir `/sdcard/Android/data/com.xenu.retrovr/files/`
  (plain `adb push`/`ls` works there).
- Extra cores: same source the app uses (core_download_manager.gd) —
  `buildbot.libretro.com/nightly/android/latest/arm64-v8a/<core>_libretro_android.so.zip`.

### Running the netplay determinism spike on-device
NetworkManager boots `Tools/netplay_spike.tscn` at startup when `user://spike.cfg`
exists (the spike deletes the cfg immediately, so a crash can't wedge the app):
```bash
printf -- '--spike-core=fceumm\n--spike-rom=/sdcard/Android/data/com.xenu.retrovr/files/roms/nes/ROM.nes\n--spike-root=/data/user/0/com.xenu.retrovr/files/libretro\n' > spike.cfg
adb push spike.cfg /data/local/tmp/
adb shell "cat /data/local/tmp/spike.cfg | run-as com.xenu.retrovr sh -c 'cat > files/spike.cfg'"
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
- **Core** — Dynamically loads a libretro core (`.dll` on Windows, `.so` on Android) via `DynLib.hpp` abstraction, copies it to a temp directory for isolation, and binds all libretro callback function pointers. All callbacks resolve the current wrapper via `GetCurrentThreadWrapper()`.
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
GDScript UI → Libretro Node (instance) → Wrapper (per-node) → Core + Handlers → Libretro Core (.dll/.so)
                                               ↑ ThreadCommand queue (ReaderWriterQueue) ↓
                                         Main thread (_process drains queue)
```

### GDScript Side
- `RetroVR/Scripts/libretro.gd` — Main controller script. Uses `@export var libretro_node: Libretro` to reference the `Libretro` node; falls back to `find_child("Libretro")` if unset.
- `RetroVR/Scripts/Objects/system.gd` — Per-arcade-cabinet controller. Has `@onready var _libretro: Libretro = $Libretro` wired to a child `Libretro` node in the scene tree.
- `RetroVR/Scenes/Objects/system.tscn` — Cabinet scene. Contains a `Libretro` child node (unique_id `4000000010`).
- GDExtension registration at `MODULE_INITIALIZATION_LEVEL_SCENE`.

## Dependencies

- **godot-cpp** (submodule, 4.5 branch) — Godot C++ bindings
- **SDL3** — On Windows: core DLL loading (`DynLib.hpp`) + the OpenGL HW-render window. On Linux: the OpenGL HW-render window only (core loading uses `dlopen`); linked against the system `libSDL3.so.0` by soname, headers from `libretro-godot/external/SDL3/`. Not used on Android (`dlopen` + EGL via `DynLib.hpp`).
- **libretro-common** — Reference implementations for VFS, audio conversion, etc. (`libretro-godot/external/libretro-common/`)
- **moodycamel::ReaderWriterQueue** — Lock-free SPSC queue for cross-thread communication
- **godot-xr-tools v4.5.1** — VR locomotion, interactions, finger poses (`RetroVR/addons/godot-xr-tools/`)

## Code Conventions

- C++latest standard (MSVC on Windows), C++20 (Clang/NDK on Android)
- Debug logging via `Log`, `LogOK`, `LogWarning`, `LogError` macros
- Libretro option data exposed to GDScript as `LibretroOptionCategory`, `LibretroOptionDefinition`, `LibretroOptionValue` objects
- Callback-based design throughout (video_refresh, audio_sample, input_poll, environment)
- All static libretro callbacks resolve their `Wrapper*` via `Wrapper::GetCurrentThreadWrapper()` — never store a raw global pointer
- `call_deferred` used when Wrapper needs to signal back to the `Libretro` node on the main thread (e.g. `NotifyOptionsReady`)
