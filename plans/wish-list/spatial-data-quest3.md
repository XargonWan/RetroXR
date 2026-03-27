# Spatial Data — Quest 3 Passthrough Object Placement

## Goal
Use Quest 3 scene understanding (plane detection) to let users place TVs, consoles, and other objects on real-world surfaces in passthrough mode.

## Current State
- **Passthrough exists** (`passthrough_init.gd`): Meta passthrough with `XR_ENV_BLEND_MODE_ALPHA_BLEND`, transparent background
- Passthrough is scene-switch based (separate `PassthroughScene.tscn`), not integrated into the main arcade
- **No plane detection** implemented yet
- Quest 2 is NOT supported (Quest 3 only for scene understanding)

## Implementation Plan

### Phase 1: OpenXR Scene Understanding Integration
1. **Enable OpenXR scene extensions** in `project.godot`:
   - `openxr/extensions/meta/scene_capture = true`
   - `openxr/extensions/meta/spatial_entity = true`
2. **Create `spatial_manager.gd`** script that:
   - Requests scene capture permission via the Meta scene API
   - Listens for `XRServer` plane events
   - Maintains a dictionary of detected planes (floor, walls, tables, ceiling) with their transforms and extents

### Phase 2: Plane Visualization & Snap Placement
1. **Create `spatial_plane.gd`** (visual representation of detected planes):
   - Semi-transparent mesh overlay on each detected plane
   - Collision shape matching plane extents
   - Snap zone or placement target for pickable objects
2. **Modify pickable objects** (TVs, systems, books):
   - When in passthrough mode, objects can be "placed" on spatial planes
   - Gravity-snap behavior: release object near a plane → it snaps to the surface
   - Use existing `XRToolsPickable` drop mechanics + raycast to nearest plane

### Phase 3: Passthrough-Arcade Hybrid
1. **Merge passthrough into MainScene** (not separate scene):
   - Toggle passthrough on/off via spawn menu option
   - When enabled: hide room geometry (walls, floor, ceiling), enable spatial planes
   - When disabled: show room geometry, hide spatial planes
2. **Keep existing static room** as default experience
3. **Object positions in passthrough mode** use standard world-space coordinates — no anchor persistence

## Key Files to Modify
- `RetroVR/project.godot` — Enable Meta scene extensions
- `RetroVR/Scripts/passthrough_init.gd` — Extend with scene understanding
- `RetroVR/Scripts/xr_init.gd` — Detect Quest 3 vs Quest 2 capabilities

## New Files
- `RetroVR/Scripts/spatial_manager.gd` — Plane detection orchestrator
- `RetroVR/Scripts/Objects/spatial_plane.gd` — Plane visualization + snap target

## Dependencies
- Godot 4.5+ with OpenXR Meta scene understanding extensions
- Quest 3 hardware (Quest 2 lacks scene understanding)
- User must complete Room Setup in Meta system settings

## Risks
- OpenXR scene understanding API may not be fully exposed in Godot 4.5 yet — may need a GDExtension plugin or direct OpenXR calls
- Plane detection quality varies by room lighting and surface types

## Verification
1. Enable passthrough mode in-game
2. Detected planes should appear as semi-transparent overlays
3. Pick up a TV, drop it near a real table → it should snap to the table surface
