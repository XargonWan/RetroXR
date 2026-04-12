## RetroController — pickable joypad that plugs into a RetroSystem controller port.
## Grip once to toggle-hold; grip+trigger+thumbstick-click to drop.
## While held and plugged in, VR controller input routes to the assigned port.
## Button and analog mappings are data-driven via ControllerBindings.
class_name RetroController
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/controller_cable.tscn")
const RETRO_DEVICE_JOYPAD := 1

const DPAD_THRESHOLD      := 0.35
const ANALOG_SCALE        := 0x7fff
const SECONDARY_GRAB_DIST := 0.25

## Input thresholds per XRController float input name.
const INPUT_THRESHOLDS: Dictionary = {
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
	"grip":          0.3,
	"trigger":       0.3,
}

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_JOYPAD

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Active bindings (loaded from ControllerBindings on plug-in)
var _button_map: Dictionary = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
var _stick_map:  Dictionary = ControllerBindings.DEFAULT_STICK_MAP.duplicate()

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
var _desktop_held: bool = false

## Keyboard action → RETRO_JOYPAD bit index for desktop mode.
const DESKTOP_BUTTON_MAP: Dictionary = {
	"RETRO_JOYPAD_B":      ControllerBindings.JOYPAD_B,
	"RETRO_JOYPAD_Y":      ControllerBindings.JOYPAD_Y,
	"RETRO_JOYPAD_SELECT": ControllerBindings.JOYPAD_SELECT,
	"RETRO_JOYPAD_START":  ControllerBindings.JOYPAD_START,
	"RETRO_JOYPAD_UP":     ControllerBindings.JOYPAD_UP,
	"RETRO_JOYPAD_DOWN":   ControllerBindings.JOYPAD_DOWN,
	"RETRO_JOYPAD_LEFT":   ControllerBindings.JOYPAD_LEFT,
	"RETRO_JOYPAD_RIGHT":  ControllerBindings.JOYPAD_RIGHT,
	"RETRO_JOYPAD_A":      ControllerBindings.JOYPAD_A,
	"RETRO_JOYPAD_X":      ControllerBindings.JOYPAD_X,
	"RETRO_JOYPAD_L":      ControllerBindings.JOYPAD_L,
	"RETRO_JOYPAD_R":      ControllerBindings.JOYPAD_R,
	"RETRO_JOYPAD_L2":     ControllerBindings.JOYPAD_L2,
	"RETRO_JOYPAD_R2":     ControllerBindings.JOYPAD_R2,
	"RETRO_JOYPAD_L3":     ControllerBindings.JOYPAD_L3,
	"RETRO_JOYPAD_R3":     ControllerBindings.JOYPAD_R3,
}

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

# Rumble state pushed from RetroSystem._on_rumble_state_changed.
# Normalized 0.0..1.0; _apply_rumble() translates to XR haptics or joy vibration.
var _rumble_weak: float = 0.0
var _rumble_strong: float = 0.0
var _rumble_event: XRToolsRumbleEvent = null
# Track joy devices currently vibrating so we can stop them exactly when state goes to zero.
var _desktop_rumble_active: bool = false

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
	_apply_rumble()


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
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return

	if is_instance_valid(_holding_ctrl) and _holding_ctrl != ctrl:
		# XRTools transferred to second hand — keep old hand as secondary.
		_secondary_ctrl = _holding_ctrl
		_allow_drop = true

	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_locomotion_block()
	# If a rumble is already in progress, route it to the new hand.
	_apply_rumble()


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
		_desktop_held = false
		_update_locomotion_block()
		# Drop any in-flight rumble along with the physical grip.
		_apply_rumble()


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
	_set_pointer_enabled(_left_vr_ctrl,  not left_held)
	_set_pointer_enabled(_right_vr_ctrl, not right_held)


