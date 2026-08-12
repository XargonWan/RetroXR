## Interactive seat probe for the Atari 2600.
##
## Loads the shell with a part in it and lets you drag that part into the pose it
## should actually sit at, then prints values ready to paste into
## atari_2600_model.gd. Written because iterating on this from renders was
## costing far more than letting a human just look at it and say "there".
##
##   godot --path RetroXR res://Tools/cart_seat_probe.tscn -- --mode=cart
##   godot --path RetroXR res://Tools/cart_seat_probe.tscn -- --mode=port
##
## MODES
##   cart  the cartridge in its slot (default)
##   port  a controller plug against a rear joystick port. LEFT/RIGHT switches
##         which port with the [ and ] keys; both are printed, mirrored, on SPACE.
extends Node3D

const ROM := "Air Raid (USA).a26"
const PLUG_MESH := "res://Scenes/Objects/atari_2600_plug_joystick.res"

## Panel normal / cart insertion axis, and where the slot mouth sits along it.
const N := Vector3(0.0, 0.73610, 0.67688)
const PANEL_PROJ := 0.05359

## Starting guess for a rear controller port.
##
## The D-sub sockets are moulded into the shell rather than being separate
## meshes, so they cannot be read out by name — three attempts to find them
## (mesh name, vertex clustering, thresholding an orthographic render) all
## failed to isolate them. This is the neighbourhood off that render: upper rear
## face, a little over 100 mm out from centre. Expect to move it.
## Port 2's guess comes from the SECOND feature that thresholding found on the
## upper rear face. The two are not a symmetric pair, which is why each port has
## to be placed on its own rather than mirrored from the other.
const PORT_START := [
	[Vector3(0.07854, 0.07007, -0.09521), Vector3(17.499, 0.0, 0.0)],   # port 1
	[Vector3(-0.10907, 0.07007, -0.09521), Vector3(17.499, 0.0, 0.0)],  # port 2
]

var _part: Node3D = null
var _model: Node3D = null
var _hud: Label = null
var _cam: Camera3D = null
var _mode := "cart"
## Both ports, edited independently: [pos, rot] each. This shell's sockets are
## not symmetric, so one placement does NOT give the other.
var _port_pose: Array = [[Vector3.ZERO, Vector3.ZERO], [Vector3.ZERO, Vector3.ZERO]]
var _port_index := 0

var _pos := Vector3.ZERO
var _rot := Vector3.ZERO
var _cart_h := 0.0

var _yaw := 35.0
var _pitch := 28.0
var _dist := 0.55
var _focus := Vector3(0, 0.06, 0)
var _dragging := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			_mode = a.split("=")[1]

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.11, 0.12, 0.14)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.68)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.0
	sun.rotation_degrees = Vector3(-45, -30, 0)
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.light_energy = 0.6
	fill.rotation_degrees = Vector3(-15, 145, 0)
	add_child(fill)

	_model = Node3D.new()
	_model.set_script(load("res://Scripts/Objects/system_models/atari_2600_model.gd"))
	add_child(_model)
	await get_tree().process_frame

	if _mode == "port":
		_part = MeshInstance3D.new()
		(_part as MeshInstance3D).mesh = load(PLUG_MESH)
		add_child(_part)
		for i in range(2):
			_port_pose[i] = [PORT_START[i][0], PORT_START[i][1]]
		_pos = _port_pose[0][0]
		_rot = _port_pose[0][1]
		_focus = Vector3(_pos.x * 0.6, 0.055, -0.09)
		_dist = 0.32
		_yaw = 160.0
		_pitch = 22.0
	else:
		_part = load("res://Scenes/Objects/media/cartridge.tscn").instantiate()
		_part.systemid = "atari_2600"
		_part.rom_path = RomLibrary.rom_dir_for_system("atari_2600").path_join(ROM)
		_part.game_label = "Air Raid"
		add_child(_part)
		_part.freeze = true
		await get_tree().process_frame
		_cart_h = _aabb(_part).size.y
		var seat: Transform3D = _model.cart_seat_transform()
		_pos = seat.origin
		_rot = seat.basis.get_euler() * 180.0 / PI

	_cam = Camera3D.new()
	_cam.fov = 40.0
	add_child(_cam)
	_cam.current = true

	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(14, 10)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color(1, 1, 1))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)


