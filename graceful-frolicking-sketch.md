# Plan: RetroVR — VR Retro Gaming Room

## Context
RetroVR already has working OpenXR VR with animated Quest 3 controllers and a single arcade cabinet running libretro. The goal is to create a new project **RetroVR** (copied from RetroVR) and build a full VR retro gaming room where the user spawns TVs, retro console Systems, and Cartridges, physically connects them with cables, and plays games — all in VR.

**Key constraint**: The `Libretro` C++ class is a singleton — only one core can run at a time. A `SystemManager` autoload will enforce this.

## Decisions
- **Godot XR Tools** addon for pickup, snap zones, pointer/ray
- **Placeholder primitives** (boxes/quads) for all 3D models initially
- **Verlet rope physics** for cables
- Core manager/downloader and ROM scraper **deferred** to later

## Step 0: Copy RetroVR → RetroVR

Copy `RetroVR/` to `RetroVR/` at the repo root (excluding `.godot/`). Update `RetroVR/project.godot`:
- Change `config/name` to `"RetroVR"`
- All subsequent work happens in `RetroVR/` only — RetroVR stays untouched

---

## Phase 0: Godot XR Tools Integration

**Goal**: Add godot-xr-tools addon and verify grip pickup works.

**Files**:
- Add `RetroVR/addons/godot-xr-tools/` (addon install)
- Modify `RetroVR/project.godot` — enable addon
- Modify `RetroVR/Scenes/MainScene.tscn` — add `XRToolsFunctionPickup` + `XRToolsFunctionPointer` as children of each controller

**Controller hierarchy becomes**:
```
LeftController (XRController3D, controller_model.gd)
  XRToolsFunctionPickup
  XRToolsFunctionPointer
RightController (XRController3D, controller_model.gd)
  XRToolsFunctionPickup
```

**Test**: Place a test `XRToolsPickable` RigidBody3D box in scene. Grip to pick up, release to drop.

---

## Phase 1: VR Locomotion

**Goal**: Smooth locomotion on left stick + teleport arc on right stick.

**Smooth locomotion (left stick)**:
- Push left stick forward → move in the direction the player is looking (HMD forward, projected onto ground plane)
- Push left → strafe left relative to look direction
- Platform-style movement: the XROrigin3D translates along the XZ plane based on stick input and camera yaw
- Speed configurable (e.g., 2–3 m/s)

**Teleport (right stick)**:
- Push right stick forward → draw a parabolic arc from the controller
- Arc hits the ground → draw a circle/ring at the landing point
- Release stick back to center → teleport XROrigin3D to that position (instant, no fade needed initially)
- If arc doesn't hit valid ground, show red/no indicator

**Approach**: Godot XR Tools has `XRToolsMovementDirect` (smooth locomotion) and `XRToolsMovementTeleport` (teleport). These can be added as children of the XROrigin3D or the player body. However, since we want specific behavior (left=smooth, right=teleport), we may configure two separate movement providers or write a custom `locomotion.gd`.

**Option A — XR Tools built-in** (recommended if it supports per-controller config):
- Add `XRToolsMovementDirect` as child of XROrigin3D, configured to use left controller stick
- Add `XRToolsMovementTeleport` as child of XROrigin3D, configured to use right controller stick
- XR Tools handles the arc rendering and collision

**Option B — Custom script**:
- `RetroVR/Scripts/locomotion.gd` attached to XROrigin3D
- Reads left controller `primary` Vector2 → translates XROrigin3D
- Reads right controller `primary` Vector2 → raycasts parabolic arc, renders with ImmediateMesh, teleports on release

**Create**:
- `RetroVR/Scripts/locomotion.gd` (if custom) or configure XR Tools movement nodes
- Add floor `StaticBody3D` with collision for teleport ray to hit

**Modify**:
- `RetroVR/Scenes/MainScene.tscn` — add movement provider nodes + floor with collision

**Test**: Use left stick to walk around the room. Push right stick forward to see teleport arc. Release to teleport to the circle.

---

## Phase 2: TV Object

**Goal**: Pickable TV with a screen mesh and a composite video snap zone.

**Create**:
- `RetroVR/Scenes/Objects/tv.tscn`
- `RetroVR/Scripts/Objects/tv.gd`

**Node tree**:
```
TV (XRToolsPickable / RigidBody3D) — tv.gd
  CollisionShape3D (BoxShape3D ~0.5×0.4×0.3)
  TVBody (MeshInstance3D, BoxMesh placeholder)
  ScreenMesh (MeshInstance3D, QuadMesh ~0.35×0.25, offset forward)
  CompositePort (XRToolsSnapZone, snap_group="composite_plug")
    PortVisual (MeshInstance3D, small yellow cylinder)
```

