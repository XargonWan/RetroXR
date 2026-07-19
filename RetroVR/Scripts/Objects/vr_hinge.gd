## VRHinge — a physical hinge: a grabbable handle that rotates a target node
## about the target's local X axis, clamped between two angles (e.g. a clamshell
## lid). Interaction mirrors VRButton/VRSlider: direct XRController3D tip
## proximity engages it (no physics bodies), plus desktop reticle pointer
## press-drag. Because it engages on tip proximity / pointer rather than the grip
## grab, it never conflicts with grip-grabbing the parent object (the whole
## device) or a nearby pickable (the cartridge stub).
##
## Attach to an Area3D with a child CollisionShape3D covering the grab region.
## The angle reported is the target's rotation about local X, in degrees.
class_name VRHinge
extends Area3D

signal rotation_changed(degrees: float)

const POINTABLE_LAYER := 1 << 20

## Node whose local-X rotation this hinge drives (e.g. a clamshell lid pivot).
@export var target: Node3D
## Rotation limits about the target's local X, in degrees.
@export var min_deg: float = 0.0
@export var max_deg: float = 180.0
## Controller tip distance (m) that engages the handle.
@export var engage_radius: float = 0.04

var _engaged_ctrl: XRController3D = null
var _pointer_engaged := false
var _controllers: Array[XRController3D] = []


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the target rotation without emitting (restore/populate use).
func set_rotation_deg_no_signal(deg: float) -> void:
	_apply(deg, false)


func _process(_delta: float) -> void:
	if _pointer_engaged:
		return   # pointer drag owns the hinge (handled in pointer_event)
	# Engage: nearest active controller tip within radius. Disengage with
	# hysteresis so a jittery hand doesn't flicker on the boundary.
	if _engaged_ctrl != null:
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or global_position.distance_to(PokeTip.tip_of(_engaged_ctrl)) > engage_radius * 1.8:
			_engaged_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_engaged_ctrl))
			return
	for ctrl in _controllers:
		if ctrl and ctrl.get_is_active() \
				and global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius:
			_engaged_ctrl = ctrl
			_track_world_point(PokeTip.tip_of(ctrl))
			return


## Desktop reticle / VR laser support (same contract as VRButton/VRSlider).
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_engaged = true
			_track_world_point(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_engaged:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED:
			_pointer_engaged = false


## Convert an engaged world point to an angle about the hinge axis (the target's
## local X) and drive the target. The point is measured in the target's PARENT
## frame relative to the pivot origin; the panel points -Z at rotation 0 and
## folds toward +Z as the angle grows (theta = atan2(y, -z)).
func _track_world_point(world_pos: Vector3) -> void:
	if target == null:
		return
	var parent := target.get_parent() as Node3D
	if parent == null:
		return
	var rel := parent.to_local(world_pos) - target.position
	if Vector2(rel.y, rel.z).length() < 0.001:
		return   # hand at the pivot — angle undefined, ignore
	# atan2 wraps at ±180°, so near a limit a tiny cross-axis jitter can flip the
	# sign (e.g. +179° → -179°) and snap the hinge to the opposite end. Unwrap
	# onto the branch nearest the current angle to keep it continuous end-to-end.
	var deg := rad_to_deg(atan2(rel.y, -rel.z))
	var cur := rad_to_deg(target.rotation.x)
	while deg - cur > 180.0:
		deg -= 360.0
	while deg - cur < -180.0:
		deg += 360.0
	_apply(deg, true)


func _apply(deg: float, emit: bool) -> void:
	if target == null:
		return
	deg = clampf(deg, min_deg, max_deg)
	target.rotation.x = deg_to_rad(deg)
	if emit:
		rotation_changed.emit(deg)