func _aabb(root: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible and mi.mesh != null:
			var ab: AABB = (root.global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for c in n.get_children():
			stack.append(c)
	return acc


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(0.06, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(2.0, _dist * 1.1)
	elif ev is InputEventMouseMotion and _dragging:
		var mm := ev as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.4
		_pitch = clampf(_pitch + mm.relative.y * 0.3, -85.0, 85.0)
	elif ev is InputEventKey and (ev as InputEventKey).pressed \
			and not (ev as InputEventKey).echo:
		var k := (ev as InputEventKey).keycode
		if k == KEY_SPACE:
			_dump()
		elif k == KEY_ESCAPE:
			get_tree().quit(0)
		elif k == KEY_BRACKETLEFT or k == KEY_BRACKETRIGHT:
			# Switch which port is being edited, KEEPING each one's own pose.
			# They were mirrored automatically at first; that turned out to be
			# wrong — this shell's two sockets are not symmetric about the
			# centreline, so each has to be placed on its own.
			_port_pose[_port_index] = [_pos, _rot]
			_port_index = 1 - _port_index
			_pos = _port_pose[_port_index][0]
			_rot = _port_pose[_port_index][1]
			_focus = Vector3(_pos.x * 0.6, _focus.y, _focus.z)


## Three step tiers. The coarse one is for getting into the neighbourhood, the
## other two for actually seating a part — a plug in a socket is a sub-millimetre
## judgement and one modifier was not enough resolution to make it.
func _steps() -> Array:
	if Input.is_key_pressed(KEY_CTRL):
		return [0.00010, 0.02, "CTRL  ultra-fine  0.10 mm / 0.02 deg"]
	if Input.is_key_pressed(KEY_SHIFT):
		return [0.00050, 0.10, "SHIFT fine        0.50 mm / 0.10 deg"]
	return [0.005, 1.0, "      coarse      5 mm / 1.0 deg"]


func _process(delta: float) -> void:
	if _part == null or _cam == null or _hud == null:
		return
	var st := _steps()
	var lin: float = float(st[0]) * delta * 60.0
	var ang: float = float(st[1]) * delta * 60.0

	if Input.is_key_pressed(KEY_W):
		_pos -= N * lin if _mode == "cart" else Vector3(0, 0, 1) * lin
	if Input.is_key_pressed(KEY_S):
		_pos += N * lin if _mode == "cart" else Vector3(0, 0, 1) * lin
	if Input.is_key_pressed(KEY_A):
		_pos.x -= lin
	if Input.is_key_pressed(KEY_D):
		_pos.x += lin
	if Input.is_key_pressed(KEY_R):
		_pos.y += lin
	if Input.is_key_pressed(KEY_F):
		_pos.y -= lin
	if Input.is_key_pressed(KEY_Q):
		_pos.z -= lin
	if Input.is_key_pressed(KEY_E):
		_pos.z += lin
	if Input.is_key_pressed(KEY_UP):
		_rot.x += ang
	if Input.is_key_pressed(KEY_DOWN):
		_rot.x -= ang
	if Input.is_key_pressed(KEY_LEFT):
		_rot.y += ang
	if Input.is_key_pressed(KEY_RIGHT):
		_rot.y -= ang
	if Input.is_key_pressed(KEY_Z):
		_rot.z += ang
	if Input.is_key_pressed(KEY_X):
		_rot.z -= ang

	var b := Basis.from_euler(_rot * PI / 180.0)
	_part.transform = Transform3D(b, _pos)

	var ry := _yaw * PI / 180.0
	var rp := _pitch * PI / 180.0
	_cam.global_position = _focus + Vector3(
		cos(rp) * sin(ry), sin(rp), cos(rp) * cos(ry)) * _dist
	_cam.look_at(_focus, Vector3.UP)

	var extra := ""
	if _mode == "cart":
		var top_proj: float = (_pos + b.y * (_cart_h * 0.5)).dot(N)
		var exposed: float = top_proj - PANEL_PROJ
		extra = "\ncart %.1f mm | exposed %.1f mm | inserted %.1f mm (%.0f%%)" % [
			_cart_h * 1000.0, exposed * 1000.0, (_cart_h - exposed) * 1000.0,
			100.0 * (_cart_h - exposed) / maxf(_cart_h, 0.0001)]
	else:
		extra = "\nEDITING PORT %d of 2   ([ or ] switches; each is placed on its own)" \
			% (_port_index + 1)

	_hud.text = ("SEAT PROBE  mode=%s   (SPACE = print, ESC = quit)\n" % _mode
		+ "right-drag orbit | wheel zoom\n"
		+ "W/S %s   A/D x   R/F y   Q/E z   arrows pitch/yaw   Z/X roll\n"
			% ("in-out along slot" if _mode == "cart" else "in-out z")
		+ "step: %s\n\n" % st[2]
		+ "pos = Vector3(%.5f, %.5f, %.5f)\n" % [_pos.x, _pos.y, _pos.z]
		+ "rot = Vector3(%.2f, %.2f, %.2f) deg" % [_rot.x, _rot.y, _rot.z]
		+ extra)


func _dump() -> void:
	var b := Basis.from_euler(_rot * PI / 180.0)
	var lines := PackedStringArray()
	if _mode == "port":
		# Both ports, independently. This shell's sockets are NOT symmetric, so
		# there is no mirror to derive one from the other.
		_port_pose[_port_index] = [_pos, _rot]
		lines.append("=== controller ports ===")
		lines.append("const _PORT_POS := [")
		for i in range(2):
			var p: Vector3 = _port_pose[i][0]
			lines.append("\tVector3(%.5f, %.5f, %.5f),   # port %d"
				% [p.x, p.y, p.z, i + 1])
		lines.append("]")
		lines.append("const _PORT_ROT := [")
		for i in range(2):
			var r: Vector3 = _port_pose[i][1]
			lines.append("\tVector3(%.3f, %.3f, %.3f),   # port %d, degrees"
				% [r.x, r.y, r.z, i + 1])
		lines.append("]")
	else:
		var top_proj: float = (_pos + b.y * (_cart_h * 0.5)).dot(N)
		var exposed: float = top_proj - PANEL_PROJ
		var depth: float = _cart_h - exposed
		var mouth: Vector3 = _pos - b.y * (_cart_h * 0.5 - depth)
		lines.append("=== cart seat ===")
		lines.append("const _CART_SEAT_X := Vector3(%.5f, %.5f, %.5f)" % [b.x.x, b.x.y, b.x.z])
		lines.append("const _CART_SEAT_Y := Vector3(%.5f, %.5f, %.5f)" % [b.y.x, b.y.y, b.y.z])
		lines.append("const _CART_SEAT_Z := Vector3(%.5f, %.5f, %.5f)" % [b.z.x, b.z.y, b.z.z])
		lines.append("const _CART_MOUTH := Vector3(%.5f, %.5f, %.5f)" % [mouth.x, mouth.y, mouth.z])
		lines.append("const _CART_INSERT_DEPTH := %.5f" % depth)
		lines.append("# cart %.1f mm, exposed %.1f mm, inserted %.1f mm"
			% [_cart_h * 1000.0, exposed * 1000.0, depth * 1000.0])
	var text := "\n".join(lines)
	print(text)
	var f := FileAccess.open("user://cart_seat.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
		f.close()
		print("[probe] also written to: %s"
			% ProjectSettings.globalize_path("user://cart_seat.txt"))