func _set_pointer_enabled(ctrl: XRController3D, enabled: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var pointer := ctrl.get_node_or_null("FunctionPointer") as Node3D
	if pointer:
		pointer.visible = enabled


func _is_combo_pressed(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) \
		and ctrl.get_float("grip") > 0.5 \
		and ctrl.get_float("trigger") > 0.5 \
		and ctrl.get_float("primary_click") > 0.5


func _transfer_to(pickup: XRToolsFunctionPickup) -> void:
	pickup.call("_pick_up_object", self)


func _drop_all() -> void:
	_set_model_visible(_holding_ctrl, true)
	_set_model_visible(_secondary_ctrl, true)
	_allow_drop = true
	_holding_ctrl = null
	_secondary_ctrl = null
	_update_locomotion_block()
	drop()


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_load_bindings()
	print("[RetroController] plugged into system port %d" % port_index)


func on_unplugged() -> void:
	print("[RetroController] unplugged from port %d" % _port_index)
	_connected_system = null
	_port_index = -1
	# Stop any lingering rumble when the cable is yanked. Usually already
	# cleared by RetroSystem._on_port_released, but idempotent and safer.
	_rumble_weak = 0.0
	_rumble_strong = 0.0
	_apply_rumble()


# ── Rumble ────────────────────────────────────────────────────────────────────

## Push a new rumble state from the system (ultimately from the libretro core).
## weak / strong are normalized 0.0..1.0.
func set_rumble(weak: float, strong: float) -> void:
	_rumble_weak = weak
	_rumble_strong = strong
	_apply_rumble()


## Translate the current rumble state into real haptics. Called on any state
## change and whenever the physical holder changes (grab/drop) so the new
## hand picks up ongoing rumble.
func _apply_rumble() -> void:
	var combined: float = XRToolsRumbleManager.combine_magnitudes(_rumble_weak, _rumble_strong)

	# Always drop any previously-queued XR event keyed on self before re-adding
	# so transferring hands mid-rumble doesn't leave the old hand buzzing.
	XRToolsRumbleManager.clear(self)

	var is_held: bool = is_instance_valid(_holding_ctrl) or is_instance_valid(_secondary_ctrl) or _desktop_held

	# No physical holder → stop desktop vibration if active, nothing else to do.
	if not is_held or combined <= 0.0:
		if _desktop_rumble_active:
			for device in Input.get_connected_joypads():
				Input.stop_joy_vibration(device)
			_desktop_rumble_active = false
		return

	# VR path: queue an indefinite event on whichever tracker(s) are holding.
	# XRToolsRumbleManager re-pulses each tick until cleared.
	if is_instance_valid(_holding_ctrl) or is_instance_valid(_secondary_ctrl):
		if _rumble_event == null:
			_rumble_event = XRToolsRumbleEvent.new()
			_rumble_event.indefinite = true
		_rumble_event.magnitude = combined
		var trackers: Array = []
		if is_instance_valid(_holding_ctrl):
			trackers.append(_holding_ctrl.tracker)
		if is_instance_valid(_secondary_ctrl):
			trackers.append(_secondary_ctrl.tracker)
		if not trackers.is_empty():
			XRToolsRumbleManager.add(self, _rumble_event, trackers)

	# Desktop path: vibrate every connected physical pad. Desktop input is
	# action-based and merges all connected pads into the same libretro port,
	# so routing rumble to all of them is the faithful mirror. Single-pad
	# (the common case) works perfectly; multi-pad rumbles uniformly.
	# TODO: when desktop input gains per-device routing, vibrate only the
	# pad actually bound to this port.
	if _desktop_held:
		for device in Input.get_connected_joypads():
			Input.start_joy_vibration(device, _rumble_weak, _rumble_strong, 0.0)
		_desktop_rumble_active = true


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── Bindings ──────────────────────────────────────────────────────────────────

## Reload bindings from disk for the currently-connected system (or global if unplugged).
func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	var systemid := ""
	if is_instance_valid(_connected_system):
		systemid = _connected_system.systemid
	var bindings := ControllerBindings.get_for_system(systemid)
	_button_map = bindings["buttons"]
	_stick_map  = bindings["sticks"]


# Returns the joypad button bitmask contributed by one controller.
# Only processes sources prefixed for the given hand.
func _apply_buttons_for_ctrl(ctrl: XRController3D, left_hand: bool) -> int:
	var bits: int = 0
	for full_source: String in _button_map:
		var bit: int = _button_map[full_source]
		if bit < 0:
			continue
		var vr_input: String
		if full_source.begins_with("right_"):
			if left_hand:
				continue
			vr_input = full_source.substr(6)
		elif full_source.begins_with("left_"):
			if not left_hand:
				continue
			vr_input = full_source.substr(5)
		else:
			vr_input = full_source
		var threshold: float = INPUT_THRESHOLDS.get(vr_input, 0.5)
		if ctrl.get_float(vr_input) > threshold:
			bits |= (1 << bit)
	return bits


# ── Input forwarding ──────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Two-handed: position between both hands.
	if is_instance_valid(_holding_ctrl) and is_instance_valid(_secondary_ctrl):
		global_position = (_holding_ctrl.global_position + _secondary_ctrl.global_position) * 0.5

	# Drop combo: each hand only releases itself.
	if _is_combo_pressed(_secondary_ctrl):
		_set_model_visible(_secondary_ctrl, true)
		_secondary_ctrl = null
		_update_locomotion_block()
		_apply_rumble()
	elif _is_combo_pressed(_holding_ctrl):
		if is_instance_valid(_secondary_ctrl):
			# Transfer: find secondary's XRToolsFunctionPickup then hand off.
			var new_ctrl := _secondary_ctrl
			var pickups := new_ctrl.find_children("*", "XRToolsFunctionPickup", true, false)
			if pickups.size() > 0:
				_set_model_visible(_holding_ctrl, true)
				_allow_drop = true
				_holding_ctrl = null
				_secondary_ctrl = null
				_update_locomotion_block()
				_saved_by.call("drop_object")
				call_deferred("_transfer_to", pickups[0])
			else:
				_drop_all()
				return
		else:
			_drop_all()
			return

	if _connected_system == null or _port_index < 0:
		return

	if _desktop_held:
		_process_desktop_joypad()
		return

	if not is_instance_valid(_holding_ctrl):
		_connected_system.get_libretro_node().SetJoypadState(_port_index, 0, 0, 0, 0, 0)
		return

	var ctrl := _holding_ctrl
	var left_hand := ctrl.tracker == &"left_hand"

	var btn: int = 0

	# Face / grip / trigger buttons via button_map.
	btn |= _apply_buttons_for_ctrl(ctrl, left_hand)
	if is_instance_valid(_secondary_ctrl):
		btn |= _apply_buttons_for_ctrl(_secondary_ctrl, _secondary_ctrl.tracker == &"left_hand")

	# lstick = left hand's primary stick; rstick = right hand's primary stick.
	var left_ctrl  := ctrl if left_hand else _secondary_ctrl
	var right_ctrl := ctrl if not left_hand else _secondary_ctrl
	var lstick: Vector2 = left_ctrl.get_vector2("primary") if is_instance_valid(left_ctrl) else Vector2.ZERO
	var rstick: Vector2 = right_ctrl.get_vector2("primary") if is_instance_valid(right_ctrl) else Vector2.ZERO

	var alx := 0; var aly := 0
	var arx := 0; var ary := 0

	# Target strings: "left", "right", "dpad", "left+dpad", "right+dpad"
	# Substring checks handle combined targets ("dpad" in "left+dpad" → true).
	var lt: String = _stick_map.get("stick_left",  "left+dpad")
	var rt: String = _stick_map.get("stick_right", "right")

	if "left"  in lt: alx = int(lstick.x * ANALOG_SCALE); aly = int(-lstick.y * ANALOG_SCALE)
	elif "right" in lt: arx = int(lstick.x * ANALOG_SCALE); ary = int(-lstick.y * ANALOG_SCALE)
	if "dpad" in lt: btn |= _threshold_to_dpad(lstick)

	if "right" in rt: arx = int(rstick.x * ANALOG_SCALE); ary = int(-rstick.y * ANALOG_SCALE)
	elif "left" in rt: alx = int(rstick.x * ANALOG_SCALE); aly = int(-rstick.y * ANALOG_SCALE)
	if "dpad" in rt: btn |= _threshold_to_dpad(rstick)

	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, alx, aly, arx, ary)


