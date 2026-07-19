## VRSlider — a physical slider/switch: a knob that travels along a local axis.
##
## Interaction mirrors VRButton: direct XRController3D tip proximity engages the
## knob (no physics bodies), plus desktop reticle pointer press-drag (works live
## thanks to the desktop pointer press/drag patch). With `steps >= 2` the knob
## snaps to detents and only emits on detent change — that IS a slide switch
## (steps = 2 → power switch). With `steps = 0` it's continuous (volume).
##
## Attach to an Area3D with a child MeshInstance3D named "KnobMesh".
class_name VRSlider
extends Area3D

signal value_changed(value: float)

const POINTABLE_LAYER := 1 << 20

## Travel axis in this node's local space.
@export var axis_local: Vector3 = Vector3(1, 0, 0)
## Total knob travel in metres (value 0 → -travel/2, value 1 → +travel/2).
@export var travel: float = 0.03
## 0 = continuous; >= 2 = snap to this many detent positions.
@export var steps: int = 0
## Controller tip distance (m) that engages the knob.
@export var engage_radius: float = 0.035
## Current value 0..1.
@export var value: float = 0.0

var _engaged_ctrl: XRController3D = null
var _pointer_engaged := false
var _controllers: Array[XRController3D] = []
var _suppress_signal := false

@onready var _knob: MeshInstance3D = $KnobMesh


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_update_knob()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the value without emitting (panel/populate use).
func set_value_no_signal(v: float) -> void:
	_suppress_signal = true
	_set_from_raw(v)
	_suppress_signal = false


func _process(_delta: float) -> void:
	if _pointer_engaged:
		return   # pointer drag owns the knob (handled in pointer_event)
	# Engage: nearest active controller tip within radius. Disengage with
	# hysteresis so a jittery hand doesn't flicker on the boundary.
	if _engaged_ctrl != null:
		# Also let go if the engaged hand grabs something mid-slide.
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or not PokeTip.is_poking(_engaged_ctrl) \
				or global_position.distance_to(PokeTip.tip_of(_engaged_ctrl)) > engage_radius * 1.8:
			_engaged_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_engaged_ctrl))
			return
	for ctrl in _controllers:
		# Skip a hand that's holding something so it can't grab the knob by bumping it.
		if ctrl and ctrl.get_is_active() and PokeTip.is_poking(ctrl) \
				and global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius:
			_engaged_ctrl = ctrl
			_track_world_point(PokeTip.tip_of(ctrl))
			return


## Desktop reticle / VR laser support (same contract as VRButton).
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


## Project a world-space point onto the travel axis → value.
func _track_world_point(world_pos: Vector3) -> void:
	var local := to_local(world_pos)
	var axis := axis_local.normalized()
	if travel <= 0.0:
		return
	_set_from_raw(local.dot(axis) / travel + 0.5)


func _set_from_raw(raw: float) -> void:
	var v := clampf(raw, 0.0, 1.0)
	if steps >= 2:
		v = roundf(v * (steps - 1)) / float(steps - 1)
	if is_equal_approx(v, value):
		return
	value = v
	_update_knob()
	if not _suppress_signal:
		value_changed.emit(value)


func _update_knob() -> void:
	if _knob:
		_knob.position = axis_local.normalized() * (value - 0.5) * travel
