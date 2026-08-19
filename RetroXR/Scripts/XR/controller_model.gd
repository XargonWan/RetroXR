class_name ControllerModel
extends XRController3D

## Global toggle for the wrap-around hand shown on held peripherals (mouse, retro
## controller, ray gun…). When false the device hand is never drawn; the
## controller art fades out on a grab either way. Default off; flipped by the
## OPTIONS menu via SpawnMenuController. Static so the two rig controllers and
## the menu all share one value.
static var draw_hands: bool = false

## The art itself comes from the XR runtime — see [ControllerArt], which owns the
## tier choice and the geometry. This node owns what the room does to it: the
## fade on a grab, and the hand drawn over a held device.
var _art: ControllerArt

# --- Wrap-around hand indicator on held peripherals ---
## A pickable must be in this group to get a wrap-around hand while held. Each
## such device carries its own "HandLeft"/"HandRight" child (an XRToolsHand,
## positioned + posed by hand in the editor); this controller simply shows the
## one matching its tracker while the device is held.
const HAND_HELD_GROUP := "hand_held_device"

# This controller's godot-xr-tools pickup function (source of grab/drop events).
var _pickup: XRToolsFunctionPickup
# The device-mounted hand this controller is currently showing (null if none).
var _shown_hand: Node3D

func _ready():
	# React to this controller's grabs/drops to show/hide the held device's hand.
	_pickup = get_node_or_null("FunctionPickup") as XRToolsFunctionPickup
	if _pickup:
		_pickup.has_picked_up.connect(_on_held_grabbed)
		_pickup.has_dropped.connect(_on_held_dropped)

	_art = ControllerArt.new()
	_art.name = "ModelArt"
	add_child(_art)
	_art.setup(self)
	# Geometry can be replaced at any point — a model that arrives during a grab
	# would otherwise be drawn opaque inside whatever is being held.
	_art.art_changed.connect(_apply_fade)
	_art.art_changed.connect(_resolve_bones)
	_setup_input()

	# A runtime hands its models over when the session begins, and the hardware
	# behind a hand can change mid-session (controllers waking, a swap to hand
	# tracking). Both are signals; neither is worth a per-frame poll.
	profile_changed.connect(_on_profile_changed)
	var xri := XRServer.find_interface("OpenXR")
	if xri != null and xri.has_signal("session_begun"):
		xri.connect("session_begun", _art.refresh)
	_art.refresh.call_deferred()

func _process(delta):
	_drive_fade(delta)
	_check_hold_state()

func _on_profile_changed(_role: String) -> void:
	_art.refresh()


# ── Driving the model's buttons ──────────────────────────────────────────
#
# Meta's runtime hands over the same articulated rig as its downloadable art
# pack, so a trigger pull still moves a trigger. Bone names verified on a Quest 3:
# the face buttons name their letter and everything else is unprefixed, where the
# art pack prefixed the hand onto half of them.

# Max rotation in degrees for each input.
const TRIGGER_FRONT_MAX  = 18.0
const THUMBSTICK_MAX     = 14.0
## Metres. The runtime rig is metre-scale — a face button sits ~10 mm out from
## its parent — where the same numbers against the centimetre-scale art pack were
## 0.11 and 0.6.
const BUTTON_PRESS  = 0.0011
const GRIP_PRESS    = 0.006

var _skeleton: Skeleton3D

# Bone indices (-1 = not found)
var _bone_trigger_front  := -1
var _bone_trigger_grip   := -1
var _bone_thumbstick     := -1
var _bone_ax             := -1  # A (right) or X (left)
var _bone_by             := -1  # B (right) or Y (left)
var _bone_oculus         := -1

# Rest positions for bones animated by translation
var _rest_pos := {}
# Rest rotations for bones animated by rotation
var _rest_rot := {}


