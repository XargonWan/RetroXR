## AnimatedController — a RetroController whose controls move.
##
## Identical hold/plug/cable/rumble/netplay behaviour to RetroController (it is a
## thin subclass); the only addition is driving separated button/stick meshes from
## the exact per-frame joypad state pushed by _send_joypad(). Buttons depress
## (translate along a per-entry direction), D-pads rock about a pivot and analog
## sticks tilt and click.
##
## Every pad in Scenes/Objects/controllers/ that has moving parts derives from
## this — the imported console models (which find their meshes by name inside the
## .glb) and the pads authored from primitives (which bind theirs by node path).
## Subclasses supply only _cache_meshes(); the animation itself is shared.
class_name AnimatedController
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

# Cached animated meshes. Each button entry: {node, rest, bit, depth}.
var _buttons: Array[Dictionary] = []
# D-pad / sticks: {node, rest, pivot} (pivot in the mesh's parent space).
var _dpad: Dictionary = {}
# A second rocker, for pads with two D-pads (the Virtual Boy). Same shape as
# _dpad plus "bits" [up, down, left, right] and an optional "axis" ("left" /
# "right") folding that analog stick in — a second D-pad has no RetroPad bits of
# its own, so which ones it borrows is the core's choice.
var _dpad2: Dictionary = {}
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

## Bind this pad's moving meshes into _buttons / _dpad / _dpad2 / _stick_l /
## _stick_r. Imported models search by mesh name (_find_mesh); pads authored as
## primitives look their controls up by node path.
func _cache_meshes() -> void:
	pass


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


# Find a non-mesh marker node by exact normalised name (the bundled pivot empties).
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


## Sign of the D-pad's pitch rotation. A positive pitch about the mesh parent's
## X axis lifts whatever lies on -Z, so a model whose UP arm points -Z must
## return -1.0 for UP to depress it. Roll is unaffected.
func _dpad_pitch_sign() -> float:
	return 1.0


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
		# "mask" lets one mesh answer to several buttons. Some pads mould their
		# face buttons as a single piece — the Genesis pad's A, B and C are one
		# mesh — so there is nothing to press individually. Defaults to just this
		# entry's own bit.
		var mask: int = int(e.get("mask", 1 << int(e["bit"])))
		var pressed: float = 1.0 if (_cur_btn & mask) != 0 else 0.0
		# Per-button press direction, defaulting to PRESS_DIR. Face buttons sink
		# into the top surface, but a control mounted on another face travels
		# into THAT face — a shoulder button on the back edge pressed along
		# PRESS_DIR just slides down the outside of the shell.
		var dir: Vector3 = e.get("dir", PRESS_DIR)
		var target: Transform3D = Transform3D(rest.basis, rest.origin + dir * (float(e["depth"]) * pressed))
		node.transform = node.transform.interpolate_with(target, w)

	if not _dpad.is_empty():
		_rock(_dpad, w)
	if not _dpad2.is_empty():
		_rock(_dpad2, w)

	if not _stick_l.is_empty():
		var click_l: float = 1.0 if (_cur_btn & (1 << ControllerBindings.JOYPAD_L3)) != 0 else 0.0
		_apply_pivot(_stick_l, _stick_basis(_cur_lstick), click_l, w)
	if not _stick_r.is_empty():
		var click_r: float = 1.0 if (_cur_btn & (1 << ControllerBindings.JOYPAD_R3)) != 0 else 0.0
		_apply_pivot(_stick_r, _stick_basis(_cur_rstick), click_r, w)


# Rock one D-pad about its pivot from the four bits it answers to, plus the
# analog stick named by "axis" if it has one.
func _rock(entry: Dictionary, w: float) -> void:
	var bits: Array = entry.get("bits", [ControllerBindings.JOYPAD_UP, ControllerBindings.JOYPAD_DOWN,
		ControllerBindings.JOYPAD_LEFT, ControllerBindings.JOYPAD_RIGHT])
	var pitch: float = float((_cur_btn >> int(bits[0])) & 1) - float((_cur_btn >> int(bits[1])) & 1)
	var roll: float  = float((_cur_btn >> int(bits[2])) & 1) - float((_cur_btn >> int(bits[3])) & 1)
	var axis: String = entry.get("axis", "")
	if not axis.is_empty():
		# Analog Y is positive DOWN and X positive RIGHT — the opposite sense to
		# the up-minus-down / left-minus-right sums above.
		var stick: Vector2 = _cur_rstick if axis == "right" else _cur_lstick
		pitch = clampf(pitch - stick.y, -1.0, 1.0)
		roll = clampf(roll - stick.x, -1.0, 1.0)
	var tilt := _dpad_tilt_deg()
	var r: Basis = Basis.from_euler(Vector3(deg_to_rad(pitch * tilt * _dpad_pitch_sign()), 0.0, deg_to_rad(roll * tilt)))
	_apply_pivot(entry, r, 0.0, w)


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
