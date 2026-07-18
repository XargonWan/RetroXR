## Shared spatial-audio tuning + occlusion for every RetroVR sound source.
##
## All device audio (the libretro emulator core, the VLC DVD/VCR, the CD/cassette
## players) streams live PCM into an AudioStreamGenerator on an AudioStreamPlayer3D.
## This class is the single place that tunes those players and applies dynamic
## occlusion, so the GDScript SpatialAudioEmitter (VLC devices) and system.gd (the
## C++-owned emulator player) sound identical without duplicating the numbers.
##
## Occlusion is cheap: one raycast from the listener (the active 3D camera — the
## XRCamera3D in VR) to the emitter per update. When something on the World layer
## blocks the line, the player's built-in distance low-pass cutoff is smoothly
## driven down so the sound muffles, exactly as it would behind a real cabinet.
## Volume is left untouched here — each device owns its own volume_db (TV knob).
class_name SpatialAudioPresets

# Physics layer the occlusion ray tests against ("World" = layer 1). Walls, floor
# and large static furniture live here; small pickables do not, so they don't
# self-occlude every source they pass in front of.
const OCCLUSION_MASK := 1

# Low-pass cutoff (Hz) the ray drives toward when the line to the listener is
# blocked. The open value is per-preset (`filter_cutoff`), so distance filtering
# still works normally when nothing is in the way.
const OCC_CUTOFF_BLOCKED := 600.0
# Exponential smoothing rate for the cutoff (higher = snappier). Smoothed to
# avoid an audible pop as you step in and out of the line of sight.
const OCC_LERP_SPEED := 8.0

# Meta keys stashed on the player so update_occlusion() is stateless to callers.
const _META_OPEN := "_sa_occ_open"     # unoccluded cutoff (the preset base)
const _META_CUR := "_sa_occ_cur"       # current smoothed cutoff

# ── Presets ───────────────────────────────────────────────────────────────────
# unit_size            reference distance (m) for full volume
# max_distance         distance (m) at which the source is silent
# panning_strength     stereo separation (1.0 = engine default)
# max_db               ceiling gain
# filter_cutoff/db     built-in distance low-pass (highs roll off with distance);
#                      cutoff doubles as the "open" target for occlusion
# area_mask            which Area3D reverb zones affect this source
# doppler              enable idle-step doppler pitch shift

## Console emulator audio, emanated from the connected TV.
const CABINET := {
	"attenuation_model": AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
	"unit_size": 3.0, "max_distance": 15.0, "panning_strength": 1.0, "max_db": 0.0,
	"filter_cutoff": 5000.0, "filter_db": -24.0, "area_mask": 1, "doppler": true,
}

## Handheld emulator audio, emanated from the device in your hands — intimate,
## short range so it doesn't carry across the room.
const HANDHELD := {
	"attenuation_model": AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
	"unit_size": 1.2, "max_distance": 6.0, "panning_strength": 1.0, "max_db": 0.0,
	"filter_cutoff": 6500.0, "filter_db": -18.0, "area_mask": 1, "doppler": true,
}

## Self-contained tabletop units (CD / cassette).
const TABLETOP := {
	"attenuation_model": AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
	"unit_size": 2.0, "max_distance": 12.0, "panning_strength": 1.0, "max_db": 0.0,
	"filter_cutoff": 5000.0, "filter_db": -24.0, "area_mask": 1, "doppler": true,
}

## Video decks (VCR / DVD), emanated from the connected TV.
const TV := {
	"attenuation_model": AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE,
	"unit_size": 3.0, "max_distance": 15.0, "panning_strength": 1.0, "max_db": 0.0,
	"filter_cutoff": 5000.0, "filter_db": -24.0, "area_mask": 1, "doppler": true,
}


## Apply a preset to an AudioStreamPlayer3D and seed the occlusion state. Safe to
## call more than once (e.g. every power-on).
static func apply(asp: AudioStreamPlayer3D, preset: Dictionary) -> void:
	if asp == null:
		return
	asp.attenuation_model = preset.get("attenuation_model", AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE)
	asp.unit_size = preset.get("unit_size", 2.0)
	asp.max_distance = preset.get("max_distance", 12.0)
	asp.panning_strength = preset.get("panning_strength", 1.0)
	asp.max_db = preset.get("max_db", 0.0)
	var cutoff: float = preset.get("filter_cutoff", 5000.0)
	asp.attenuation_filter_cutoff_hz = cutoff
	asp.attenuation_filter_db = preset.get("filter_db", -24.0)
	asp.area_mask = preset.get("area_mask", 1)
	asp.doppler_tracking = (
		AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
		if preset.get("doppler", true)
		else AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	)
	asp.set_meta(_META_OPEN, cutoff)
	asp.set_meta(_META_CUR, cutoff)


## Muffle the player when the listener's line of sight to it is blocked. Call once
## per (throttled) frame while the player is audible. `exclude` is a list of RIDs
## or CollisionObject3D nodes to ignore (the emitter's own device body).
static func update_occlusion(asp: AudioStreamPlayer3D, delta: float, exclude: Array = []) -> void:
	if asp == null or not asp.is_inside_tree() or not asp.playing:
		return
	var cam := asp.get_viewport().get_camera_3d()
	if cam == null:
		return
	var world := asp.get_world_3d()
	if world == null:
		return
	var open_cutoff: float = asp.get_meta(_META_OPEN, 5000.0)
	var q := PhysicsRayQueryParameters3D.create(cam.global_position, asp.global_position, OCCLUSION_MASK)
	q.exclude = _to_rids(exclude)
	var hit := world.direct_space_state.intersect_ray(q)
	var target := OCC_CUTOFF_BLOCKED if not hit.is_empty() else open_cutoff
	var cur: float = asp.get_meta(_META_CUR, open_cutoff)
	cur = lerpf(cur, target, clampf(delta * OCC_LERP_SPEED, 0.0, 1.0))
	asp.set_meta(_META_CUR, cur)
	asp.attenuation_filter_cutoff_hz = cur


# Normalize a mixed list of CollisionObject3D nodes / RIDs into an RID array for
# PhysicsRayQueryParameters3D.exclude.
static func _to_rids(items: Array) -> Array[RID]:
	var out: Array[RID] = []
	for it in items:
		if it is RID:
			out.append(it)
		elif it is CollisionObject3D:
			out.append(it.get_rid())
	return out