**tv.gd**: Exposes `get_screen_mesh() -> MeshInstance3D`. When a cable plug snaps into `CompositePort`, calls `plug.get_system().on_tv_connected(self)`. On unsnap, calls `on_tv_disconnected()`.

---

## Phase 3: System Object

**Goal**: Pickable retro console with firm-coded libretro core, power/reset buttons, cartridge slot, cable attach point.

**Create**:
- `RetroVR/Scenes/Objects/system.tscn` (base scene)
- `RetroVR/Scripts/Objects/system.gd`
- `RetroVR/Scripts/system_manager.gd` (autoload singleton)
- System variants: `system_nes.tscn`, `system_snes.tscn`, `system_n64.tscn`, `system_ps1.tscn` (inherit base, set `core_name`)

**Node tree**:
```
System (XRToolsPickable / RigidBody3D) — system.gd
  CollisionShape3D (BoxShape3D ~0.3×0.1×0.25)
  SystemBody (MeshInstance3D, BoxMesh, colored per type)
  CartridgeSlot (XRToolsSnapZone, snap_group="cartridge")
  CableAttachPoint (Node3D)
  PowerButton (Area3D) — vr_button.gd
  ResetButton (Area3D) — vr_button.gd
```

**system.gd exports**: `core_name`, `core_directory`, `system_label`. Tracks `rom_path` (from cartridge), `connected_tv`, `is_powered_on`. `power_on()` calls `SystemManager.stop_active_system()` first, then `Libretro.StartContent(tv.get_screen_mesh(), ...)`. `power_off()` calls `Libretro.StopContent()`.

**system_manager.gd** (autoload): Tracks `active_system`, exposes `stop_active_system()`, `set_active_system()`, `clear_active_system()`.

**Modify**: `RetroVR/project.godot` — add SystemManager autoload.

---

## Phase 4: Cartridge Object

**Goal**: Pickable cartridge carrying a ROM path that snaps into system slots.

**Create**:
- `RetroVR/Scenes/Objects/cartridge.tscn`
- `RetroVR/Scripts/Objects/cartridge.gd`

**Node tree**:
```
Cartridge (XRToolsPickable / RigidBody3D) — cartridge.gd
  CollisionShape3D (BoxShape3D ~0.1×0.08×0.015)
  CartridgeMesh (MeshInstance3D, BoxMesh)
```

**cartridge.gd**: `@export rom_path: String`. Exposes `get_rom_path()`. When snapped into system's CartridgeSlot, system reads `get_rom_path()`. When removed, system clears rom_path and stops if running.

---

## Phase 5: VR Button Interaction

**Goal**: Physical press buttons (Power/Reset) on systems respond to controller touch.

**Create**:
- `RetroVR/Scripts/Objects/vr_button.gd`

**vr_button.gd**: Extends `Area3D`. Emits `button_pressed` signal. On `body_entered` (controller collision layer), visually depresses the button mesh and emits signal. On `body_exited`, resets position.

**Wire**: System connects `PowerButton.button_pressed` → toggle power. `ResetButton.button_pressed` → `power_off(); power_on()`.

---

## Phase 6: Spatial Audio (C++ Change)

**Goal**: Audio comes from TV position in 3D space instead of being global.

**Modify** (C++, requires rebuild):
- `SKLibretro/src/Wrapper.cpp` — change `memnew(AudioStreamPlayer)` → `memnew(AudioStreamPlayer3D)`, update name to `"AudioStreamPlayer3D"`
- `SKLibretro/src/AudioHandler.hpp` — change member type to `AudioStreamPlayer3D*`
- `SKLibretro/src/AudioHandler.cpp` — update `get_node<AudioStreamPlayer3D>("AudioStreamPlayer3D")`
- Add `#include <godot_cpp/classes/audio_stream_player3d.hpp>` where needed

**Note**: `AudioStreamPlayer3D` works fine for the flat-screen Demo too since the scene is 3D. Both projects share the DLL.

**Build**: `scons -C Temp platform=windows target=template_debug arch=x64`

---

## Phase 7: Cable with Verlet Rope Physics

**Goal**: Each system has a dangling video cable. User grabs the plug end and drags it to a TV's composite port.

**Create**:
- `RetroVR/Scripts/Objects/verlet_rope.gd`
- `RetroVR/Scripts/Objects/cable_plug.gd`
- `RetroVR/Scenes/Objects/cable.tscn`

