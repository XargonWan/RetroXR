## MediaSlot — a reusable front-loading media bay (DVD disc, VHS tape, console
## disc/UMD). One node manages the whole insert/eject/grab lifecycle for a slot so
## the DVD player, VCR, console, and PSP don't each re-implement it.
##
## Design (see also the spike in git history): while loaded, the media is a FROZEN
## rigid child of the slot, so it rides the host through the scene graph with no
## per-frame code. Ride-in / ride-out are plain local-transform tweens. When a hand
## grabs it, XR-tools' own grab takes over and we just reparent it back to world so
## the grab driver isn't fighting the host's motion. A single host<->media collision
## exception is held for the whole loaded span (incl. the grab pull-away) so the
## partly-inside media never shoves the host.
##
## The host wires two signals:
##   inserted(media) — media accepted; read its path / update state here.
##   removed()       — media left (ejected, or pulled straight out); stop playback.
## and drives it with eject(), has_media(), get_media(), restore(media).
class_name MediaSlot
extends Node


## Media accepted into the slot (the insert ride has begun).
signal inserted(media: Node3D)
## Media has left the slot for good (ejected, or grabbed straight out).
signal removed()


## The body the media attaches to and is collision-excepted against (player/console).
@export var host: PhysicsBody3D
## Detection zone at the slot mouth; also a child of `host` so it rides with it.
@export var slot: XRToolsSnapZone
## Orientation of the media relative to the slot when loaded (IDENTITY = as-authored;
## a VHS tape lies flat, e.g. Basis(Vector3(1,0,0), -PI/2)).
@export var media_local_basis: Basis = Basis.IDENTITY
## How far past the mouth (into the body, along -Z) the media rides when seated.
@export var insert_depth: float = 0.10
## Insert / eject ride duration (seconds).
@export var ride_time: float = 0.9


enum State { EMPTY, LOADED, PARKED }
var _state: State = State.EMPTY
var _media: Node3D = null
var _holder: Node3D = null       # non-Area child of the slot the media parents under
var _tween: Tween = null
# The media's own freeze mode, restored when a hand takes it. While loaded we force
# STATIC so the physics server treats it as non-simulated scenery and it rides the
# host perfectly rigidly; KINEMATIC (the pickable default) drifts a couple of cm
# under host rotation because the server keeps re-integrating it.
var _orig_freeze_mode: int = RigidBody3D.FREEZE_MODE_KINEMATIC


func _ready() -> void:
	# A plain holder under the slot so the loaded media isn't a child of the Area3D
	# (avoids the zone re-detecting its own captured media).
	_holder = Node3D.new()
	_holder.name = "MediaHolder"
	if slot:
		slot.add_child(_holder)
		slot.has_picked_up.connect(_on_slot_captured)


func has_media() -> bool:
	return _media != null


func get_media() -> Node3D:
	return _media


## Slot-local pose at the mouth (flush with the slot origin).
func _mouth_pose() -> Transform3D:
	return Transform3D(media_local_basis, Vector3.ZERO)


## Slot-local pose seated inside the body.
func _seated_pose() -> Transform3D:
	return Transform3D(media_local_basis, Vector3(0.0, 0.0, -insert_depth))


# --- Capture / insert ---------------------------------------------------------

## The snap zone grabbed a dropped media. Take ownership on the next idle frame
## (deferred so we're clear of the zone's pick-up call stack).
func _on_slot_captured(media: Node3D) -> void:
	call_deferred("_accept", media, false)


## Programmatic insert for save / net restore: seat the media immediately with no
## ride and no zone involvement (bypasses the zone's snap filter, on purpose).
func restore(media: Node3D) -> void:
	_accept(media, true)


