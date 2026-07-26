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
| Runtime support | verified working | **verified working** — Quest 3, Oculus runtime 207.65.0, OpenXR 1.1.54 |

Enabling `meta/scene_api` is also what makes the vendors plugin inject
`com.oculus.permission.USE_SCENE` / `USE_ANCHOR_API` into the manifest.

## Phases

### Phase 0 — Capability probe — **DONE 2026-07-26**
Ran `Tools/spatial_probe.tscn` on a Quest 3 (Oculus runtime 207.65.0, OpenXR 1.1.54) via the
`QuestSpatialProbe` export preset. **Verdict: take the core path.**

| Query | Result |
|---|---|
| `supports_capability(CAPABILITY_PLANE_TRACKING)` | true |
| `supports_capability(CAPABILITY_ANCHOR)` | true |
| `OpenXRSpatialPlaneTrackingCapability.is_supported()` | true |
| `OpenXRSpatialAnchorCapability.is_spatial_anchor_supported()` | true |
| `OpenXRSpatialAnchorCapability.is_spatial_persistence_supported()` | true |
| marker tracking (QR / micro-QR / ArUco / AprilTag) | false — all four |
| `OpenXRFbSpatialEntityExtension.is_spatial_entity_supported()` | true (fallback also fine) |
| `OpenXRFbSceneCaptureExtension.is_scene_capture_supported()` | true, `is_scene_capture_enabled()` false |

With `enable_builtin_plane_detection` on, Godot published **31 `OpenXRPlaneTracker`s (36
trackers total) with no discovery code written at all** — 9 carried real geometry
(0.92×2.03, 0.87×2.06, 1.73×2.32, 2.41×1.51, 1.85×1.00, 0.73×2.04 m and two ~0.45 m squares:
walls, floor/ceiling and two small surfaces), the rest reported zero bounds. Frame rate held
at ~71.5 fps against the 72 Hz target in an otherwise empty scene.

Three things the probe taught us that the phases below now assume:

