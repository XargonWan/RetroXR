# SK.Libretro.Godot

GDExtension to run libretro cores inside of Godot 4

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