## Assume ownership of `media`: drop the zone's grab (if any), reparent it under the
## holder as a frozen rigid child, add the collision exception, and either ride it
## in (`seated_now == false`) or place it seated at once (restore).
func _accept(media: Node3D, seated_now: bool) -> void:
	if not is_instance_valid(media) or _media != null:
		return
	slot.enabled = false
	# Release the zone's own grab so we, not its grab driver, own the body.
	if slot.has_snapped_object():
		slot.drop_object()
	_media = media
	if media is RigidBody3D:
		var rb := media as RigidBody3D
		_orig_freeze_mode = rb.freeze_mode
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rb.freeze = true
	media.reparent(_holder)
	# Not grabbable while it's inside the unit — only once ejected (see eject()).
	if "enabled" in media:
		media.enabled = false
	if is_instance_valid(host):
		host.add_collision_exception_with(media)
	if not media.picked_up.is_connected(_on_media_taken):
		media.picked_up.connect(_on_media_taken)
	_state = State.LOADED
	if seated_now:
		media.transform = _seated_pose()
	else:
		media.transform = _mouth_pose()
		_ride_to(_seated_pose())
	inserted.emit(media)


# --- Eject --------------------------------------------------------------------

## Ride the loaded media back out to the mouth, where it stays (still a frozen child
## riding the host) until a hand takes it. Playback stops now (removed()).
func eject() -> void:
	if _state != State.LOADED or _media == null:
		return
	_state = State.PARKED
	# Now grabbable — the disc/tape is coming out.
	if "enabled" in _media:
		_media.enabled = true
	removed.emit()
	_ride_to(_mouth_pose())


# --- Grab hand-off ------------------------------------------------------------

## A hand grabbed the media (from the parked mouth pose, or straight from the seat).
## XR-tools' grab driver now owns it; reparent it back to world so that driver isn't
## fighting the host's motion, and restore host collision after the pull-away.
func _on_media_taken(media: Node3D) -> void:
	if media.picked_up.is_connected(_on_media_taken):
		media.picked_up.disconnect(_on_media_taken)
	# Hand off with the media's normal freeze mode so XR-tools' grab drives it as
	# usual, and make sure it UN-freezes (falls) when the hand lets go — it was
	# frozen while loaded, so XR-tools captured restore_freeze = true otherwise, and
	# the disc/tape would hang in the air after being taken out.
	if media is RigidBody3D:
		(media as RigidBody3D).freeze_mode = _orig_freeze_mode
	if "restore_freeze" in media:
		media.restore_freeze = false
	# Grabbed while still seated (shouldn't happen — grab is disabled while loaded —
	# but stays correct if it ever does) counts as removal.
	if _state == State.LOADED:
		removed.emit()
	if _tween:
		_tween.kill()
		_tween = null
	_media = null
	_state = State.EMPTY
	slot.enabled = true
	# Hold the host collision exception until the hand DROPS the media, so it never
	# hits the body while being pulled out or held near it. Connected now (not after
	# the deferred reparent) so a same-frame drop can't slip past.
	if media.has_signal("dropped") and not media.dropped.is_connected(_drop_host_exception):
		media.dropped.connect(_drop_host_exception, CONNECT_ONE_SHOT)
	call_deferred("_release_media", media)


## Reparent the grabbed media to world, keeping its global pose, so the grab driver
## isn't fighting the host's motion.
func _release_media(media: Node3D) -> void:
	if is_instance_valid(media) and media.get_parent() == _holder:
		media.reparent(get_tree().current_scene)


## The hand let go of the media away from the slot — it's a normal body again, so
## restore its collision with the host. Skipped if it was re-inserted meanwhile
## (its exception was re-added and must stay).
func _drop_host_exception(media: Node3D) -> void:
	if is_instance_valid(host) and is_instance_valid(media) and media != _media:
		host.remove_collision_exception_with(media)


# --- Ride animation -----------------------------------------------------------

## Tween the media's local (slot-relative) transform to `target`; it rides the host
## for free as a frozen child, so this is the only motion code.
func _ride_to(target: Transform3D) -> void:
	if _media == null:
		return
	if _tween:
		_tween.kill()
	var from: Transform3D = _media.transform
	_tween = _media.create_tween()
	_tween.tween_method(func(t: float) -> void:
			if is_instance_valid(_media):
				_media.transform = from.interpolate_with(target, t),
		0.0, 1.0, ride_time) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