## Re-read the rig whenever the art changes. A model can be replaced mid-session,
## and a stale bone index would drive a freed skeleton.
func _resolve_bones() -> void:
	var skel := _art.skeleton()
	if skel == _skeleton:
		return
	_skeleton = skel
	_bone_trigger_front = -1
	_bone_trigger_grip = -1
	_bone_thumbstick = -1
	_bone_ax = -1
	_bone_by = -1
	_bone_oculus = -1
	_rest_pos.clear()
	_rest_rot.clear()
	if _skeleton == null:
		return

	_bone_trigger_front = _find_bone("b_trigger_front")
	_bone_trigger_grip  = _find_bone("b_trigger_grip")
	_bone_thumbstick    = _find_bone("b_thumbstick")
	_bone_oculus        = _find_bone("b_button_oculus")
	if tracker == "left_hand":
		_bone_ax = _find_bone("b_button_x")
		_bone_by = _find_bone("b_button_y")
	else:
		_bone_ax = _find_bone("b_button_a")
		_bone_by = _find_bone("b_button_b")

	for idx in [_bone_trigger_grip, _bone_ax, _bone_by, _bone_oculus]:
		if idx >= 0:
			_rest_pos[idx] = _skeleton.get_bone_rest(idx).origin
	for idx in [_bone_trigger_front, _bone_thumbstick]:
		if idx >= 0:
			_rest_rot[idx] = _skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()


## The art pack prefixed the hand onto the trigger, grip, thumbstick and Oculus
## bones; the runtime rig does not. Accept either rather than tie the animation
## to one supplier's naming.
func _find_bone(base: String) -> int:
	var idx := _skeleton.find_bone(base)
	if idx >= 0:
		return idx
	var prefix := "left" if tracker == "left_hand" else "right"
	return _skeleton.find_bone("%s_%s" % [prefix, base])


func _setup_input() -> void:
	input_float_changed.connect(_on_float_changed)
	input_vector2_changed.connect(_on_vec2_changed)
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)


func _on_float_changed(action: String, value: float):
	match action:
		"trigger":
			_set_bone_rot(_bone_trigger_front, Vector3(value * TRIGGER_FRONT_MAX, 0.0, 0.0))
		"grip":
			var grip_dir = -1.0 if tracker == "right_hand" else 1.0
			_set_bone_pos(_bone_trigger_grip, Vector3(grip_dir * value * GRIP_PRESS, 0.0, 0.0))


func _on_vec2_changed(action: String, value: Vector2):
	if action == "primary":
		_set_bone_rot(_bone_thumbstick, Vector3(
			value.y * THUMBSTICK_MAX,
			0.0,
			value.x * THUMBSTICK_MAX
		))


func _on_button_pressed(button: String):
	match button:
		"ax_button":   _set_bone_pos(_bone_ax,     Vector3(0.0, -BUTTON_PRESS, 0.0))
		"by_button":   _set_bone_pos(_bone_by,     Vector3(0.0, -BUTTON_PRESS, 0.0))
		"menu_button": _set_bone_pos(_bone_oculus, Vector3(0.0, -BUTTON_PRESS, 0.0))


func _on_button_released(button: String):
	match button:
		"ax_button":   _reset_bone(_bone_ax)
		"by_button":   _reset_bone(_bone_by)
		"menu_button": _reset_bone(_bone_oculus)


func _reset_bone(bone_idx: int) -> void:
	if bone_idx >= 0 and _skeleton:
		_skeleton.reset_bone_pose(bone_idx)


func _set_bone_rot(bone_idx: int, euler_degrees: Vector3):
	if bone_idx < 0 or not _skeleton:
		return
	var offset = Quaternion.from_euler(
		Vector3(deg_to_rad(euler_degrees.x), deg_to_rad(euler_degrees.y), deg_to_rad(euler_degrees.z))
	)
	_skeleton.set_bone_pose_rotation(bone_idx, _rest_rot.get(bone_idx, Quaternion.IDENTITY) * offset)


func _set_bone_pos(bone_idx: int, offset: Vector3):
	if bone_idx < 0 or not _skeleton:
		return
	_skeleton.set_bone_pose_position(bone_idx, _rest_pos.get(bone_idx, Vector3.ZERO) + offset)


# ── Fading the controller art ────────────────────────────────────────────
#
# Grabbing something used to snap the controller out of existence, and only for
# devices that author a hand pose; everything else kept a controller drawn inside
# the object you were holding. It now fades, on every grab.

