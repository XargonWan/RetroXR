## RetroController — pickable joypad that plugs into a RetroSystem controller port.
## Grip once to toggle-hold; grip+trigger+thumbstick-click to drop.
## While held and plugged in, VR controller input routes to the assigned port.
class_name RetroController
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/controller_cable.tscn")
const RETRO_DEVICE_JOYPAD := 1

const DPAD_THRESHOLD := 0.35
const ANALOG_SCALE   := 0x7fff

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
var _allow_drop := false          # set true by combo so _rehold() lets the drop stand
var _saved_by: Node3D = null      # XRToolsFunctionPickup currently holding us
var _holding_ctrl: XRController3D = null  # cached for input forwarding

@onready var _cable_attach_point: Node3D = $CableAttachPoint


func _ready() -> void:
	super._ready()
	press_to_hold = false  # toggle: grip press once to hold, grip press again triggers re-hold
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_spawn_cable()


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

# grabbed(pickable, by) — save the pickup node and its controller each time we're grabbed.
func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	_saved_by = by
	var pickup := by as XRToolsFunctionPickup
	_holding_ctrl = pickup.get_controller() if pickup else null


# dropped(pickable) — fires when xr-tools releases us (grip press in toggle mode).
# Unless the combo set _allow_drop, schedule a re-hold next frame.
func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		call_deferred("_rehold")
	else:
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null


# Runs at end of the frame after a non-combo drop.
# If _allow_drop was set by the combo during that frame, let the drop stand.
func _rehold() -> void:
	if _allow_drop or not is_instance_valid(_saved_by):
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		return
	# Re-establish hold from both sides — private but callable at runtime
	_saved_by.call("_pick_up_object", self)


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
	if _connected_system == null or _port_index < 0:
		return

	if not is_instance_valid(_holding_ctrl):
		_connected_system.get_libretro_node().SetJoypadState(_port_index, 0, 0, 0, 0, 0)
		return

	var ctrl := _holding_ctrl

	# Drop combo: grip + trigger + thumbstick click — intercepted before any input is forwarded.
	# _allow_drop gates _rehold() so the physical release sticks.
	if ctrl.get_float("grip") > 0.5 \
			and ctrl.get_float("trigger") > 0.5 \
			and ctrl.get_float("primary_click") > 0.5:
		_allow_drop = true
		_holding_ctrl = null
		drop()
		return

	# Map VR controller → joypad, hand-aware so L/R/L2/R2 land on the correct side.
	var left_hand := ctrl.tracker == &"left_hand"
	var btn: int = 0

	# D-pad from primary stick
	var ls: Vector2 = ctrl.get_vector2("primary")
	if ls.y >  DPAD_THRESHOLD: btn |= (1 << 4)  # JOYPAD_UP
	if ls.y < -DPAD_THRESHOLD: btn |= (1 << 5)  # JOYPAD_DOWN
	if ls.x < -DPAD_THRESHOLD: btn |= (1 << 6)  # JOYPAD_LEFT
	if ls.x >  DPAD_THRESHOLD: btn |= (1 << 7)  # JOYPAD_RIGHT

	# Face buttons: left hand → X/Y, right hand → A/B
	if ctrl.get_float("ax_button") > 0.5:
		btn |= (1 << (9 if left_hand else 8))   # X : A
	if ctrl.get_float("by_button") > 0.5:
		btn |= (1 << (1 if left_hand else 0))   # Y : B

	# Shoulder: grip → L/R, trigger → L2/R2
	if ctrl.get_float("grip") > 0.3:
		btn |= (1 << (10 if left_hand else 11))  # L : R
	if ctrl.get_float("trigger") > 0.3:
		btn |= (1 << (12 if left_hand else 13))  # L2 : R2

	# Stick click: left → SELECT, right → START
	if ctrl.get_float("primary_click") > 0.5:
		btn |= (1 << (2 if left_hand else 3))   # SELECT : START

	# Analog from secondary stick (right stick when held in left hand, etc.)
	var rs: Vector2 = ctrl.get_vector2("secondary")
	var arx := int(rs.x * ANALOG_SCALE)
	var ary := int(-rs.y * ANALOG_SCALE)

	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, 0, 0, arx, ary)
