class_name CapsenseHand
extends XRNode3D

## Runtime hand geometry and joints paired with one physical controller. Meta's
## simultaneous-hands-and-controllers extension supplies controller-inferred
## Capsense joints while the Touch controller is held, and unobstructed camera
## joints when it is put down. The display preference decides which geometry is
## shown; unavailable joints or mesh always fall back to controller art.

@export var controller_path: NodePath
@export_enum("Left", "Right") var hand: int = 0

const POSITION_VALID := XRHandTracker.HAND_JOINT_FLAG_POSITION_VALID
const INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const PALM := XRHandTracker.HAND_JOINT_PALM

var _controller: XRController3D = null
var _mesh: Node = null
var _mesh_ready_override: Variant = null
var _last_motion_range := -1


func _ready() -> void:
	_controller = get_node_or_null(controller_path) as XRController3D
	_mesh = get_node_or_null("OpenXRFbHandTrackingMesh")
	if _controller != null and _controller.has_method("register_capsense_hand"):
		_controller.call("register_capsense_hand", self)
	apply_display_mode()


func _process(_delta: float) -> void:
	apply_display_mode()


func hand_tracker() -> XRHandTracker:
	return XRServer.get_tracker(tracker) as XRHandTracker


func hand_source() -> int:
	var ht := hand_tracker()
	return ht.hand_tracking_source if ht != null \
		else XRHandTracker.HAND_TRACKING_SOURCE_NOT_TRACKED


func joints_valid() -> bool:
	var ht := hand_tracker()
	if ht == null or not ht.has_tracking_data:
		return false
	return _joint_position_valid(ht, PALM) and _joint_position_valid(ht, INDEX_TIP)


func mesh_ready() -> bool:
	if _mesh_ready_override != null:
		return bool(_mesh_ready_override)
	if _mesh == null or not _mesh.has_method("get_mesh_instance"):
		return false
	var mi := _mesh.call("get_mesh_instance") as MeshInstance3D
	return mi != null and mi.mesh != null


func is_hand_available() -> bool:
	return joints_valid() and mesh_ready()


## Current index tip in world space, queried directly from XRHandTracker. The
## joint transforms share tracking space; making the tip relative to the palm
## and composing it through this XRNode3D also carries the origin's reference
## frame and world-scale handling.
func index_tip_position() -> Variant:
	if AppPrefs.xr_display_mode == AppPrefs.XRDisplayMode.CONTROLLERS:
		return null
	var ht := hand_tracker()
	if ht == null or not ht.has_tracking_data \
			or not _joint_position_valid(ht, PALM) \
			or not _joint_position_valid(ht, INDEX_TIP):
		return null
	var palm: Transform3D = ht.get_hand_joint_transform(PALM)
	var tip: Transform3D = ht.get_hand_joint_transform(INDEX_TIP)
	return global_transform * (palm.affine_inverse() * tip).origin


## Surface target for the post-tracking finger modifier. Only the rendered
## skeleton consumes this; PokeTip.tip_of() continues to expose the raw joint.
func visual_contact_target() -> Variant:
	if not visible or _controller == null or not PokeTip.is_poking(_controller):
		return null
	var poke := _controller.get_node_or_null("PokeTip") as PokeTip
	return poke.visual_contact_target() if poke != null else null


func apply_display_mode() -> void:
	var mode: int = AppPrefs.xr_display_mode
	var source := hand_source()
	var available := is_hand_available()
	var holding := _controller != null and not PokeTip.is_poking(_controller)
	var show_hand := available and mode != AppPrefs.XRDisplayMode.CONTROLLERS and not holding
	visible = show_hand

	# A controller-sourced hand wraps its visible controller in BOTH mode. An
	# unobstructed camera hand has no controller at that pose, so it takes over.
	var show_controller := mode == AppPrefs.XRDisplayMode.CONTROLLERS or not available
	if mode == AppPrefs.XRDisplayMode.BOTH and available:
		show_controller = source == XRHandTracker.HAND_TRACKING_SOURCE_CONTROLLER
	if _controller != null and _controller.has_method("set_display_visible"):
		_controller.call("set_display_visible", show_controller)

	var wanted_range := OpenXRInterface.HAND_MOTION_RANGE_CONFORM_TO_CONTROLLER
	if mode == AppPrefs.XRDisplayMode.HANDS \
			or source == XRHandTracker.HAND_TRACKING_SOURCE_UNOBSTRUCTED:
		wanted_range = OpenXRInterface.HAND_MOTION_RANGE_UNOBSTRUCTED
	_set_motion_range(wanted_range)


func active_motion_range() -> int:
	return _last_motion_range


func _set_motion_range(value: int) -> void:
	if value == _last_motion_range:
		return
	_last_motion_range = value
	var xri := XRServer.find_interface("OpenXR") as OpenXRInterface
	if xri != null:
		xri.set_motion_range(hand, value as OpenXRInterface.HandMotionRange)


func _joint_position_valid(ht: XRHandTracker, joint: int) -> bool:
	return (ht.get_hand_joint_flags(joint) & POSITION_VALID) != 0


## Synthetic probes have no runtime mesh, but still need to exercise the exact
## visibility and joint paths. null restores the real readiness check.
func set_mesh_ready_override(value: Variant) -> void:
	_mesh_ready_override = value