## Seconds for a full fade. Short enough to read as "the controller got out of
## the way" rather than as an animation.
const FADE_TIME := 0.08

var _fade := 1.0
var _fade_target := 1.0


## Show or hide the loaded controller model (called by VRInputMapper). Kept as a
## bool for its callers; it sets a fade target rather than toggling.
func set_model_visible(v: bool) -> void:
	_fade_to(1.0 if v else 0.0)


## The fade is independent of `draw_hands`: the art gets out of the way because
## it would otherwise be drawn inside whatever is in your hand, which is true
## whether or not a hand is drawn over the device.
func _fade_to(target: float) -> void:
	_fade_target = target


func _drive_fade(delta: float) -> void:
	if is_equal_approx(_fade, _fade_target):
		return
	_fade = move_toward(_fade, _fade_target, delta / FADE_TIME)
	_apply_fade()


## Push the current fade level onto the art. The materials belong to ControllerArt
## because they are duplicates of whatever the runtime supplied; a surface it
## could not give us a BaseMaterial3D for cannot take an alpha at all, so it is
## hidden for the whole of a partial fade rather than left standing opaque.
func _apply_fade() -> void:
	if _art == null:
		return
	# Skip drawing entirely once invisible, and go back to opaque rendering at
	# full alpha so the model keeps its normal depth behaviour when in use.
	_art.visible = _fade > 0.001
	for m in _art.fade_materials:
		m.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED if _fade >= 0.999 \
			else BaseMaterial3D.TRANSPARENCY_ALPHA
		var c: Color = m.albedo_color
		m.albedo_color = Color(c.r, c.g, c.b, _fade)
	for g in _art.opaque_only:
		g.visible = _fade >= 0.999


## XRToolsFunctionPickup.drop_object() returns before emitting has_dropped when
## the held object was freed under it, which strands the art faded out with
## nothing in hand. Restore whenever this hand is hidden but holding nothing.
func _check_hold_state() -> void:
	if _pickup == null or _fade_target > 0.0:
		return
	if is_instance_valid(_pickup.picked_up_object) or _pickup.is_ray_grabbing():
		return
	_on_held_dropped()


## This controller grabbed something — fade the controller art out, and when the
## object is a device peripheral show its own hand for this tracker (authored in
## the device scene).
func _on_held_grabbed(what: Node) -> void:
	# A ray-pointer (telekinesis) grab holds the object at a distance, not in the
	# hand — its has_picked_up still fires, but the controller has nothing to get
	# out of the way of and no hand belongs on the object.
	if _pickup and _pickup.is_ray_grabbing_target(what as XRToolsPickable):
		return
	# Fade on ANY grab, not just the device peripherals that author their own
	# hand pose. A cartridge or a TV left the controller art sitting inside
	# whatever you were holding.
	_fade_to(0.0)
	_show_device_hand(what)


## This controller released whatever it held — hide the hand, restore the art.
func _on_held_dropped() -> void:
	_hide_device_hand()
	_fade_to(1.0)


## Draw the device's own hand for this tracker, if it authors one and the option
## is on. Only the hand answers to `draw_hands` — the fade above does not.
func _show_device_hand(what: Node) -> void:
	if not draw_hands:
		return
	if what == null or not what.is_in_group(HAND_HELD_GROUP):
		return
	var hand_name := "HandLeft" if tracker == "left_hand" else "HandRight"
	var hand := what.get_node_or_null(NodePath(hand_name)) as Node3D
	if hand == null:
		return
	hand.visible = true
	_shown_hand = hand


func _hide_device_hand() -> void:
	if is_instance_valid(_shown_hand):
		_shown_hand.visible = false
	_shown_hand = null


## Re-evaluate the device hand after the OPTIONS switch flipped mid-hold, so
## turning hands off drops the hand off whatever is already held and turning
## them on puts one there without waiting for a re-grab.
func refresh_device_hand() -> void:
	_hide_device_hand()
	if _pickup == null or _pickup.is_ray_grabbing():
		return
	# Variant, not Node3D: the hand can still be pointing at an object that was
	# freed while held, and binding that to a typed local throws.
	var held: Variant = _pickup.picked_up_object
	if is_instance_valid(held):
		_show_device_hand(held)
