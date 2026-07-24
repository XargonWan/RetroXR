## VRHinge — a physical, grip-latched hinge: a grabbable lid that rotates a target
## node about the target's local X axis, clamped between two angles (a clamshell
## lid or a console flap).
##
## Interaction (VR + desktop), unified:
##   • HOVER — a controller tip within engage_radius, or the desktop reticle over
##     the grab box, shows a floating OPEN-HAND icon above the lid ("grab here").
##   • HELD  — hold the GRIP button (VR) / press-drag the reticle (desktop) to
##     LATCH; the icon becomes a FIST and the lid rotates toward the hand/pointer.
##     Once latched the hand need NOT stay in the grab box — the latch holds until
##     grip is released (VR) / the click is released (desktop).
##
## Because it latches on grip / pointer-press (not the grip-GRAB of a pickable) it
## never conflicts with grip-grabbing the whole device or a nearby pickable (the
## cartridge stub): the device isn't a pickable, and the grab zone is only the
## top (free) half of the lid.
##
## Attach to an Area3D with a child CollisionShape3D covering the grab region (the
## desktop reticle ray hits this; VR engages on tip proximity to the Area origin).
## The angle reported is the target's rotation about local X, in degrees.
class_name VRHinge
extends Area3D

signal rotation_changed(degrees: float)

const POINTABLE_LAYER := 1 << 20
const GRIP_ON := 0.6      # grip float that latches the hinge
const GRIP_OFF := 0.4     # grip float that releases it (hysteresis)
const ICON_HOVER := 0xF256   # Nerd Font: open palm — "grab here"
const ICON_HELD := 0xF255    # Nerd Font: closed fist — "holding"
const SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"

## Node whose local-X rotation this hinge drives (e.g. a clamshell lid pivot).
@export var target: Node3D
## Rotation limits about the target's local X, in degrees.
@export var min_deg: float = 0.0
@export var max_deg: float = 180.0
## Controller tip distance (m) that engages the handle.
@export var engage_radius: float = 0.04
## Desktop: degrees the mouse wheel rolls the hinge per notch while held.
@export var wheel_step_deg: float = 10.0
## Where the floating hint icon sits, in this hinge's local frame (above the lid).
@export var icon_offset: Vector3 = Vector3(0.0, 0.0, 0.04)
## Icon glyph height, roughly, in metres.
@export var icon_size: float = 0.028

var _grip_ctrl: XRController3D = null    # latched controller (grip held)
var _pointer_held := false               # desktop pointer latched
var _pointer_hover := false              # desktop reticle over the grab box
var _controllers: Array[XRController3D] = []
var _icon: Label3D = null


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_build_icon()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)


## Set the target rotation without emitting (restore/populate use).
func set_rotation_deg_no_signal(deg: float) -> void:
	_apply(deg, false)


func _process(_delta: float) -> void:
	# VR: grip-latched engagement. A latched controller drives the hinge until it
	# releases grip — regardless of how far the hand roams from the grab box.
	if _grip_ctrl != null:
		if not is_instance_valid(_grip_ctrl) or not _grip_ctrl.get_is_active() \
				or _grip_ctrl.get_float("grip") < GRIP_OFF:
			_grip_ctrl = null
		else:
			_track_world_point(PokeTip.tip_of(_grip_ctrl))
	elif not _pointer_held:
		# Not latched (and desktop isn't dragging): latch a hovering controller
		# that squeezes grip.
		for ctrl in _controllers:
			if ctrl == null or not ctrl.get_is_active():
				continue
			if global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius \
					and ctrl.get_float("grip") > GRIP_ON:
				_grip_ctrl = ctrl
				_track_world_point(PokeTip.tip_of(ctrl))
				break
	_update_icon()


## Desktop reticle / VR laser support (same contract as VRButton/VRSlider). Press
## latches; the latch holds through MOVED even if the ray leaves the box, and only
## RELEASED lets go — EXITED just clears the hover highlight, never the drag.
##
## On DESKTOP a press only latches (fist icon) — the mouse WHEEL then rolls the
## angle while held (see _unhandled_input), which is finer and steadier than
## dragging the ray. In VR the laser pointer keeps its press-drag.
func pointer_event(event: XRToolsPointerEvent) -> void:
	var vr := get_viewport().use_xr
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hover = true
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_held = true
			if vr:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.MOVED:
			if _pointer_held and vr:
				_track_world_point(event.position)
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_held = false
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hover = false
			# NB: keep _pointer_held — a drag is allowed to leave the grab box.
	_update_icon()


## Desktop: while the lid is held (reticle pressed on the grab box), the mouse
## wheel rolls the hinge open/closed. Wheel up opens, wheel down closes. Gated on
## _pointer_held, so other wheel consumers (held-object push/pull) only see the
## event when no hinge is grabbed. rotation.x grows toward SHUT on both the
## clamshells (0 open → 180 shut) and the NES flap driver (0 shut → -105 open),
## so "open" is always -step and "close" +step.
func _unhandled_input(event: InputEvent) -> void:
	if not _pointer_held or target == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	var step := 0.0
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = -wheel_step_deg
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = wheel_step_deg
	else:
		return
	_apply(rad_to_deg(target.rotation.x) + step, true)
	get_viewport().set_input_as_handled()


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


# --- floating hint icon --------------------------------------------------------

## Build the open-hand / fist hint, billboarded and floating above the lid. It is
## parented to this Area3D (a child of the lid pivot), so it rides the lid as it
## swings. The Symbols Nerd Font is chained as a fallback so the PUA glyphs resolve
## (same recipe as tv_remote.gd).
func _build_icon() -> void:
	_icon = Label3D.new()
	_icon.name = "HingeHint"
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	var symbols: Font = load(SYMBOL_FONT_PATH)
	if symbols:
		fv.fallbacks = [symbols]
	_icon.font = fv
	_icon.font_size = 96
	_icon.pixel_size = icon_size / 96.0
	_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_icon.no_depth_test = true
	_icon.render_priority = 2
	_icon.outline_size = 18
	_icon.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_icon.position = icon_offset
	_icon.visible = false
	add_child(_icon)


## Show the fist while held, the open hand while hovering, nothing otherwise.
func _update_icon() -> void:
	if _icon == null:
		return
	if _icon.position != icon_offset:
		_icon.position = icon_offset
	var held := _grip_ctrl != null or _pointer_held
	if held:
		_icon.text = String.chr(ICON_HELD)
		_icon.modulate = Color(1.0, 0.82, 0.28)   # fist — amber "holding"
		_icon.visible = true
		return
	if _pointer_hover or _vr_hovering():
		_icon.text = String.chr(ICON_HOVER)
		_icon.modulate = Color(0.92, 0.96, 1.0)    # open hand — cool white
		_icon.visible = true
		return
	_icon.visible = false


func _vr_hovering() -> bool:
	for ctrl in _controllers:
		if ctrl and ctrl.get_is_active() \
				and global_position.distance_to(PokeTip.tip_of(ctrl)) <= engage_radius:
			return true
	return false
