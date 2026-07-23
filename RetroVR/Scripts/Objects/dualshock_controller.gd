## DualShockController — a RetroController whose DualShock model animates.
##
## Identical hold/plug/cable/rumble/netplay behaviour to RetroController (it is a
## thin subclass); the only addition is driving the separated button/stick meshes
## from the exact per-frame joypad state pushed by _send_joypad(). Face buttons
## depress (translate), the D-pad rocks and the analog sticks tilt about the
## imported pivot empties shipped inside the .glb (Dpad / StickLeft / StickRight).
##
## The model is an author's imported "PlayStation Controller" bundle — separated named
## meshes: button_x/circle/square/triangle, button_l1/l2/r1/r2, button_select/
## start/analog, dpad, stick_left/right, Main, controller_screws.
class_name DualShockController
extends RetroController

# Press depths (metres) and tilt limits (degrees). Tuned by eye; refine in-headset.
const FACE_PRESS: float    = 0.0022
const TRIGGER_PRESS: float = 0.0032
const SMALL_PRESS: float   = 0.0016
const STICK_CLICK: float   = 0.0016
const DPAD_TILT_DEG: float  = 7.0
const STICK_TILT_DEG: float = 16.0
const PRESS_DIR: Vector3   = Vector3(0, -1, 0)   # "into the shell" in model space
const ANIM_LERP: float     = 20.0

# Mesh-base-name -> RETRO_JOYPAD bit (PSX/RetroArch standard glyph mapping).
const FACE_BUTTONS: Dictionary = {
	"button_x":        ControllerBindings.JOYPAD_B,   # Cross
	"button_circle":   ControllerBindings.JOYPAD_A,   # Circle
	"button_square":   ControllerBindings.JOYPAD_Y,   # Square
	"button_triangle": ControllerBindings.JOYPAD_X,   # Triangle
	"button_l1":       ControllerBindings.JOYPAD_L,
	"button_r1":       ControllerBindings.JOYPAD_R,
	"button_select":   ControllerBindings.JOYPAD_SELECT,
	"button_start":    ControllerBindings.JOYPAD_START,
}
const TRIGGERS: Dictionary = {
	"button_l2": ControllerBindings.JOYPAD_L2,
	"button_r2": ControllerBindings.JOYPAD_R2,
}

# Cached animated meshes. Each button entry: {node, rest, bit, depth}.
var _buttons: Array[Dictionary] = []
# D-pad / sticks: {node, rest, pivot} (pivot in the mesh's parent space).
var _dpad: Dictionary = {}
var _stick_l: Dictionary = {}
var _stick_r: Dictionary = {}

# Latest joypad state captured from _send_joypad; zeroed when no input this frame.
var _cur_btn: int = 0
var _cur_lstick: Vector2 = Vector2.ZERO
var _cur_rstick: Vector2 = Vector2.ZERO
var _got_input: bool = false


func _ready() -> void:
	super._ready()
	_cache_meshes()


# ── Node caching ────────────────────────────────────────────────────────────

# Normalise a node name for tolerant matching (Godot's glTF import may turn
# "button_x.002" into "button_x_002" / "button_x002"). Strips non-alphanumerics.
func _norm(s: String) -> String:
	var out: String = ""
	for ch in s.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out


func _find_mesh(base: String) -> MeshInstance3D:
	var target: String = _norm(base)
	for n: Node in find_children("*", "MeshInstance3D", true, false):
		if _norm(n.name).begins_with(target):
			return n as MeshInstance3D
	return null


# Find a non-mesh marker node by exact normalised name (the imported pivot empties).
func _find_pivot(mesh: MeshInstance3D, empty_name: String) -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var target: String = _norm(empty_name)
	for n: Node in find_children("*", "Node3D", true, false):
		if n is MeshInstance3D:
			continue
		if _norm(n.name) == target:
			var n3d: Node3D = n as Node3D
			return mesh.get_parent().to_local(n3d.global_position)
	# No pivot empty (e.g. the PS2 model ships none) — fall back to the mesh's
	# own AABB centre so sticks/D-pad still rotate in place, not about the origin.
	var a: AABB = mesh.get_aabb()
	return mesh.transform * a.get_center()


