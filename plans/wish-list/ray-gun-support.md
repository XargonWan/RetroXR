# Ray-Gun Support — Light Gun Controller & Controller Port System

## Goal
Add physical controller objects (regular joypad and light gun) that plug into numbered ports on the front of each system, establishing the foundational controller-port metaphor that multiplayer will later build on.

## Current State
- **InputHandler C++ already has lightgun stubs**:
  - `SetLightgunPosition(port, x, y)` — X,Y in [-16384, 16384] range
  - `SetLightgunIsOffscreen(port, bool)` — whether gun points off-screen
  - `SetLightgunButtons(port, buttons)` — trigger, start, etc.
  - `StateCallback` routes `RETRO_DEVICE_LIGHTGUN` queries to these values
- **No GDScript → C++ bridge** for lightgun — Wrapper doesn't expose these methods
- **VRInputMapper** currently attaches via button combo (Left X + Right A), with no physical metaphor
- **TV screen mesh** has known world-space position and dimensions

## System Controller Ports
Each RetroSystem gets **4 controller ports** on its front face, labeled 1, 2, 3, 4:
- Each port is an `XRToolsSnapZone` with `snap_require = "controller_plug"`
- Port snap zones glow/highlight when a compatible controller cable approaches
- Only one controller per port at a time
- Ports are placeholder geometry now (labeled slots) — visual models refined later

When a controller plug snaps into a port:
- The port slot highlights in the controller's color / player number color
- The system calls `SetControllerPortDevice(port_index, device_type)` on the Libretro node
- The controller begins routing its input to that port number

This system is shared by both regular joypad controllers and light guns (and any future controller types).

## Implementation Plan

### Phase 1: Expose APIs to GDScript (C++)
1. **Add lightgun methods to `Libretro` node**:
   ```cpp
   void SetLightgunPosition(int port, int x, int y);
   void SetLightgunIsOffscreen(int port, bool offscreen);
   void SetLightgunButton(int port, int button_id, bool pressed);
   ```
   - Forward to `Wrapper` → `InputHandler`
   - Bind in `_bind_methods()` for GDScript access
2. **Add joypad input-per-port methods** (replace hardcoded port 0):
   ```cpp
   void SetJoypadState(int port, int button_mask, int analog_lx, int analog_ly, int analog_rx, int analog_ry);
   ```
   - `Wrapper._process()` currently only routes to port 0; this enables per-port routing from GDScript

### Phase 2: System Controller Ports
1. **Modify `system.tscn`**: Add 4 `ControllerPort` snap zones to the front face:
   - `ControllerPort1`, `ControllerPort2`, `ControllerPort3`, `ControllerPort4`
   - Each is an `XRToolsSnapZone` with `snap_require = "controller_plug"` group
   - Each has a `Label3D` showing "1", "2", "3", "4"
   - Each has a placeholder `MeshInstance3D` (small rectangular recess)
2. **Modify `system.gd`**: Handle port snap/unsnap signals:
   - `_on_port_snapped(port_index, controller)`: call `SetControllerPortDevice(port_index, controller.device_type)`
   - `_on_port_released(port_index)`: call `SetControllerPortDevice(port_index, RETRO_DEVICE_NONE)`
   - Store `_plugged_controllers: Array[Node]` (4 slots, null if empty)
3. **Remove VRInputMapper button-combo attach**: The old Left X + Right A attach/detach combo is replaced by physically plugging in a controller. Delete or disable that attachment mechanism.

### Phase 3: Regular Controller Object
1. **Create `retro_controller.gd`**:
   - Extends `XRToolsPickable` (RigidBody3D, same as cartridges)
   - `device_type: int = RETRO_DEVICE_JOYPAD`
   - Has a **cable** (reuse `cable.tscn`): VerletRope from controller body to a `ControllerPlug`
   - `ControllerPlug` is in "controller_plug" group
   - In held state: maps VR controller buttons → `libretro_node.SetJoypadState(port, ...)`
   - Knows its port index from which snap zone it's plugged into
2. **Create `retro_controller.tscn`**:
   - Generic gamepad shape (BoxMesh placeholder for now)
   - CableAttachPoint at back, ControllerPlug at cable end
   - Grab point at center

