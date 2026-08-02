# retroXR

A VR retro-gaming room in Godot 4: real emulated hardware you pick up, plug in and
play with, driven by libretro cores.

## Building

Almost everything interesting here is C++. Five GDExtensions have to be compiled
before the Godot project will run — a fresh clone has the sources but not the
libraries. Miss one and Godot says so on startup, then every scene using its types
fails to parse:

```
ERROR: GDExtension dynamic library not found: 'res://verlet-rope/verlet_rope.gdextension'.
SCRIPT ERROR: Parse Error: Could not find type "VerletRope" in the current scope.
```

| Extension | Provides | Built from | Deploys to |
|---|---|---|---|
| `libretro-godot` | `Libretro` — runs the emulator cores (submodule) | repo root | `RetroVR/libretro-godot/` |
| `verlet-rope` | `VerletRope` — the simulated cables | `verlet-rope/` | `RetroVR/verlet-rope/` |
| `vlc-godot` | `VlcPlayer` — video for the VCR and DVD player | `vlc-godot/` | `RetroVR/vlc-godot/` |
| `godot-pdfium` | `PDFRenderer` — renders manual pages | `godot-pdfium/` | `RetroVR/godot-pdfium/` |
| `metaxr-audio` | HRTF spatial audio on Quest | `metaxr-audio-godot/` | `RetroVR/metaxr-audio/` |

**Each needs its own `scons` invocation.** They share the `godot-cpp` submodule, and
godot-cpp's `SConstruct` can only run once per process, so a single scons run can never
cover two of them. Each also has its own `VariantDir('Temp')`, which is why each builds
from its own directory — except `libretro-godot`, whose SConstruct is the repo root's.

### Prerequisites

```bash
git submodule update --init --recursive     # godot-cpp, libretro-common, vulkan-headers
pip install --user scons                    # ensure the Scripts/bin dir is on PATH
```

Plus a compiler: **MSVC** on Windows, **GCC/Clang** on Linux, the **Android NDK** for
Quest (set `ANDROID_NDK_ROOT`; `ANDROID_HOME` must be *empty*, not unset, or godot-cpp
looks for a full SDK).

Every third-party binary these link against is already committed — PDFium for all three
platforms, the libVLC import libraries and Android `libvlc.so`, the Meta XR Audio blob.
The one exception is **libVLC on Linux**, which links the system library (Fedora:
`vlc-devel` to build, `vlc-libs` to run).

### One command

```bash
python Tools/build.py windows                 # all five, debug + release
python Tools/build.py android --target release
python Tools/build.py linux --only vlc-godot
python Tools/build.py windows --jobs 8 -- verbose=yes    # extra args go to scons
```

It runs the five builds in sequence, prints a pass/fail table, and exits non-zero if any
failed. Architecture follows the platform: `x86_64` for windows and linux, `arm64` for
android.

Asking for `linux` **from Windows** re-invokes the script inside WSL (`--distro`, default
`Ubuntu`) with `HOME` and `PATH` reset — WSL inherits the Windows environment, whose PATH
contains spaces and breaks a bare `export PATH="$HOME/.local/bin:$PATH"`. From Linux it
just builds. *(scons is not currently installed in either WSL distro here; `pip install
--user scons` inside the distro first.)*

### Or one at a time

```bash
scons platform=windows arch=x86_64 target=template_debug          # libretro-godot, from the root
cd verlet-rope && scons platform=linux arch=x86_64 target=template_release
cd godot-pdfium && scons platform=android arch=arm64 target=template_debug ANDROID_HOME=
```

Each writes a `lib<name>.<platform>.<target>.<arch>.so` (or `.dll`) next to the
`.gdextension` file that points at it.

## Video player (VCR)

Besides emulator systems, the arcade room can play video files on the same TVs, driven by
the in-tree `vlc-godot` GDExtension — a [libVLC](https://www.videolan.org/vlc/libvlc.html)
backed `VlcPlayer`. It is the single video backend for both the VCR and the DVD player,
and it handles x265/HEVC.

1. Drop video files into the `videos/` folder (next to `roms/` and `books/`):
   - Windows: `%USERPROFILE%\retrovr\videos`
   - Quest/Android: `/sdcard/Android/data/com.xenu.retrovr/files/videos`
   - Supported: `.mp4`, `.mkv`, `.avi`, `.webm`, `.mov`
2. Open the spawn menu (`Tab`), go to the **Videos** tab, and click a video to spawn a
   **VHS tape** carrying that file's path (like a cartridge carries a ROM path).
3. From the **Objects** tab, spawn a **VCR** and a **TV**.
4. Plug the VCR's cable into the TV (same cable/plug the emulator systems use).
5. Insert the tape into the VCR's slot, then use the on-unit buttons:
   **Play**, **Pause**, **Stop** (eject/blank), **&lt;&lt;** (rewind), **&gt;&gt;** (fast-forward).

The video renders onto the connected TV's screen, and the TV's volume/power buttons
control the VCR's audio and screen just like a system.

## TV remote

Spawn a **TV Remote** from the spawn menu's **Objects** tab. While held, point it at a
TV or VCR — the target is outlined maroon and a small menu pops up above the remote:

- **TV**: `POWER` / `VOL +` / `VOL −`
- **VCR**: `PLAY` / `PAUSE` / `STOP` / `FF` / `REW`

**VR**: flick the thumbstick up/down to move the selection, press the primary button
(`A`/`X`) or click the thumbstick to activate.

**Desktop**: the remote snaps to the lower-right corner aiming where you look (like the
ray gun). `Arrow Up`/`Arrow Down` move the selection, `Enter` activates, and — because
it is FPS-snapped — dropping it requires **`Ctrl` + Left-click** (plain click won't drop it).

## Desktop mode controls

When no VR headset is detected, RetroVR falls back to a desktop mode with mouse/keyboard controls.

**Movement / camera**
- `WASD` — move
- Mouse — look
- `Ctrl` (hold) — crouch
- `Caps Lock` (hold) — walk (move slower, finer-grained control)

**Interaction**
- Left-click — grab/pick up object under cursor (or shoot, if holding the ray gun)
- `Ctrl` + Left-click — drop held object (required for FPS-snapped objects: ray gun,
  TV remote; plain click also drops everything else)
- Scroll wheel — push/pull held object along view ray (disabled while FPS-snapped)
- Middle-mouse drag — rotate held object in place
- `Tab` — toggle spawn menu

**Retro joypad** (when a Libretro node has input focus)
- D-pad: `W`/`A`/`S`/`D`
- Face buttons: Numpad `1`=B, `2`=A, `3`=Y, `4`=X
- Shoulders: `L`=`Q`/`R`/Numpad3, `R`=`E`/`Y`/Numpad6
- Triggers: `L2`=`Z`, `R2`=`X`
- Stick clicks: `L3`=`C`, `R3`=`V`
- `Shift`=Select, `Enter`=Start
- Left stick: `T`/`G`/`F`/`H` (up/down/left/right)
- Right stick: `I`/`K`/`J`/`L` (up/down/left/right)
