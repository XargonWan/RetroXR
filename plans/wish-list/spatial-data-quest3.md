# Spatial Data — Passthrough Object Placement

*Rewritten 2026-07-26. Supersedes the 2026-03-27 draft, whose central risk ("the API may
not be exposed in Godot 4.5") is resolved — see "Corrections to the March draft" at the end.*

## Goal
In passthrough, let the user place TVs, consoles and other objects on real-world surfaces,
and have those placements still be there tomorrow.

## Verified current state (2026-07-26)

**Passthrough works, in its own scene.** `PassthroughScene.tscn` is a 34-line stub: player
rig, a 100×100 invisible floor, one directional light, a transparent `WorldEnvironment`.
`passthrough_init.gd` sets `XR_ENV_BLEND_MODE_ALPHA_BLEND` and `transparent_bg`. It is
reachable from the spawn menu's "Passthrough AR" room card (`spawn_menu.gd:4262-4266`),
gated on `SceneManager.is_passthrough_supported()`.

**Spawning already works there; persistence does not.** The spawn menu lives on the player
rig (`player_rig.tscn:112-120`), so it comes along into every scene, and `_place_spawned()`
parents into `get_tree().current_scene` (`spawn_menu_controller.gd:766-775`). But save/load
is hard-gated to the arcade — `spawn_menu_controller.gd:201` and the auto-save in
`scene_manager.gd:82-84` — and `ScenePersistence` writes only to `user://scenes/arcade/`.
So today you can spawn a TV in passthrough and it evaporates on scene change.

**No plane detection.** Both enabling settings are off in `project.godot`:
`xr/openxr/extensions/meta/scene_api = false`, `xr/openxr/extensions/spatial_entity/* = false`.

**Two working APIs are already in the tree** (both confirmed present via a headless
`ClassDB` probe against Godot 4.7 + this project):

| | Meta / vendors path | Core / cross-vendor path |
|---|---|---|
| Ships in | `addons/godotopenxrvendors` 5.1.0 | Godot 4.7 core |
| Enable with | `xr/openxr/extensions/meta/scene_api` (+ `meta/anchor_api`) | `xr/openxr/extensions/spatial_entity/enabled` + `enable_plane_tracking` |
| Planes | `OpenXRFbSceneManager` — `auto_create`, `create_scene_anchors()`, `get_anchor_node()`, `request_scene_capture()`, `is_scene_capture_supported()`; signals `openxr_fb_scene_anchor_created` / `_scene_data_missing` / `_scene_capture_completed` | `OpenXRPlaneTracker` (extends `OpenXRSpatialEntityTracker`) — `bounds_size`, `plane_alignment`, `plane_label`, `get_mesh()`, `get_shape()`, signal `mesh_changed`; reachable via `XRServer.get_trackers()` and bindable to an `XRAnchor3D` |
| Anchors | `OpenXRFbSpatialAnchorManager` (persistent, UUID-keyed) | `enable_spatial_anchors` / `enable_persistent_anchors`, `OpenXRAnchorTracker` |
| Quest 3 mesh | `OpenXRMetaSpatialEntityMeshExtension` | `OpenXRSpatialComponentMesh` |
| Runtime support | certain on Meta | **unverified on the Quest runtime** — Phase 0 settles it |

Enabling `meta/scene_api` is also what makes the vendors plugin inject
`com.oculus.permission.USE_SCENE` / `USE_ANCHOR_API` into the manifest.

## Phases

### Phase 0 — Capability probe (do this first; no new files)
Flip `meta/scene_api = true` and `meta/anchor_api = true` in `project.godot`, export, and on
device print:
- `OpenXRFbSceneManager.is_scene_capture_supported()` / `is_scene_capture_enabled()`
- `OpenXRSpatialEntityExtension.supports_capability(...)` for plane tracking + anchors

Whichever path reports support wins, and every later phase is written against it. Prefer the
core path if it works — it's vendor-neutral and needs no addon. Assume the Meta path
otherwise. Do not write `spatial_manager.gd` before this answers.

### Phase 1 — Planes in the passthrough scene
Add scene understanding to `PassthroughScene.tscn`:
- Meta path: drop in an `OpenXRFbSceneManager` with `auto_create = true` and a
  `default_scene` that visualises one plane; it spawns an anchor node per Room Setup entity.
  On `openxr_fb_scene_data_missing`, call `request_scene_capture()` to send the user to Room
  Setup.
- Core path: watch `XRServer` for `OpenXRPlaneTracker`s and spawn an `XRAnchor3D` per plane,
  taking geometry straight from `get_mesh()` and collision from `get_shape()`.

Either way this is thin glue, not the plane bookkeeping the old draft imagined. Visual: a
faint wireframe or ~10% alpha overlay, and a toggle to hide it once placement is done.

### Phase 2 — Make passthrough a real room
Placement is pointless while nothing survives a scene change. Generalise persistence off the
arcade:
- `ScenePersistence` takes a room id instead of hardcoding `user://scenes/arcade/`
  (`SAVE_DIR`, `ARCADE_DIR`, `MANIFEST_FILE`), giving passthrough its own slot dir.
- Lift the `current_scene_id == "arcade"` gates in `spawn_menu_controller.gd:201` and
  `scene_manager.gd:82-84` to "any room that declares persistence".
- Passthrough gets at least one slot so a layout can be saved and reloaded.

World-space coordinates are fine at this stage — they're correct as long as the guardian
origin doesn't move.

### Phase 3 — Snap and anchor persistence (the payoff)
- On drop, raycast from the pickable to the nearest plane collider and snap the object to the
  surface, reusing the existing `XRToolsPickable` drop path (`snap_highlight.gd` already does
  proximity highlighting for snap zones and is the model to follow).
- Persist placement as a **spatial anchor UUID + local offset**, not a world transform, via
  `OpenXRFbSpatialAnchorManager` (or `enable_persistent_anchors` on the core path). That's
  what makes "my TV is on the real table" survive a re-centre, a guardian redraw, and a
  reboot — the thing plain world coordinates cannot do.
- Fall back to world-space when anchors are unsupported, so the feature degrades instead of
  breaking.

## Files

Modify:
- `RetroVR/project.godot` — the enabling settings above
- `RetroVR/Scenes/PassthroughScene.tscn` — scene manager / plane visualiser
- `RetroVR/Scripts/Data/scene_persistence.gd` — per-room save dirs
- `RetroVR/Scripts/Data/scene_manager.gd` — persistence gate
- `RetroVR/Scripts/UI/spawn_menu_controller.gd` — persistence gate

New (paths follow the current foldered `Scripts/` layout):
- `RetroVR/Scripts/Data/spatial_manager.gd` — capability detection + plane bookkeeping
- `RetroVR/Scripts/Objects/spatial_plane.gd` — plane visual + collider + snap target

## Risks
- **Runtime support for the core path is unverified** on Quest — Phase 0 exists to settle it.
- **Perf.** The Quest is already CPU-bound (120 Hz target + GDScript verlet cables saturate
  the main thread). Plane overlays plus passthrough plus an emulator is a real budget
  question; measure before adding per-frame plane logic.
- **Room Setup is a hard prerequisite.** With no room scanned there are no planes;
  `scene_data_missing` → `request_scene_capture()` is the only recovery, and it yanks the
  user out to the system UI.
- **Guardian re-centring** moves world space under any non-anchored object. Phase 3's anchor
  UUIDs are the mitigation, which is why Phase 3 shouldn't be skipped.
- Plane quality varies with lighting and surface type; expect coarse rectangles, not furniture.

## Verification
1. Phase 0: on-device log line naming which API reported support.
2. Phase 1: passthrough scene with plane overlays on real walls/floor/table — capture a
   **screencap from the headset** (video, since it's head-motion dependent), not a headless run.
3. Phase 2: spawn a TV in passthrough, switch to arcade and back, TV is still there.
4. Phase 3: drop a TV near a real table → snaps to the surface. Re-centre the guardian and
   relaunch the app → still on the table.

## Corrections to the March draft
- The core risk ("may need a GDExtension plugin or direct OpenXR calls") is resolved — both
  APIs above already exist in this tree.
- The setting names it gave (`openxr/extensions/meta/scene_capture`,
  `.../spatial_entity`) do not exist; the real ones are `xr/openxr/extensions/meta/scene_api`
  and `xr/openxr/extensions/spatial_entity/*`.
- **"Quest 2 lacks scene understanding" is wrong.** Meta's Scene API / Room Setup planes work
  on Quest 2 — the export preset already ships `quest_2_support=1`. Quest 3-only features are
  the automatic room scan and the scene mesh/depth. Gate on `is_scene_capture_supported()`,
  not on a headset ID in `xr_init.gd`.
- Its Phase 3 ("merge passthrough into MainScene, toggle room geometry") is obsolete: the repo
  went multi-scene (`arcade` / `den` / `passthrough` / `test` in `scene_manager.gd:11-16`) and
  the passthrough room card already exists. Merging would fight that.
- Its "no anchor persistence, standard world-space coordinates" is the decision that made the
  feature not worth building; Phase 3 reverses it.
- Its phase order put snap mechanics before the room could keep anything. Reversed.
- It targeted Godot 4.5; the project is on 4.7. `Scripts/` is now foldered, so its two new
  file paths were wrong.
