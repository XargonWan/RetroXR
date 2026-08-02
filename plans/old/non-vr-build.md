# Non-VR Build — Desktop Mode

## Goal
Allow the project to run without a VR headset using mouse+WASD controls, with a crosshair for object interaction (mimicking VR ray pointer).

## Current State
- **`xr_init.gd`** already gracefully falls back if OpenXR is unavailable (logs warning, continues)
- **godot-xr-tools has desktop support modules** in `addons/godot-xr-tools/desktop-support/`:
  - `function_desktop_pointer.gd` — Ray-based pointer with mouse
  - `movement_desktop_direct.gd` — WASD movement
  - `movement_desktop_turn.gd` — Mouse-look turning
  - `mouse_capture.gd` — Mouse lock/unlock
  - `controller_hider.gd` — Hide controller meshes
- These exist but are **not wired** into `player_rig.tscn`
- All interaction (pickup, snap, pointer) uses XRTools which has desktop equivalents

## Implementation Plan

### Phase 1: Desktop Player Rig
1. **Add desktop support nodes to `player_rig.tscn`**:
   - Add `XRToolsMovementDesktopDirect` (WASD) to XROrigin3D
   - Add `XRToolsMovementDesktopTurn` (mouse look) to XROrigin3D
   - Add `XRToolsMouseCapture` to XROrigin3D
   - Add `XRToolsControllerHider` to each controller
   - Add `XRToolsFunctionDesktopPointer` to camera (replaces VR pointer)
2. **These nodes auto-disable when XR is active** (built-in godot-xr-tools behavior)

### Phase 2: Crosshair / Reticle
1. **Add a centered crosshair overlay**:
   - Small dot/cross sprite on a CanvasLayer (always centered)
   - Only visible when in desktop mode
   - Indicates where the desktop pointer ray is aimed (screen center)
2. **Pointer interaction**: Desktop pointer casts ray from camera center, same collision layers as VR pointer (layer 21)

### Phase 3: Desktop Input Mapping
1. **Keyboard controls for libretro** (already partially defined in `project.godot`):
   - RETRO_JOYPAD actions already have keyboard bindings (arrow keys, ZXCVBN, etc.)
   - These work automatically in desktop mode via `Input.is_action_pressed()`
2. **Object interaction**:
   - Left click = grab/drop (replaces grip button)
   - Right click = secondary action / pointer click
   - Scroll wheel = optional (zoom or rotate held object)
3. **Special key for "activating" buttons** (from wish list):
   - `E` key or left-click when pointing at a button → triggers button press
   - Reuse existing `XRToolsFunctionDesktopPointer` which handles this

### Phase 4: Mode Detection & UI
1. **Auto-detect mode** in `xr_init.gd`:
   - If OpenXR initializes → VR mode (existing behavior)
   - If OpenXR fails → Desktop mode, enable desktop nodes
   - Store mode in a global: `Global.is_vr_mode`
2. **Adapt spawn menu**:
   - In desktop mode, spawn menu becomes a traditional 2D UI panel (not a 3D viewport)
   - Or: keep 3D viewport but render to screen overlay
3. **Adapt VRInputMapper**:
   - Skip VR-specific attach combo (Left X + Right A)
   - In desktop mode, click on a system to attach, Escape to detach

## Key Files to Modify
- `RetroXR/Scenes/player_rig.tscn` — Add desktop support nodes
- `RetroXR/Scripts/XR/xr_init.gd` — Mode detection, enable/disable desktop nodes
- `RetroXR/Scripts/XR/vr_input_mapper.gd` — Desktop attach/detach alternative
- `RetroXR/Scripts/UI/spawn_menu/spawn_menu_controller.gd` — Desktop menu interaction

## New Files
- `RetroXR/Scripts/Desktop/desktop_reticle.gd` — Crosshair overlay script
- `RetroXR/Scenes/UI/desktop_reticle.tscn` — Crosshair scene

## Interaction Limitations (from wish list)
- Picking up and placing objects with mouse is less intuitive than VR grab
- Cable plugging may need a simplified "click to connect" mode
- Some VR-specific gestures (page turning books) need keyboard alternatives

## Verification
1. Run project without VR headset connected
2. WASD moves, mouse looks around
3. Crosshair visible at screen center
4. Left-click picks up objects, click again drops
5. Can plug cable into TV, insert cartridge, press START button
6. Libretro games play with keyboard input
