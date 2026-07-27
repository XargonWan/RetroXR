## VRSlider — a physical slider/switch: a knob that travels along a local axis.
##
## Interaction mirrors VRButton: direct XRController3D tip proximity engages the
## knob (no physics bodies), plus desktop reticle pointer press-drag (works live
## thanks to the desktop pointer press/drag patch). With `steps >= 2` the knob
## snaps to detents and only emits on detent change — that IS a slide switch
## (steps = 2 → power switch). With `steps = 0` it's continuous (volume).
##
## Two interaction modes, same as VRButton:
##   • TOUCH (default) — the fingertip crossing engage_radius grabs the knob at
##     once, and a 1.8x radius hysteresis decides when it lets go.
##   • TRIGGER (require_trigger = true) — the fingertip entering the interaction
##     box only ARMS the knob, outlining it green; pulling the controller's
##     TRIGGER latches it (amber) and the knob tracks the hand until the trigger
##     is released. Because it latches rather than tracking proximity, the hand
##     is free to roam past the knob mid-drag — strictly better than the radius
##     hysteresis it replaces. Same model as VRHinge.
##
## Attach to an Area3D with a child MeshInstance3D named "KnobMesh".
class_name VRSlider
extends Area3D

signal value_changed(value: float)

const POINTABLE_LAYER := 1 << 20

## Analog trigger action, read as a float — see VRButton.
const TRIGGER_ACTION := "trigger"
const TRIGGER_ON := 0.6
const TRIGGER_OFF := 0.4

## Travel axis in this node's local space.
@export var axis_local: Vector3 = Vector3(1, 0, 0)
## Degrees the knob TURNS across the full travel, for a cap that rides a curved
## edge rather than a straight slot. A long cap on a shallow arc cannot stay on
## the surface by translating alone — its middle sinks in while its tips break
## out — so it has to turn as it goes. Zero (the default) is a plain straight
## slide, which is what a flat slot wants.
@export var knob_turn_deg: float = 0.0
## Axis the knob turns about, in THIS node's local space. The default suits an
## edge that curves in the horizontal plane, i.e. a switch on a device's side.
@export var knob_turn_axis: Vector3 = Vector3.UP

## Total knob travel in metres (value 0 → -travel/2, value 1 → +travel/2).
@export var travel: float = 0.03
## 0 = continuous; >= 2 = snap to this many detent positions.
@export var steps: int = 0
## Controller tip distance (m) that engages the knob. TOUCH mode only —
## TRIGGER mode uses interact_margin.
@export var engage_radius: float = 0.035
## Require a TRIGGER pull while the fingertip is inside the interaction box,
## instead of grabbing on proximity alone. Off by default so authored sliders
## keep their existing behaviour until switched over scene by scene.
@export var require_trigger: bool = false
## How far (metres) the interaction box extends past the knob mesh's own AABB,
## on every side. TRIGGER mode only.
@export var interact_margin: float = 0.02
## Current value 0..1.
@export var value: float = 0.0

var _engaged_ctrl: XRController3D = null
var _pointer_engaged := false
var _pointer_hovered := false
var _controllers: Array[XRController3D] = []
var _suppress_signal := false

# TRIGGER mode state
var _armed: bool = false
# Controller instance ids whose trigger has dropped below TRIGGER_OFF since they
# last latched this knob — stops one held trigger grabbing knob after knob.
var _rearmed: Dictionary = {}

# Travel direction in the KNOB'S PARENT space, and the pose everything is
# measured from: the knob's transform at _knob_anchor_value, which is the value
# the geometry is actually MODELLED at. Anchoring on that rather than on
# mid-travel means value == anchor reproduces the modelled pose exactly, by
# construction — which matters once the knob turns as well as slides.
var _knob_axis: Vector3 = Vector3.RIGHT
var _knob_turn_axis: Vector3 = Vector3.UP
var _knob_anchor: Transform3D = Transform3D()
var _knob_anchor_value: float = 0.5
# Cap centre in the knob's own MESH space — the point it turns about. An adopted
# GLB cap often has an identity node transform with its offset baked into the
# vertex data, so its centre is tens of mm from its origin and turning about the
# origin would fling it across the shell.
var _knob_centre: Vector3 = Vector3.ZERO