## How far the "d-pad" rocks about its pivot. A flat pad only needs a few
## degrees; a real joystick shaft swings much further. Override per controller.
func _dpad_tilt_deg() -> float:
	return DPAD_TILT_DEG


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in FACE_BUTTONS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(FACE_BUTTONS[base]), "depth": FACE_PRESS})
	for base: String in TRIGGERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(TRIGGERS[base]), "depth": TRIGGER_PRESS})

	var dm: MeshInstance3D = _find_mesh("dpad")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "Dpad")}
	var sl: MeshInstance3D = _find_mesh("stick_left")
	if sl != null:
		_stick_l = {"node": sl, "rest": sl.transform, "pivot": _find_pivot(sl, "StickLeft")}
	var sr: MeshInstance3D = _find_mesh("stick_right")
	if sr != null:
		_stick_r = {"node": sr, "rest": sr.transform, "pivot": _find_pivot(sr, "StickRight")}

	print("[dualshock] cached %d buttons, dpad=%s lstick=%s rstick=%s"
		% [_buttons.size(), not _dpad.is_empty(), not _stick_l.is_empty(), not _stick_r.is_empty()])


# ── Input capture + animation ───────────────────────────────────────────────

# Capture the exact merged per-frame state, then forward to the base behaviour.
func _send_joypad(btn: int, alx: int, aly: int, arx: int, ary: int) -> void:
	_cur_btn = btn
	_cur_lstick = Vector2(float(alx) / ANALOG_SCALE, float(aly) / ANALOG_SCALE)
	_cur_rstick = Vector2(float(arx) / ANALOG_SCALE, float(ary) / ANALOG_SCALE)
	_got_input = true
	super._send_joypad(btn, alx, aly, arx, ary)


func _process(delta: float) -> void:
	_got_input = false
	super._process(delta)          # runs hold/drop/plug logic; calls _send_joypad when active
	if not _got_input:             # not plugged/held → relax to rest
		_cur_btn = 0
		_cur_lstick = Vector2.ZERO
		_cur_rstick = Vector2.ZERO
	_animate(delta)


func _animate(delta: float) -> void:
	var w: float = clampf(ANIM_LERP * delta, 0.0, 1.0)

	for e: Dictionary in _buttons:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var pressed: float = 1.0 if (_cur_btn & (1 << int(e["bit"]))) != 0 else 0.0
		var target: Transform3D = Transform3D(rest.basis, rest.origin + PRESS_DIR * (float(e["depth"]) * pressed))
		node.transform = node.transform.interpolate_with(target, w)

	if not _dpad.is_empty():
		var pitch: float = float((_cur_btn >> ControllerBindings.JOYPAD_UP) & 1) - float((_cur_btn >> ControllerBindings.JOYPAD_DOWN) & 1)
		var roll: float  = float((_cur_btn >> ControllerBindings.JOYPAD_LEFT) & 1) - float((_cur_btn >> ControllerBindings.JOYPAD_RIGHT) & 1)
		var tilt := _dpad_tilt_deg()
		var r: Basis = Basis.from_euler(Vector3(deg_to_rad(pitch * tilt), 0.0, deg_to_rad(roll * tilt)))
		_apply_pivot(_dpad, r, 0.0, w)

	if not _stick_l.is_empty():
		var click_l: float = 1.0 if (_cur_btn & (1 << ControllerBindings.JOYPAD_L3)) != 0 else 0.0
		_apply_pivot(_stick_l, _stick_basis(_cur_lstick), click_l, w)
	if not _stick_r.is_empty():
		var click_r: float = 1.0 if (_cur_btn & (1 << ControllerBindings.JOYPAD_R3)) != 0 else 0.0
		_apply_pivot(_stick_r, _stick_basis(_cur_rstick), click_r, w)


func _stick_basis(stick: Vector2) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(stick.y * STICK_TILT_DEG), 0.0, deg_to_rad(-stick.x * STICK_TILT_DEG)))


# Rotate a mesh about a world-space pivot (in parent space), plus an optional
# click push along PRESS_DIR, lerping from its current transform toward target.
func _apply_pivot(entry: Dictionary, r: Basis, click: float, w: float) -> void:
	var node: MeshInstance3D = entry["node"]
	var rest: Transform3D = entry["rest"]
	var pivot: Vector3 = entry["pivot"]
	var about: Transform3D = Transform3D(r, pivot - r * pivot + PRESS_DIR * (STICK_CLICK * click))
	var target: Transform3D = about * rest
	node.transform = node.transform.interpolate_with(target, w)
