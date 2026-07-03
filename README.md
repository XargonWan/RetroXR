# SK.Libretro.Godot

GDExtension to run libretro cores inside of Godot 4

## Desktop mode controls

When no VR headset is detected, RetroVR falls back to a desktop mode with mouse/keyboard controls.

**Movement / camera**
- `WASD` — move
- Mouse — look

**Interaction**
- Left-click — grab/pick up object under cursor (or shoot, if holding the ray gun)
- `Ctrl` + Left-click — drop held object (plain click also drops non-gun objects)
- Scroll wheel — push/pull held object along view ray (disabled while gun is FPS-snapped)
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