1. **Spatial data needs Horizon OS consent, not just an Android permission.** `meta/scene_api`
   injects `com.oculus.permission.USE_SCENE`, but it is a *runtime* permission that installs
   `granted=false`, and even after `adb shell pm grant` the shell raises its own "Allow … to
   access your spatial data?" dialog. Until it is answered the app **does not launch at all** —
   the shell caches the launch ("Launch is blocked because: a Reprojected OS dialog is
   currently showing"). Plan for a first-run consent step; a denied grant looks exactly like
   an empty room. `USE_ANCHOR_API` is granted automatically.
2. **Semantic labels came back empty on every plane.** `get_plane_label()` was `""` across all
   31, so `COMPONENT_TYPE_PLANE_SEMANTIC_LABEL` is not populated by the built-in path. Snapping
   cannot say "this is a table" yet — it has to work off `plane_alignment` + bounds, or drive
   discovery manually and request the label component.
3. **Built-in detection is a project-wide switch.** `enable_builtin_plane_detection` is a
   project setting, so the arcade and den would run discovery too. On an already CPU-bound
   scene that is not free. The settings are currently feature-gated to `.spatialprobe` so only
   the probe preset gets them; Phase 1 must either accept the cost project-wide or drive
   discovery by hand (`create_spatial_context` + `OpenXRSpatialPlaneTrackingCapability.start_entity_discovery`)
   so it runs only in the passthrough room.

### Phase 1 — Planes in the passthrough scene
Watch `XRServer` for `OpenXRPlaneTracker`s and spawn a visual + collider per plane, taking
geometry from `get_mesh()` and collision from `get_shape(thickness)`. The probe proves the
trackers arrive on their own, so this is presentation, not discovery.

Decide first whether to keep `enable_builtin_plane_detection` (simple, but project-wide) or
run discovery manually so it is scoped to passthrough — see point 3 above. Ungate the
`.spatialprobe` settings in `project.godot` as part of this phase, and add the first-run
consent request.

Visual: a faint wireframe or ~10% alpha overlay, and a toggle to hide it once placement is
done. With labels empty, distinguish surfaces by `plane_alignment` plus bounds (a 2.4×1.5 m
horizontal plane is the floor; ~0.9×2.0 m verticals are walls).

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
- ~~Runtime support for the core path is unverified~~ — settled in Phase 0: supported.
- **Consent is a launch-blocker, not just a feature gate.** An unanswered spatial-data dialog
  prevents the app from starting at all, and the failure mode is silent (cached launch). Any
  automated/on-device testing has to answer it once per package.
- **Perf.** The Quest is already CPU-bound (120 Hz target + GDScript verlet cables saturate
  the main thread). Plane detection alone held ~71.5 fps in an *empty* scene, which is
  encouraging but says nothing about the arcade; measure there before enabling it project-wide.
- **Room Setup is a hard prerequisite.** With no room scanned there are no planes;
  `scene_data_missing` → `request_scene_capture()` is the only recovery, and it yanks the
  user out to the system UI.
- **No semantic labels** from the built-in path, so surface classification is geometric
  guesswork until manual discovery requests the label component.
- **Guardian re-centring** moves world space under any non-anchored object. Phase 3's anchor
  UUIDs are the mitigation, which is why Phase 3 shouldn't be skipped.
- Plane quality varies with lighting and surface type; expect coarse rectangles, not furniture.

## Probe harness (how to re-run Phase 0)
`Tools/spatial_probe.tscn` ships as its own app so it never disturbs an installed RetroVR:
export preset **QuestSpatialProbe** (`com.xenu.retrovr.spatialprobe`) declares the custom
feature `spatialprobe`, which selects `run/main_scene.spatialprobe` and the gated `[xr]`
settings. The spatial permissions ride on the preset's `permissions/custom_permissions`
rather than on a global setting, because the vendors plugin's manifest injection reads
`meta/scene_api` **without** feature-tag overrides — gating the setting alone would drop them.
Verified end to end: gated build still reports 36 trackers / 31 planes. Nothing in the normal
Quest build changes.

```bash
"$godot" --headless --path "$proj" --export-debug "QuestSpatialProbe" probe.apk
adb install -r probe.apk
adb shell pm grant com.xenu.retrovr.spatialprobe com.oculus.permission.USE_SCENE
adb shell pm grant com.xenu.retrovr.spatialprobe horizonos.permission.USE_SCENE
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close
adb shell setprop debug.oculus.guardian_pause 1
adb shell monkey -p com.xenu.retrovr.spatialprobe 1
adb logcat -s 'godot:*' | grep '\[spatial\]'
```

Traps that cost a cycle each, all confirmed here:
- **A scene path on the command line does not work in an export.** `command_line/extra_args`
  bakes into `_cl_` fine, but the runtime aborts with *"compiled without support for path
  overrides"* and re-logs it every frame — 2.1 GB of logcat in 100 s. Use a feature-tagged
  `run/main_scene` instead.
- **`adb logcat -s godot:*` unquoted is glob-eaten by the shell**, silently disabling the
  filter. Quote it: `-s 'godot:*'`.
- **The first launch after install will be swallowed** by the spatial-data consent dialog
  (and possibly a Guardian dialog). `adb shell dumpsys activity activities | grep
  GrantPermissionsActivity` shows it; a human has to answer it once. `adb exec-out screencap
  -p` is the fastest way to see what is on the panel.
- **An APK's `AndroidManifest.xml` is binary XML with UTF-16LE strings**, so
  `grep -a USE_SCENE` on it returns nothing whether or not the permission is there. Decode
  first (`data.count("USE_SCENE".encode("utf-16-le"))`) or the check silently lies.
- The probe prints an `alive t=… frames=…` heartbeat so "process died" is distinguishable
  from "process running but not ticking".

## Verification
1. Phase 0: on-device log line naming which API reported support. **Done — see Phase 0 above.**
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