func _process_desktop_joypad() -> void:
	var btn: int = 0
	for action: String in DESKTOP_BUTTON_MAP:
		var bit: int = DESKTOP_BUTTON_MAP[action]
		if Input.is_action_pressed(action):
			btn |= (1 << bit)

	# Left stick from RETRO_ANALOG_LEFT_* actions; Y negated to match VR convention.
	var lx := Input.get_axis("RETRO_ANALOG_LEFT_X_NEGATIVE",  "RETRO_ANALOG_LEFT_X_POSITIVE")
	var ly := Input.get_axis("RETRO_ANALOG_LEFT_Y_NEGATIVE",  "RETRO_ANALOG_LEFT_Y_POSITIVE")
	var rx := Input.get_axis("RETRO_ANALOG_RIGHT_X_NEGATIVE", "RETRO_ANALOG_RIGHT_X_POSITIVE")
	var ry := Input.get_axis("RETRO_ANALOG_RIGHT_Y_NEGATIVE", "RETRO_ANALOG_RIGHT_Y_POSITIVE")
	var alx := int(lx * ANALOG_SCALE)
	var aly := int(-ly * ANALOG_SCALE)
	var arx := int(rx * ANALOG_SCALE)
	var ary := int(-ry * ANALOG_SCALE)

	_connected_system.get_libretro_node().SetJoypadState(_port_index, btn, alx, aly, arx, ary)


static func _threshold_to_dpad(stick: Vector2) -> int:
	var bits := 0
	if stick.y >  DPAD_THRESHOLD: bits |= (1 << 4)
	if stick.y < -DPAD_THRESHOLD: bits |= (1 << 5)
	if stick.x < -DPAD_THRESHOLD: bits |= (1 << 6)
	if stick.x >  DPAD_THRESHOLD: bits |= (1 << 7)
	return bits