var _outline: WidgetOutline = null
var _outline_amber: bool = false

@onready var _knob: MeshInstance3D = $KnobMesh


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_knob_axis = axis_local.normalized()
	_knob_turn_axis = knob_turn_axis.normalized()
	# The authored placeholder is driven from the Area origin at mid-travel, which
	# is what this class did before knobs could be adopted or turn.
	_anchor_knob(Transform3D(_knob.basis, Vector3.ZERO) if _knob != null else Transform3D(), 0.5)
	_update_knob()
	_outline = WidgetOutline.attach(self)
	# The knob is a hidden placeholder on every baked handheld — outline it anyway
	# (see WidgetOutline.outline_hidden_source).
	_outline.outline_hidden_source = true
	_outline.set_source(_knob)
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the value AND report it, for an owner driving the slider from something
## other than a hand on the knob — the PSP's volume +/- buttons step it this way.
## The plain `value` export has no setter, so assigning it moves nothing and tells
## nobody; set_value_no_signal moves the knob but stays silent.
func set_value(v: float) -> void:
	_set_from_raw(v)


## Set the value without emitting (panel/populate use).
func set_value_no_signal(v: float) -> void:
	_suppress_signal = true
	_set_from_raw(v)
	_suppress_signal = false


## Drive the real GLB knob instead of the placeholder KnobMesh, hiding the
## placeholder. Mirrors VRButton.set_button_mesh — without it a handheld whose
## GLB has loaded would size its interaction box to a hidden primitive and show
## no highlight at all (see handheld_model.gd).
func set_knob_mesh(mesh: MeshInstance3D) -> void:
	if mesh == null:
		return
	var old := get_node_or_null("KnobMesh") as MeshInstance3D
	if old and old != mesh:
		old.hide()
	_knob = mesh
	# Convert the travel axis from THIS node's local space into the adopted
	# knob's parent space so _update_knob still slides it the right way.
	var world_axis := (global_transform.basis * axis_local.normalized()).normalized()
	var parent := mesh.get_parent() as Node3D
	if parent:
		_knob_axis = parent.global_transform.basis.inverse() * world_axis
	else:
		_knob_axis = world_axis
	if parent:
		_knob_turn_axis = (parent.global_transform.basis.inverse()
			* (global_transform.basis * knob_turn_axis.normalized())).normalized()
	# Anchor on where the GLB actually models the cap, at whatever value is current
	# — adopting must not visibly jerk it. GLBs model switches in the off position,
	# which is value 0, so this lines up.
	_anchor_knob(mesh.transform, value)
	if _outline:
		_outline.set_source(_knob)
	_update_knob()


func _process(_delta: float) -> void:
	if _pointer_engaged:
		_sync_outline()
		return   # pointer drag owns the knob (handled in pointer_event)
	if not _controllers.is_empty():
		if require_trigger:
			_process_trigger_mode()
		else:
			_process_touch_mode()
	_sync_outline()


## TOUCH mode — the original behaviour: proximity engages, 1.8x radius releases.
func _process_touch_mode() -> void:
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


## TRIGGER mode — arm on proximity, latch on the trigger's rising edge, and hold
## the latch until the trigger is released regardless of where the hand goes.
func _process_trigger_mode() -> void:
	for ctrl in _controllers:
		if ctrl != null and ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_rearmed[ctrl.get_instance_id()] = true

	if _engaged_ctrl != null:
		if not is_instance_valid(_engaged_ctrl) or not _engaged_ctrl.get_is_active() \
				or _engaged_ctrl.get_float(TRIGGER_ACTION) < TRIGGER_OFF:
			_engaged_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_engaged_ctrl))
			_armed = true
			return

	var ctrl := _hovering_ctrl()
	_armed = ctrl != null
	if ctrl == null or ctrl.get_float(TRIGGER_ACTION) <= TRIGGER_ON:
		return
	if not _rearmed.get(ctrl.get_instance_id(), false):
		return
	_rearmed[ctrl.get_instance_id()] = false
	_engaged_ctrl = ctrl
	_track_world_point(PokeTip.tip_of(ctrl))