**verlet_rope.gd**: 15 segments, verlet integration in `_physics_process`. Point 0 pinned to system's `CableAttachPoint`. Last point follows plug position. 5 constraint iterations per frame. Rendered via `ImmediateMesh` tube geometry.

**cable_plug.gd**: `XRToolsPickable`, `snap_group="composite_plug"`. Holds back-reference to parent system via `get_system()`. When snapped into TV's CompositePort, establishes connection.

**Cable is instantiated as child of each System**. Plug dangles freely until grabbed.

---

## Phase 8: Spawn Menu

**Goal**: VR menu to spawn TVs, Systems, and Cartridges.

**Create**:
- `RetroVR/Scenes/UI/spawn_menu.tscn`
- `RetroVR/Scripts/UI/spawn_menu.gd`

**Approach**: `SubViewport` rendered on a QuadMesh that appears in front of the player. 3 tabs (Systems, Cartridges, TVs) with GridContainer of items. `XRToolsFunctionPointer` ray interacts with the SubViewport. Clicking spawns the selected object.

**Activation**: Left controller menu button toggles the spawn menu.

---

## Phase 9: VR Input Mapping

**Goal**: Map XR controller buttons/sticks to libretro joypad so games are playable.

**Create**:
- `RetroVR/Scripts/vr_input_mapper.gd`

**Approach**: Reads XR controller input signals and injects synthetic `Input.action_press()` / `Input.action_release()` calls for the existing `RETRO_JOYPAD_*` actions. Has `mapping_active` flag — only active when a system is powered on and player is not holding an object.

**Mapping (right controller)**:
- Thumbstick → D-pad (RETRO_JOYPAD_UP/DOWN/LEFT/RIGHT)
- A button → RETRO_JOYPAD_A
- B button → RETRO_JOYPAD_B
- Trigger → RETRO_JOYPAD_R2
- Grip → RETRO_JOYPAD_R

---

## Phase 10: Scene Cleanup & Integration

**Goal**: Remove old arcade cabinet, build a VR room.

**Modify**:
- `RetroVR/Scenes/MainScene.tscn` — remove `magic-deniro-80-hor`, remove old `libretro.gd` attachment, add floor (StaticBody3D + PlaneMesh), WorldEnvironment, pre-place one TV + NES System + cartridge for immediate testing

**Remove** (no longer needed):
- `RetroVR/Scripts/libretro.gd` — logic moved to `system.gd` + `system_manager.gd`

---

## Verification (End-to-End)
1. Run RetroVR with headset connected
2. Press menu button → spawn menu appears
3. Spawn a TV, an NES System, and a cartridge
4. Pick up cartridge → insert into system's slot
5. Pick up cable plug from system → drag to TV's composite port
6. Press power button on system → libretro starts, game renders on TV screen
7. Audio is spatial from TV position
8. Use right controller thumbstick + buttons to play the game
9. Press power button again → stops
10. Remove cartridge → system clears ROM path

## New Files Summary
| File | Purpose |
|---|---|
| `RetroVR/Scripts/locomotion.gd` | Smooth locomotion + teleport arc (if custom, not XR Tools built-in) |
| `RetroVR/Scripts/system_manager.gd` | Autoload: enforces singleton libretro constraint |
| `RetroVR/Scripts/Objects/tv.gd` | TV: screen mesh, composite port |
| `RetroVR/Scripts/Objects/system.gd` | System: power/reset, core binding, connections |
| `RetroVR/Scripts/Objects/cartridge.gd` | Cartridge: ROM path carrier |
| `RetroVR/Scripts/Objects/vr_button.gd` | Reusable VR pressable button |
| `RetroVR/Scripts/Objects/verlet_rope.gd` | Verlet rope physics |
| `RetroVR/Scripts/Objects/cable_plug.gd` | Grabbable cable plug |
| `RetroVR/Scripts/UI/spawn_menu.gd` | Spawn menu controller |
| `RetroVR/Scripts/vr_input_mapper.gd` | XR → libretro input mapping |
| `RetroVR/Scenes/Objects/tv.tscn` | TV scene |
| `RetroVR/Scenes/Objects/system.tscn` | Base system scene |
| `RetroVR/Scenes/Objects/system_nes.tscn` | NES variant |
| `RetroVR/Scenes/Objects/cartridge.tscn` | Cartridge scene |
| `RetroVR/Scenes/Objects/cable.tscn` | Cable + plug assembly |
| `RetroVR/Scenes/UI/spawn_menu.tscn` | Spawn menu |