### Phase 4: Ray Gun Object
1. **Create `ray_gun.gd`**:
   - Extends `XRToolsPickable`
   - `device_type: int = RETRO_DEVICE_LIGHTGUN`
   - Has a **cable** from gun body to a `ControllerPlug` (same "controller_plug" group as regular controllers)
   - When plugged into a port: calls `SetControllerPortDevice(port, RETRO_DEVICE_LIGHTGUN)` via system
   - When held: casts ray from barrel tip, reports lightgun position per frame
   - Trigger → `libretro_node.SetLightgunButton(port, LIGHTGUN_TRIGGER, true)`
2. **Create `ray_gun.tscn`**:
   - Gun-shaped mesh (pistol/zapper placeholder)
   - `RayCast3D` from barrel tip
   - `LaserDot` (small sphere at raycast hit point, only visible when plugged in and powered system)
   - CableAttachPoint at handle base

### Phase 5: Screen Coordinate Mapping (Light Gun)
1. **Raycast → libretro coordinates**:
   ```gdscript
   var screen_mesh: MeshInstance3D = _connected_system.get_connected_tv().get_screen_mesh()
   var plane = Plane(screen_mesh.global_basis.z, screen_mesh.global_position)
   var hit = plane.intersects_ray(barrel_tip.global_position, -barrel_tip.global_basis.z)

   if hit == null:
       libretro_node.SetLightgunIsOffscreen(port, true)
   else:
       var local = screen_mesh.global_transform.affine_inverse() * hit
       var u = (local.x / screen_width) + 0.5
       var v = (local.y / screen_height) + 0.5
       if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
           libretro_node.SetLightgunIsOffscreen(port, true)
       else:
           var lx = int((u * 2.0 - 1.0) * 16384)
           var ly = int((v * 2.0 - 1.0) * 16384)
           libretro_node.SetLightgunPosition(port, lx, ly)
           libretro_node.SetLightgunIsOffscreen(port, false)
   ```
2. **The gun resolves its system** via `_connected_system` — set when the controller plug snaps into a port

### Phase 6: Spawn & Persistence
1. **Add to spawn menu** — new "Controllers" section:
   - "Regular Controller" — spawns `retro_controller.tscn`
   - "Ray Gun" — spawns `ray_gun.tscn`
2. **Scene persistence** (`scene_persistence.gd`):
   - Save controller type, position, which system port it's plugged into
   - Restore on load: re-spawn controller, reconnect plug to correct port
3. **Haptic feedback**: Pulse VR controller on light gun trigger pull

## Key Files to Modify
- `libretro-godot/src/Libretro.hpp/.cpp` — Bind lightgun + per-port joypad methods
- `libretro-godot/src/Wrapper.hpp/.cpp` — Forward calls, replace port-0-only polling
- `RetroVR/Scenes/Objects/system.tscn` — Add 4 controller port snap zones to front
- `RetroVR/Scripts/Objects/system.gd` — Port snap/unsnap handlers, remove button-combo attach
- `RetroVR/Scripts/vr_input_mapper.gd` — Remove or disable old attach-combo logic
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — Controllers spawn section
- `RetroVR/Scripts/Data/scene_persistence.gd` — Controller serialization

## New Files
- `RetroVR/Scripts/Objects/retro_controller.gd` — Regular joypad object
- `RetroVR/Scenes/Objects/retro_controller.tscn` — Joypad scene with cable
- `RetroVR/Scripts/Objects/ray_gun.gd` — Light gun object
- `RetroVR/Scenes/Objects/ray_gun.tscn` — Gun scene with cable and raycast

## Lightgun Button IDs (libretro API)
| ID | Name | VR Mapping |
|----|------|------------|
| 0 | RETRO_DEVICE_ID_LIGHTGUN_TRIGGER | VR trigger |
| 1 | RETRO_DEVICE_ID_LIGHTGUN_CURSOR | A button |
| 2 | RETRO_DEVICE_ID_LIGHTGUN_TURBO | B button |
| 3 | RETRO_DEVICE_ID_LIGHTGUN_PAUSE | Menu/Start |
| 4 | RETRO_DEVICE_ID_LIGHTGUN_START | Start |

## Verification
1. Spawn a regular controller → pick it up → plug cable into system port 1 → game receives input on port 0 (libretro uses 0-indexed)
2. Spawn a ray gun → plug into port 2 → system registers port 1 as lightgun device
3. Load a lightgun game → aim gun at TV → laser dot visible on screen → trigger fires at correct position
4. Aim gun away from TV → registers off-screen
5. Two controllers plugged into ports 1 and 2 → 2-player game works locally
6. Save scene → reload → controllers and connections restore correctly
