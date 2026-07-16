class_name ControllerModel
extends XRController3D

## Global toggle for the wrap-around hand shown on held peripherals (mouse, retro
## controller, ray gun…). When false the device hand is never drawn and the
## controller art stays visible while holding. Default off; flipped by the
## OPTIONS menu via SpawnMenuController. Static so the two rig controllers and
## the menu all share one value.
static var draw_hands: bool = false

const TOUCH_PLUS_BASE = "res://Models/oculus-controller-art-v1.8/Meta Quest Touch Plus/"
const TOUCH_PRO_BASE  = "res://Models/oculus-controller-art-v1.8/Meta Quest Touch Pro/"

const MODELS = {
	"touch_plus": {
		"left_hand":  TOUCH_PLUS_BASE + "models/MetaQuestTouchPlus_Left.fbx",
		"right_hand": TOUCH_PLUS_BASE + "models/MetaQuestTouchPlus_Right.fbx",
	},
	"touch_pro": {
		"left_hand":  TOUCH_PRO_BASE + "models/questpro_controllers_left.fbx",
		"right_hand": TOUCH_PRO_BASE + "models/questpro_controllers_right.fbx",
	},
}

const TOUCH_PLUS_TEXTURES = {
	"left_hand": {
		"albedo": TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_Left_BaseColor.png",
		"orm":    TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_ORM.png",
		"normal": TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_Normals.png",
	},
	"right_hand": {
		"albedo": TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_right_BaseColor.png",
		"orm":    TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_ORM.png",
		"normal": TOUCH_PLUS_BASE + "textures/MetaQuestTouchPlus_Normals.png",
	},
}
const BATTERY_TEXTURE = TOUCH_PLUS_BASE + "textures/batteryIndicatorTexture32.png"

# Max rotation in degrees for each input
const TRIGGER_FRONT_MAX  = 18.0
const THUMBSTICK_MAX     = 14.0
const BUTTON_PRESS  = 0.11  # cm-scale units pressed in
const GRIP_PRESS    = 0.6

var _model_loaded := false
var _model_root: Node3D
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

func _process(_delta):
	if _model_loaded:
		return
	var xr_tracker = XRServer.get_tracker(tracker)
	if xr_tracker == null or xr_tracker.profile.is_empty() or "none" in xr_tracker.profile:
		return
	_load_model(xr_tracker.profile)
	_model_loaded = true

func _load_model(profile: String):
	var model_key: String
	var path: String
	if "touch_plus" in profile or "oculus/touch_controller" in profile:
		model_key = "touch_plus"
		path = MODELS["touch_plus"][tracker]
	else:
		push_warning("No model for profile: " + profile)
		return

	var scene = load(path)
	if not scene:
		push_warning("Failed to load controller model: " + path)
		return

	_model_root = scene.instantiate()
	_model_root.rotation_degrees.y = 180.0
	add_child(_model_root)

	if model_key == "touch_plus":
		_apply_touch_plus_material()

	_setup_skeleton()
	_setup_input()

func _setup_skeleton():
	_skeleton = _model_root.find_child("Skeleton3D", true, false) as Skeleton3D
	if not _skeleton:
		return
	var prefix = "left" if tracker == "left_hand" else "right"
	_bone_trigger_front = _skeleton.find_bone(prefix + "_b_trigger_front")
	_bone_trigger_grip  = _skeleton.find_bone(prefix + "_b_trigger_grip")
	_bone_thumbstick    = _skeleton.find_bone(prefix + "_b_thumbstick")
	_bone_oculus        = _skeleton.find_bone(prefix + "_b_button_oculus")
	# A/X and B/Y share names across both controllers
	if tracker == "left_hand":
		_bone_ax = _skeleton.find_bone("b_button_x")
		_bone_by = _skeleton.find_bone("b_button_y")
	else:
		_bone_ax = _skeleton.find_bone("b_button_a")
		_bone_by = _skeleton.find_bone("b_button_b")

	for idx in [_bone_trigger_grip, _bone_ax, _bone_by, _bone_oculus]:
		if idx >= 0:
			_rest_pos[idx] = _skeleton.get_bone_rest(idx).origin
	for idx in [_bone_trigger_front, _bone_thumbstick]:
		if idx >= 0:
			_rest_rot[idx] = _skeleton.get_bone_rest(idx).basis.get_rotation_quaternion()


func _setup_input():
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
		"ax_button":   _skeleton.reset_bone_pose(_bone_ax)
		"by_button":   _skeleton.reset_bone_pose(_bone_by)
		"menu_button": _skeleton.reset_bone_pose(_bone_oculus)

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

func _apply_touch_plus_material():
	var tex = TOUCH_PLUS_TEXTURES[tracker]

	var mat = StandardMaterial3D.new()
	mat.albedo_texture            = load(tex["albedo"])
	mat.orm_texture               = load(tex["orm"])
	mat.normal_enabled            = true
	mat.normal_texture            = load(tex["normal"])
	mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	mat.ao_texture_channel        = BaseMaterial3D.TEXTURE_CHANNEL_RED
	mat.metallic_texture_channel  = BaseMaterial3D.TEXTURE_CHANNEL_BLUE

	var battery_mat = StandardMaterial3D.new()
	battery_mat.albedo_texture = load(BATTERY_TEXTURE)
	battery_mat.transparency   = BaseMaterial3D.TRANSPARENCY_ALPHA

	var prefix = "left" if tracker == "left_hand" else "right"
	var battery_mesh = _model_root.find_child(prefix + "_batteryIndicatorQuad_MeshX", true, false) as MeshInstance3D
	if battery_mesh:
		for i in battery_mesh.get_surface_override_material_count():
			battery_mesh.set_surface_override_material(i, battery_mat)

	_apply_material_recursive(_model_root, mat, battery_mesh)

func _apply_material_recursive(node: Node, mat: Material, exclude: Node = null):
	if node != exclude and node is MeshInstance3D:
		for i in node.get_surface_override_material_count():
			node.set_surface_override_material(i, mat)
	for child in node.get_children():
		_apply_material_recursive(child, mat, exclude)


## Show or hide the loaded controller model (called by VRInputMapper)
func set_model_visible(v: bool) -> void:
	if _model_root:
		# With hands disabled the controller art always stays visible — a held
		# peripheral shows the controller, never a hand — so ignore hide requests.
		_model_root.visible = v or not draw_hands


## This controller grabbed a device peripheral — hide the controller art and
## show the device's own hand for this tracker (authored in the device scene).
func _on_held_grabbed(what: Node) -> void:
	if what == null or not what.is_in_group(HAND_HELD_GROUP):
		return
	# Hands turned off in the options menu — keep the controller art, no hand.
	if not draw_hands:
		return
	# A ray-pointer (telekinesis) grab holds the object at a distance, not in the
	# hand — its has_picked_up still fires, but no hand should be drawn on it.
	if _pickup and _pickup.is_ray_grabbing_target(what as XRToolsPickable):
		return
	var hand_name := "HandLeft" if tracker == "left_hand" else "HandRight"
	var hand := what.get_node_or_null(NodePath(hand_name)) as Node3D
	if hand == null:
		return
	set_model_visible(false)
	hand.visible = true
	_shown_hand = hand


## This controller released whatever it held — hide the hand, restore the art.
func _on_held_dropped() -> void:
	if is_instance_valid(_shown_hand):
		_shown_hand.visible = false
	_shown_hand = null
	set_model_visible(true)
