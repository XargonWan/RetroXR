## RetroKeyboard — pickable keyboard that plugs into a RetroSystem controller
## port (same cable/plug as a controller). Cores see RETRO_DEVICE_KEYBOARD:
## key presses update the poll bitset AND fire the core's keyboard event
## callback (ScummVM, DOSBox, home computers).
##
## VR typing: the key grid is built procedurally; each hand presses at most the
## single nearest key under its controller tip (so a palm can't mash a row).
## Desktop typing: offline, the OS keyboard already flows through the C++
## _input path; during netplay this script forwards OS keys into the
## deterministic schedule instead (the C++ path blocks itself then).
class_name RetroKeyboard
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/controller_cable.tscn")
const RETRO_DEVICE_KEYBOARD := 3

# Key grid geometry (board-local metres). X = right, Z = toward the user.
const KEY_PITCH := 0.026
const KEY_SIZE := 0.023
const KEY_TOP_Y := 0.014       # resting key-cap top
const PRESS_TRAVEL := 0.006    # cap sink when pressed
const TOUCH_MAX_Y := 0.06      # controller tip must be within this above caps
const PRESS_Y := 0.010         # tip below this (board-local) = pressed

# RETROK_* keycodes (libretro.h).
const RK := {
	"esc": 27, "bksp": 8, "tab": 9, "return": 13, "space": 32, "lshift": 304,
	"minus": 45, "equals": 61, "lbracket": 91, "rbracket": 93,
	"semicolon": 59, "quote": 39, "comma": 44, "period": 46, "slash": 47,
	"up": 273, "down": 274, "right": 275, "left": 276,
}

## Layout rows: [label, retrok keycode, width in key units].
## Letters use RETROK a..z = 97..122; digits 0..9 = 48..57.
var _layout: Array = []

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_KEYBOARD

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable (same pattern as RetroController / RetroMouse)
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
var _pending_port_restore: Dictionary = {}

# Key grid: array of {rect: Rect2 (x,z), keycode, char, mesh, base_y}.
var _keys: Array = []
# Currently pressed keycode per hand tracker name ("" -> keycode or -1).
var _hand_pressed: Dictionary = {}
var _controllers: Array = []

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _key_root: Node3D = $Keys


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	_build_layout()
	_build_keys()
	_spawn_cable()
	call_deferred("_find_controllers")


func _find_controllers() -> void:
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node)


func _build_layout() -> void:
	_layout = []
	var row0: Array = [["ESC", RK.esc, 1.0]]
	for d in "1234567890":
		row0.append([d, d.unicode_at(0), 1.0])
	row0.append(["-", RK.minus, 1.0])
	row0.append(["=", RK.equals, 1.0])
	row0.append(["BKSP", RK.bksp, 1.6])
	_layout.append(row0)

	var row1: Array = [["TAB", RK.tab, 1.4]]
	for c in "qwertyuiop":
		row1.append([c.to_upper(), c.unicode_at(0), 1.0])
	row1.append(["[", RK.lbracket, 1.0])
	row1.append(["]", RK.rbracket, 1.0])
	_layout.append(row1)

	var row2: Array = []
	for c in "asdfghjkl":
		row2.append([c.to_upper(), c.unicode_at(0), 1.0])
	row2.append([";", RK.semicolon, 1.0])
	row2.append(["'", RK.quote, 1.0])
	row2.append(["ENTER", RK["return"], 1.8])
	_layout.append(row2)

	var row3: Array = [["SHIFT", RK.lshift, 1.8]]
	for c in "zxcvbnm":
		row3.append([c.to_upper(), c.unicode_at(0), 1.0])
	row3.append([",", RK.comma, 1.0])
	row3.append([".", RK.period, 1.0])
	row3.append(["/", RK.slash, 1.0])
	_layout.append(row3)

	_layout.append([
		["SPACE", RK.space, 7.0],
		["←", RK.left, 1.0], ["↓", RK.down, 1.0],
		["↑", RK.up, 1.0], ["→", RK.right, 1.0],
	])


func _build_keys() -> void:
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.22, 0.22, 0.26)
	var rows := _layout.size()
	# Total width from the widest row, to centre everything.
	var max_w := 0.0
	for row: Array in _layout:
		var w := 0.0
		for k: Array in row:
			w += float(k[2]) * KEY_PITCH
		max_w = maxf(max_w, w)
	var z0 := -(rows * KEY_PITCH) / 2.0
	for r in range(rows):
		var row: Array = _layout[r]
		var row_w := 0.0
		for k: Array in row:
			row_w += float(k[2]) * KEY_PITCH
		var x := -row_w / 2.0
		for k: Array in row:
			var w := float(k[2]) * KEY_PITCH
			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(w - (KEY_PITCH - KEY_SIZE), 0.008, KEY_SIZE)
			mesh.mesh = box
			mesh.set_surface_override_material(0, cap_mat)
			mesh.position = Vector3(x + w / 2.0, KEY_TOP_Y - 0.004, z0 + (r + 0.5) * KEY_PITCH)
			_key_root.add_child(mesh)
			var lbl := Label3D.new()
			lbl.text = str(k[0])
			lbl.pixel_size = 0.0004
			lbl.font_size = 24 if str(k[0]).length() == 1 else 14
			lbl.rotation_degrees = Vector3(-90, 0, 0)
			lbl.position = Vector3(x + w / 2.0, KEY_TOP_Y + 0.001, z0 + (r + 0.5) * KEY_PITCH)
			_key_root.add_child(lbl)
			_keys.append({
				"rect": Rect2(x, z0 + r * KEY_PITCH, w, KEY_PITCH),
				"keycode": int(k[1]),
				"mesh": mesh,
				"base_y": mesh.position.y,
			})
			x += w


