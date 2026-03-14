# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SK.Libretro.Godot is a GDExtension (C++) that runs libretro emulator cores inside Godot 4.5+. It bridges Godot's scene system with the libretro API, enabling retro game emulation within Godot projects.

The Godot project in this repo:
- `RetroVR/` — VR arcade room (primary development target, godot-xr-tools based)

## Build Commands

Requires SCons and MSVC (Windows) or Android NDK (Android). The godot-cpp submodule must be initialized first:
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
```

The `SConstruct` is at the workspace root; `Temp/SConscript` does the actual build logic.
Output libraries go to `RetroVR/libretro-godot/`.

No test suite exists in this project.

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
- **SDL3** — Core DLL loading and HW render window management on Windows only (`libretro-godot/external/SDL3/`). Not used on Android (replaced by `dlopen`/`dlsym` via `DynLib.hpp`).
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