## First active, non-holding controller whose poke tip is inside the knob's box.
func _hovering_ctrl() -> XRController3D:
	for ctrl in _controllers:
		if ctrl == null or not ctrl.get_is_active() or not PokeTip.is_poking(ctrl):
			continue
		if _tip_in_box(PokeTip.tip_of(ctrl)):
			return ctrl
	return null


## Interaction volume: the knob mesh's own AABB grown by interact_margin on every
## side, tested in the knob's local space. It rides the knob as the value changes,
## which is what you want — you grab the cap, not the track.
func _tip_in_box(tip: Vector3) -> bool:
	if not is_instance_valid(_knob) or _knob.mesh == null:
		return false
	var box := _knob.mesh.get_aabb().grow(interact_margin)
	return box.has_point(_knob.global_transform.affine_inverse() * tip)


## Desktop reticle / VR laser support (same contract as VRButton).
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hovered = true
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_hovered = true
			_pointer_engaged = true
			_track_world_point(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_engaged:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_engaged = false
		XRToolsPointerEvent.Type.EXITED:
			_pointer_engaged = false
			_pointer_hovered = false


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


## Knob pose at mid-travel, plus the point it turns about: the cap's own CENTRE
## in the knob's parent frame. An adopted GLB cap frequently has an identity node
## transform with its offset baked into the vertex data, so `position` is nowhere
## near the cap and turning about it would fling the cap across the shell.
## Record the pose the knob is modelled in, and the value that pose represents.
func _anchor_knob(pose: Transform3D, at_value: float) -> void:
	_knob_anchor = pose
	_knob_anchor_value = at_value
	_knob_centre = Vector3.ZERO
	if _knob != null and _knob.mesh != null:
		_knob_centre = _knob.mesh.get_aabb().get_center()


func _update_knob() -> void:
	if _knob == null:
		return
	# Everything is measured from the anchor, so at value == anchor this is exactly
	# the modelled pose: zero slide, zero turn, no drift to correct for.
	var d: float = value - _knob_anchor_value
	var slide: Vector3 = _knob_axis * d * travel
	if is_zero_approx(knob_turn_deg):
		_knob.position = _knob_anchor.origin + slide
		return
	# Turn about the cap's own centre where it currently sits, then slide.
	var r := Basis(_knob_turn_axis.normalized(), deg_to_rad(knob_turn_deg) * d)
	var pivot: Vector3 = _knob_anchor * _knob_centre
	_knob.transform = Transform3D(Basis.IDENTITY, slide) 		* Transform3D(r, pivot - r * pivot) * _knob_anchor


## Green while armed, amber while the trigger holds the knob.
##
## Only the ARMED/ENGAGED states are gated on require_trigger — they describe the
## trigger mode and mean nothing without it. Pointer hover is not: the laser and
## the desktop reticle highlight whatever they are over, which is what VRButton
## has always done. Gating the whole method left every slider in the room silent
## under the pointer while every button lit up.
func _sync_outline() -> void:
	if _outline == null:
		return
	if not require_trigger:
		_outline.sync(_pointer_hovered)
		return
	var engaged := _engaged_ctrl != null or _pointer_engaged
	if engaged != _outline_amber:
		_outline_amber = engaged
		_outline.set_color(WidgetOutline.ACTIVE_COLOR if engaged else WidgetOutline.HOVER_COLOR)
	_outline.sync(_armed or engaged or _pointer_hovered)
