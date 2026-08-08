## Nunchuk — the Wii Remote's extension, as a separate object on its own cord.
##
## It never talks to libretro. The remote owns the slot and makes every core call
## for the pair, so this only has to say what its stick and buttons are doing and
## let the remote fold that into the one joypad word it sends. Seating the plug in
## the remote's expansion port is what flips that remote from WIIMOTE to
## WIIMOTE_NC; pulling it out flips it back.
##
## No motion of its own: the core leaves the Nunchuk's Tilt and Swing groups
## compiled out and binds its shake to a button, so a real accelerometer here
## would have nowhere to go.
class_name Nunchuk
extends XRToolsPickable


const NUNCHUK_CABLE_SCENE := preload("res://Scenes/Objects/nunchuk_cable.tscn")

## What the plug reports so it fits the remote's expansion port and nothing else.
## RetroSystem._accepts_plug rejects any plug whose systemid is not the console's,
## which keeps this cord out of every cabinet socket in the room.
const PLUG_SYSTEMID := "wii_nunchuk"

const INPUT_THRESHOLDS: Dictionary = {
	"trigger":   0.3,
	"grip":      0.3,
	"ax_button": 0.5,
	"by_button": 0.5,
}

## Height of the drop hint above the nunchuk, in metres.
const HINT_HEIGHT := 0.10

const BUTTON_PRESS := 0.0015
const ANIM_WEIGHT := 0.4

## Shake threshold in m/s^2 of proper acceleration, over gravity. The core takes
## the Nunchuk's shake as a button, so this is where the gesture becomes one.
const SHAKE_THRESHOLD := 14.0

# Cable
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Hold state
var _holding_ctrl: XRController3D = null
var _hint: HeldHint = null

# Shake detection
var _prev_velocity := Vector3.ZERO
var _shaking := false

# Active bindings
var _nunchuk_map: Dictionary = ControllerBindings.DEFAULT_NUNCHUK_MAP.duplicate()

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _c_button: MeshInstance3D = $CButton
@onready var _z_button: MeshInstance3D = $ZButton

var _c_rest := Transform3D()
var _z_rest := Transform3D()


func _ready() -> void:
	super._ready()
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_c_rest = _c_button.transform
	_z_rest = _z_button.transform
	_load_bindings()
	_spawn_cable()


func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	_nunchuk_map = ControllerBindings.get_for_system("wii")["nunchuk"]


# ── Cable (mirrors RetroMultitap) ─────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = NUNCHUK_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	# set_controller copies device_type and systemid off this node; the sentinel
	# below is what the remote's expansion port filters on.
	_cable_plug.systemid = PLUG_SYSTEMID
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, -0.1, 0)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length


func get_plug() -> ControllerPlug:
	return _cable_plug


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if _cable_plug.is_picked_up():
		return
	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()
	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward := dir.dot(_cable_plug.linear_velocity)
		if outward > 0.0:
			_cable_plug.linear_velocity -= dir * outward


# ── Hold ──────────────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	var pickup := by as XRToolsFunctionPickup
	_holding_ctrl = pickup.get_controller() if pickup else null


func _on_dropped_signal(_pickable: Node3D) -> void:
	if _hint:
		_hint.on_dropped()
	_holding_ctrl = null


# ── State the Wiimote polls ───────────────────────────────────────────────────

## Stick, C, Z and whether the nunchuk is being shaken right now. Read once a
## frame by the remote holding the port; nothing here reaches the core directly.
func get_state() -> Dictionary:
	var vr := is_instance_valid(_holding_ctrl)
	return {
		"stick": _holding_ctrl.get_vector2("primary") if vr else Vector2.ZERO,
		"c":     _held(_nunchuk_map.get("c", "ax_button")),
		"z":     _held(_nunchuk_map.get("z", "trigger")),
		"shake": _shaking,
	}


func _held(source: Variant) -> bool:
	if not is_instance_valid(_holding_ctrl):
		return false
	var name_str := str(source)
	if name_str.is_empty() or name_str == "none":
		return false
	return _holding_ctrl.get_float(name_str) > float(INPUT_THRESHOLDS.get(name_str, 0.5))


func _process(delta: float) -> void:
	_update_shake(delta)
	var state := get_state()
	_animate(_c_button, _c_rest, state.get("c", false))
	_animate(_z_button, _z_rest, state.get("z", false))


## A jerk of the whole object, not a button. Uses the same proper-acceleration
## reading the remote does — motion minus gravity — so simply holding it still
## while the room moves cannot register.
func _update_shake(delta: float) -> void:
	if delta <= 0.0:
		return
	var accel := (linear_velocity - _prev_velocity) / delta + Vector3.UP * 9.80665
	_prev_velocity = linear_velocity
	_shaking = accel.length() > SHAKE_THRESHOLD


func _animate(node: MeshInstance3D, rest: Transform3D, down: bool) -> void:
	var depth := BUTTON_PRESS if down else 0.0
	# The buttons face -Z on the shell's back, so they press away from the player.
	var tgt := Transform3D(rest.basis, rest.origin + Vector3(0, 0, depth))
	node.transform = node.transform.interpolate_with(tgt, ANIM_WEIGHT)
