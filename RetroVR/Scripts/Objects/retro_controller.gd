## RetroController — pickable joypad that plugs into a RetroSystem controller port.
## Grip once to toggle-hold; grip+trigger+thumbstick-click to drop.
## While held and plugged in, VR controller input routes to the assigned port.
class_name RetroController
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/controller_cable.tscn")
const RETRO_DEVICE_JOYPAD := 1

const DPAD_THRESHOLD      := 0.35
const ANALOG_SCALE        := 0x7fff
const SECONDARY_GRAB_DIST := 0.25

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_JOYPAD

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Pending port restore (set before cable is ready)
var _pending_port_restore: Dictionary = {}

# Toggle-hold state
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null    # primary holder (official XRTools)
var _secondary_ctrl: XRController3D = null  # second hand tracked manually

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

@onready var _cable_attach_point: Node3D = $CableAttachPoint


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_spawn_cable()
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			_left_vr_ctrl = ctrl
			ctrl.button_pressed.connect(_on_vr_grip_pressed.bind(ctrl))
		elif ctrl.tracker == &"right_hand":
			_right_vr_ctrl = ctrl
			ctrl.button_pressed.connect(_on_vr_grip_pressed.bind(ctrl))


## Secondary hold: grip press on the other hand picks it up; only the combo drops it.
func _on_vr_grip_pressed(button: String, from_ctrl: XRController3D) -> void:
	if button != "grip_click":
		return
	# Primary hand — XRTools toggle handles this.
	if from_ctrl == _holding_ctrl:
		return
	# Free hand trying to grab as secondary.
	if not is_instance_valid(_holding_ctrl) or is_instance_valid(_secondary_ctrl):
		return
	if from_ctrl.global_position.distance_to(global_position) > SECONDARY_GRAB_DIST:
		return
	_secondary_ctrl = from_ctrl
	_set_model_visible(from_ctrl, false)
	_update_locomotion_block()


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if _cable_plug.is_picked_up() or _connected_system != null:
		return

	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()

	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward_vel := dir.dot(_cable_plug.linear_velocity)
		if outward_vel > 0.0:
			_cable_plug.linear_velocity -= dir * outward_vel


# ── Toggle-hold ───────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		return

	if is_instance_valid(_holding_ctrl) and _holding_ctrl != ctrl:
		# XRTools transferred to second hand — keep old hand as secondary.
		_secondary_ctrl = _holding_ctrl
		_allow_drop = true

	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		call_deferred("_rehold")
	else:
		_set_model_visible(_holding_ctrl, true)
		_set_model_visible(_secondary_ctrl, true)
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		_secondary_ctrl = null
		_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
		_set_model_visible(_secondary_ctrl, true)
		_saved_by = null
		_holding_ctrl = null
		_secondary_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


func _set_model_visible(ctrl: XRController3D, show: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", show)


func _update_locomotion_block() -> void:
	var left_held := (is_instance_valid(_holding_ctrl)   and _holding_ctrl.tracker   == &"left_hand") \
				  or (is_instance_valid(_secondary_ctrl) and _secondary_ctrl.tracker == &"left_hand")
	var right_held := (is_instance_valid(_holding_ctrl)   and _holding_ctrl.tracker   == &"right_hand") \
				   or (is_instance_valid(_secondary_ctrl) and _secondary_ctrl.tracker == &"right_hand")
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, right_held)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	print("[RetroController] plugged into system port %d" % port_index)


func on_unplugged() -> void:
	print("[RetroController] unplugged from port %d" % _port_index)
	_connected_system = null
	_port_index = -1


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── Input forwarding ──────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Two-handed: position between both hands.
	if is_instance_valid(_holding_ctrl) and is_instance_valid(_secondary_ctrl):
		global_position = (_holding_ctrl.global_position + _secondary_ctrl.global_position) * 0.5

	# Drop combo: always checked regardless of port connection.
	if is_instance_valid(_holding_ctrl):
		var ctrl := _holding_ctrl
		if ctrl.get_float("grip") > 0.5 \
				and ctrl.get_float("trigger") > 0.5 \
				and ctrl.get_float("primary_click") > 0.5:
			_set_model_visible(ctrl, true)
			_set_model_visible(_secondary_ctrl, true)
			_allow_drop = true
			_holding_ctrl = null
			_secondary_ctrl = null
			_update_locomotion_block()
			drop()
			return

	if _connected_system == null or _port_index < 0:
		return

	if not is_instance_valid(_holding_ctrl):
		_connected_system.get_libretro_node().SetJoypadState(_port_index, 0, 0, 0, 0, 0)
		return

	var ctrl := _holding_ctrl
	var left_hand := ctrl.tracker == &"left_hand"
	var btn: int = 0

	var ls: Vector2 = ctrl.get_vector2("primary")
	if ls.y >  DPAD_THRESHOLD: btn |= (1 << 4)
	if ls.y < -DPAD_THRESHOLD: btn |= (1 << 5)
	if ls.x < -DPAD_THRESHOLD: btn |= (1 << 6)
	if ls.x >  DPAD_THRESHOLD: btn |= (1 << 7)
	if ctrl.get_float("ax_button") > 0.5:
		btn |= (1 << (9 if left_hand else 8))
	if ctrl.get_float("by_button") > 0.5:
		btn |= (1 << (1 if left_hand else 0))
	if ctrl.get_float("grip") > 0.3:
		btn |= (1 << (10 if left_hand else 11))
	if ctrl.get_float("trigger") > 0.3:
		btn |= (1 << (12 if left_hand else 13))
	if ctrl.get_float("primary_click") > 0.5:
		btn |= (1 << (2 if left_hand else 3))

	var arx := 0
	var ary := 0

	if is_instance_valid(_secondary_ctrl):
		var sc := _secondary_ctrl
		var sc_left := sc.tracker == &"left_hand"
		if sc.get_float("ax_button") > 0.5:
			btn |= (1 << (9 if sc_left else 8))
		if sc.get_float("by_button") > 0.5:
			btn |= (1 << (1 if sc_left else 0))
		if sc.get_float("grip") > 0.3:
			btn |= (1 << (10 if sc_left else 11))
		if sc.get_float("trigger") > 0.3:
			btn |= (1 << (12 if sc_left else 13))
		if sc.get_float("primary_click") > 0.5:
			btn |= (1 << (2 if sc_left else 3))
		var right_ctrl := ctrl if not left_hand else sc
		var rs: Vector2 = right_ctrl.get_vector2("primary")
		arx = int(rs.x * ANALOG_SCALE)
		ary = int(-rs.y * ANALOG_SCALE)
	else:
		var rs: Vector2 = ctrl.get_vector2("secondary")
		arx = int(rs.x * ANALOG_SCALE)
		ary = int(-rs.y * ANALOG_SCALE)

	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, 0, 0, arx, ary)