# ── Cable (mirrors RetroController) ──────────────────────────────────────────

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


# ── Port events (duck-typed contract used by RetroSystem) ────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	print("[RetroKeyboard] plugged into system port %d" % port_index)


func on_unplugged() -> void:
	print("[RetroKeyboard] unplugged from port %d" % _port_index)
	_release_all()
	_connected_system = null
	_port_index = -1


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── VR key pressing ───────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	# Cable rope clamp (same as RetroController).
	if _cable_plug != null and _cable_attach_point != null and _max_rope_length > 0.0 \
			and not _cable_plug.is_picked_up() and _connected_system == null:
		var attach_pos := _cable_attach_point.global_position
		var diff := _cable_plug.global_position - attach_pos
		var dist := diff.length()
		if dist > _max_rope_length:
			var dir := diff / dist
			_cable_plug.global_position = attach_pos + dir * _max_rope_length
			var outward := dir.dot(_cable_plug.linear_velocity)
			if outward > 0.0:
				_cable_plug.linear_velocity -= dir * outward

	_scan_hands()


func _scan_hands() -> void:
	for ctrl: Node in _controllers:
		if not is_instance_valid(ctrl) or not (ctrl as XRController3D).get_is_active():
			continue
		var name_key := str((ctrl as XRController3D).tracker)
		var tip: Vector3 = to_local((ctrl as Node3D).global_position)
		var hit := -1
		if tip.y >= 0.0 and tip.y <= TOUCH_MAX_Y and tip.y < PRESS_Y:
			hit = _key_at(Vector2(tip.x, tip.z))
		var prev: int = _hand_pressed.get(name_key, -1)
		if hit == prev:
			continue
		if prev >= 0:
			_set_key(prev, false)
		if hit >= 0:
			_set_key(hit, true)
		_hand_pressed[name_key] = hit


func _key_at(p: Vector2) -> int:
	for i in range(_keys.size()):
		if (_keys[i]["rect"] as Rect2).has_point(p):
			return i
	return -1


func _set_key(index: int, down: bool) -> void:
	var k: Dictionary = _keys[index]
	var mesh := k["mesh"] as MeshInstance3D
	mesh.position.y = float(k["base_y"]) - (PRESS_TRAVEL if down else 0.0)
	_send_key(int(k["keycode"]), down)


func _release_all() -> void:
	for name_key: String in _hand_pressed:
		var idx: int = _hand_pressed[name_key]
		if idx >= 0:
			_set_key(idx, false)
	_hand_pressed.clear()


## True while either on-board SHIFT is held (either hand).
func _shift_held() -> bool:
	for name_key: String in _hand_pressed:
		var idx: int = _hand_pressed[name_key]
		if idx >= 0 and int(_keys[idx]["keycode"]) == RK.lshift:
			return true
	return false


# ── Key routing ───────────────────────────────────────────────────────────────

func _send_key(keycode: int, down: bool) -> void:
	if _connected_system == null:
		return
	var character := 0
	if keycode >= 32 and keycode <= 126:
		character = keycode
		if _shift_held() and keycode >= 97 and keycode <= 122:
			character = keycode - 32   # uppercase letters
	# Netplay: key events ride the deterministic frame schedule.
	if NetworkManager.netplay_queue_key(_connected_system, keycode, down, character):
		return
	_connected_system.get_libretro_node().SetKeyState(0, keycode, down, character)


## Desktop typing during netplay: the C++ OS-keyboard path blocks itself while
## port 0 is netplay-masked, so forward OS keys into the schedule here.
## (Offline, C++ handles OS keys directly — don't double-feed.)
func _unhandled_key_input(event: InputEvent) -> void:
	if _connected_system == null or not NetworkManager.netplay_running():
		return
	var key := event as InputEventKey
	if key == null or key.is_echo():
		return
	var keycode := _godot_to_retrok(key.keycode)
	if keycode == 0:
		return
	var character := int(key.unicode)
	NetworkManager.netplay_queue_key(_connected_system, keycode, key.is_pressed(), character)


## Minimal Godot -> RETROK map for desktop netplay typing (letters, digits,
## and the keys on the virtual board).
static func _godot_to_retrok(gd: int) -> int:
	if gd >= KEY_A and gd <= KEY_Z:
		return 97 + (gd - KEY_A)
	if gd >= KEY_0 and gd <= KEY_9:
		return 48 + (gd - KEY_0)
	match gd:
		KEY_SPACE: return 32
		KEY_ENTER: return 13
		KEY_BACKSPACE: return 8
		KEY_TAB: return 9
		KEY_ESCAPE: return 27
		KEY_SHIFT: return 304
		KEY_MINUS: return 45
		KEY_EQUAL: return 61
		KEY_BRACKETLEFT: return 91
		KEY_BRACKETRIGHT: return 93
		KEY_SEMICOLON: return 59
		KEY_APOSTROPHE: return 39
		KEY_COMMA: return 44
		KEY_PERIOD: return 46
		KEY_SLASH: return 47
		KEY_UP: return 273
		KEY_DOWN: return 274
		KEY_RIGHT: return 275
		KEY_LEFT: return 276
	return 0
