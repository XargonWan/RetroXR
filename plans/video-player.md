# Video Player — VCR Media Player

## Goal
Add a video player system that follows the same physical metaphor as game consoles: VCR tapes spawn from a "videos" folder, insert into a VCR player, which connects to TVs via the existing cable/plug system.

## Current State
- **System/TV/Cable pattern** fully implemented and working:
  - `system.gd` — Console with cartridge slot, cable, power button, screen mesh assignment
  - `tv.gd` — TV with CompositePort snap zone, screen mesh, ambilight
  - `cable_plug.gd` — Grabbable plug that snaps into TV
- **Books pattern** provides content-from-folder template:
  - `rom_library.gd` — Scans folders by extension, returns `{path, label}` arrays
  - Spawn menu has a tab for books, spawns `PDFBook` instances
- **Godot has `VideoStreamPlayer`** built-in (supports OGV/Theora natively, MP4 via GDExtension)

## Implementation Plan

### Phase 1: Video Content Discovery
1. **Add video scanning to `rom_library.gd`** (or new `video_library.gd`):
   - Scan `%USERPROFILE%/retrovr/videos/` (Windows) or equivalent Android path
   - Supported extensions: `.ogv` (native Godot), `.mp4` (if GDExtension available)
   - Return `{path: String, label: String}` array (same pattern as ROMs/books)
2. **Add "Videos" tab to spawn menu**:
   - List discovered videos with spawn button
   - Spawns VCR tape objects

### Phase 2: VCR Tape Object
1. **Create `vcr_tape.gd`** (analogous to `cartridge.gd`):
   - Extends `XRToolsPickable` (RigidBody3D)
   - Stores `video_path: String` and `video_label: String`
   - In "vcr_tape" group (for snap zone filtering)
   - Visual: VHS cassette shaped mesh (BoxMesh ~0.19x0.025x0.10m with label)
2. **Create `vcr_tape.tscn`**:
   - RigidBody3D with collision, mesh, grab points
   - Label3D showing video name

### Phase 3: VCR Player Object
1. **Create `vcr_player.gd`** (analogous to `system.gd`):
   - Extends `XRToolsPickable` (same as RetroSystem)
   - Has a **TapeSlot** (`XRToolsSnapZone`, `snap_require = "vcr_tape"`)
   - Has a **CableAttachPoint** for cable (reuse `cable.tscn`)
   - Has **buttons**: Play, Pause, Stop (Area3D with VRButton behavior)
   - Stores reference to connected TV via cable plug
   - **Key difference from system.gd**: Uses `VideoStreamPlayer` instead of Libretro node
2. **Video display pipeline** (reuse screen mesh pattern):
   - When cable plugged into TV: `tv.get_screen_mesh()` → assign video texture to mesh material
   - `VideoStreamPlayer` outputs to a `ViewportTexture` or directly to the mesh's material
   - Reuse the emission-based display: `StandardMaterial3D.TEXTURE_EMISSION`
3. **Playback controls**:
   - Play button: Start/resume `VideoStreamPlayer`
   - Pause button: Toggle pause
   - Stop button: Stop and rewind
   - Optional: Fast-forward/rewind via VR stick while attached

### Phase 4: Cable Integration (Reuse Existing)
1. **Spawn cable in `vcr_player.gd._ready()`** (copy pattern from `system.gd._spawn_cable()`):
   - VerletRope from CableAttachPoint to CablePlug
   - Plug is in "composite_plug" group (same as system cables)
   - TV doesn't care what's on the other end — it just calls back to the connected object
2. **Modify `tv.gd`** slightly:
   - `_on_plug_snapped()` currently calls `plug.get_system()` — generalize to `plug.get_source()`
   - Source can be RetroSystem OR VCRPlayer
   - Both implement a common interface: `on_tv_connected(tv)`, `on_tv_disconnected()`, `set_screen_enabled()`

### Phase 5: Persistence & Scene Save
1. **Extend `scene_persistence.gd`**:
   - Add VCRPlayer and VCRTape to serializable types
   - Save: video_path, connected_tv, inserted_tape, playback position
   - Restore: re-spawn VCR player, reconnect cable, reinsert tape

## Key Files to Modify
- `RetroVR/Scripts/Data/rom_library.gd` — Add `scan_videos()` and `ensure_videos_root()`
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — Add Videos tab, spawn VCR tapes
- `RetroVR/Scripts/Objects/tv.gd` — Generalize plug source (system OR VCR player)
- `RetroVR/Scripts/Objects/cable_plug.gd` — `get_source()` instead of `get_system()`
- `RetroVR/Scripts/Data/scene_persistence.gd` — Add VCR types

## New Files
- `RetroVR/Scripts/Objects/vcr_player.gd` — VCR player controller
- `RetroVR/Scripts/Objects/vcr_tape.gd` — VCR tape (video cartridge)
- `RetroVR/Scenes/Objects/vcr_player.tscn` — VCR player scene
- `RetroVR/Scenes/Objects/vcr_tape.tscn` — VCR tape scene
- `RetroVR/Scripts/Data/video_library.gd` — Video folder scanning (or add to rom_library)

## Dependencies
- **OGV/Theora**: Native Godot support, no extra dependencies
- **MP4/H.264**: Requires a GDExtension like `godot-videodecoder` or FFmpeg-based plugin
- Consider starting with OGV only, add MP4 later

## Verification
1. Place `.ogv` files in `retrovr/videos/`
2. Open spawn menu → Videos tab → see listed videos
3. Spawn a VCR tape, spawn a VCR player
4. Insert tape into VCR player's slot
5. Plug VCR cable into TV
6. Press Play → video displays on TV screen with ambilight reacting
7. Pause/Stop buttons work
8. Save scene, reload → VCR player and tape restore correctly
