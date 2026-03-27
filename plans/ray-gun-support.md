# Ray-Gun Support — Light Gun Controller

## Goal
Support light gun games (Duck Hunt, etc.) by mapping a VR controller's aim direction to screen X,Y coordinates passed to libretro's lightgun input device.

## Current State
- **InputHandler C++ already has lightgun stubs**:
  - `SetLightgunPosition(port, x, y)` — X,Y in [-16384, 16384] range
  - `SetLightgunIsOffscreen(port, bool)` — whether gun points off-screen
  - `SetLightgunButtons(port, buttons)` — trigger, start, etc.
  - `StateCallback` routes `RETRO_DEVICE_LIGHTGUN` queries to these values
- **No GDScript → C++ bridge** for lightgun — Wrapper doesn't expose these methods
- **VR controllers have precise aim tracking** via `XRController3D.global_transform`
- **TV screen mesh** has known world-space position and dimensions

## Implementation Plan

### Phase 1: Expose Lightgun API to GDScript
1. **Add methods to `Libretro` node** (C++):
   ```cpp
   void SetLightgunPosition(int port, int x, int y);
   void SetLightgunIsOffscreen(int port, bool offscreen);
   void SetLightgunButton(int port, int button_id, bool pressed);
   ```
   - These forward to `Wrapper` → `InputHandler`
   - Bind in `_bind_methods()` for GDScript access
2. **Add `SetControllerPortDevice(port, RETRO_DEVICE_LIGHTGUN)`** support:
   - Already exists on Libretro node
   - Core must be told port is a lightgun device

### Phase 2: Ray-Gun VR Object
1. **Create `ray_gun.gd`**:
   - Extends `XRToolsPickable` — grabbable gun-shaped object
   - When held, casts a ray from the barrel forward
   - Visual: Gun-shaped mesh (simple pistol/zapper shape)
   - Laser pointer visual (thin cylinder or `RayCast3D` with debug line)
   - Trigger input: VR trigger button → lightgun trigger
2. **Create `ray_gun.tscn`**:
   - RigidBody3D with gun mesh, collision, grab point at grip
   - RayCast3D from barrel tip, forward direction
   - LaserDot (small sphere at raycast hit point)

### Phase 3: Screen Coordinate Mapping
1. **Raycast → Screen UV calculation**:
   ```gdscript
   # Cast ray from gun barrel
   var ray_origin = barrel_tip.global_position
   var ray_dir = -barrel_tip.global_basis.z  # forward

   # Intersect with TV screen plane
   var screen_mesh: MeshInstance3D = connected_tv.get_screen_mesh()
   var plane = Plane(screen_mesh.global_basis.z, screen_mesh.global_position)
   var hit = plane.intersects_ray(ray_origin, ray_dir)

   # Convert world hit to local UV [0,1]
   var local = screen_mesh.global_transform.affine_inverse() * hit
   var u = (local.x / screen_width) + 0.5  # center-origin to corner-origin
   var v = (local.y / screen_height) + 0.5

   # Convert UV to libretro range [-16384, 16384]
   var lx = int((u * 2.0 - 1.0) * 16384)
   var ly = int((v * 2.0 - 1.0) * 16384)
   ```
2. **Off-screen detection**: If ray doesn't hit screen plane or UV is outside [0,1], set `offscreen = true`
3. **Call per frame** in `_physics_process()`:
   ```gdscript
   libretro_node.SetLightgunPosition(port, lx, ly)
   libretro_node.SetLightgunIsOffscreen(port, is_offscreen)
   ```

### Phase 4: Attach Gun to System
1. **Attachment mechanism** (similar to VRInputMapper but for lightgun):
   - Gun needs to know which system/TV it's aiming at
   - Option A: Auto-detect — raycast finds TV, look up connected system
   - Option B: Manual — gun has a cable that plugs into system (physical metaphor)
   - **Recommended**: Option A (simpler, more intuitive — just point and shoot)
2. **Port assignment**:
   - Lightgun typically uses port 1 (player 1's gun) or port 0
   - Call `SetControllerPortDevice(port, RETRO_DEVICE_LIGHTGUN)` when gun activates
   - Some cores expect lightgun on port 1 specifically

### Phase 5: Spawn & Persistence
1. **Add "Ray Gun" to spawn menu** (accessories/controllers section)
2. **Scene persistence**: Save gun position, which system it's associated with
3. **Haptic feedback**: Pulse VR controller on trigger pull for recoil feel

## Key Files to Modify
- `libretro-godot/src/Libretro.hpp/.cpp` — Bind lightgun methods to GDScript
- `libretro-godot/src/Wrapper.hpp/.cpp` — Forward lightgun calls to InputHandler
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — Add ray gun spawn option
- `RetroVR/Scripts/Data/scene_persistence.gd` — Ray gun serialization

## New Files
- `RetroVR/Scripts/Objects/ray_gun.gd` — Gun controller script
- `RetroVR/Scenes/Objects/ray_gun.tscn` — Gun scene with mesh and raycast

## Lightgun Button IDs (libretro API)
| ID | Name | VR Mapping |
|----|------|------------|
| 0 | RETRO_DEVICE_ID_LIGHTGUN_TRIGGER | VR trigger |
| 1 | RETRO_DEVICE_ID_LIGHTGUN_CURSOR | A button |
| 2 | RETRO_DEVICE_ID_LIGHTGUN_TURBO | B button |
| 3 | RETRO_DEVICE_ID_LIGHTGUN_PAUSE | Menu/Start |
| 4 | RETRO_DEVICE_ID_LIGHTGUN_START | Start |

## Verification
1. Load a lightgun game (e.g., Duck Hunt on NES with appropriate core)
2. Spawn a ray gun from the menu
3. Pick up gun, point at TV — laser dot visible on screen
4. Pull trigger → game registers shot at correct screen position
5. Point away from TV → game registers off-screen (reload in Duck Hunt)
6. Haptic feedback on trigger pull
