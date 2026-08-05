## Interactive cart-seat probe.
##
## Loads the Atari 2600 shell with a cartridge in it and lets you drag the cart
## into the pose it should actually sit at, then prints values ready to paste
## into atari_2600_model.gd. Written because iterating on this from renders was
## costing far more than letting a human just look at it and say "there".
##
##   run:  Godot --path RetroXR res://Tools/cart_seat_probe.tscn
extends Node3D

const ROM := "Air Raid (USA).a26"

## Panel normal / insertion axis, and where the slot mouth sits along it.
const N := Vector3(0.0, 0.73610, 0.67688)
const PANEL_PROJ := 0.05359

var _cart: Node3D = null
var _model: Node3D = null
var _hud: Label = null
var _cam: Camera3D = null

# pose being edited, in the console's local space
var _pos := Vector3.ZERO
var _rot := Vector3.ZERO          # euler degrees
var _cart_h := 0.0

# camera orbit
var _yaw := 35.0
var _pitch := 28.0
var _dist := 0.55
var _focus := Vector3(0, 0.09, 0)
var _dragging := false


func _ready() -> void:
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

	_cart = load("res://Scenes/Objects/cartridge.tscn").instantiate()
	_cart.systemid = "atari_2600"
	_cart.rom_path = RomLibrary.rom_dir_for_system("atari_2600").path_join(ROM)
	_cart.game_label = "Air Raid"
	add_child(_cart)
	_cart.freeze = true
	await get_tree().process_frame
	_cart_h = _aabb(_cart).size.y

	# start from whatever the model currently believes
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
		if mi != null and mi.visible:
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
			_dist = maxf(0.12, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(2.0, _dist * 1.1)
	elif ev is InputEventMouseMotion and _dragging:
		var mm := ev as InputEventMouseMotion
		_yaw -= mm.relative.x * 0.4
		_pitch = clampf(_pitch + mm.relative.y * 0.3, -20.0, 85.0)
	elif ev is InputEventKey and (ev as InputEventKey).pressed \
			and not (ev as InputEventKey).echo:
		if (ev as InputEventKey).keycode == KEY_SPACE:
			_dump()
		elif (ev as InputEventKey).keycode == KEY_ESCAPE:
			get_tree().quit(0)


func _process(delta: float) -> void:
	# _ready() awaits, so _process runs while it is still part-way through —
	# every node it builds has to be checked, not just the first one.
	if _cart == null or _cam == null or _hud == null:
		return
	var fine := Input.is_key_pressed(KEY_SHIFT)
	var lin := (0.004 if fine else 0.03) * delta * 60.0
	var ang := (0.15 if fine else 1.2) * delta * 60.0

	# W/S drive the cart along the slot, which is the axis that matters
	if Input.is_key_pressed(KEY_W):
		_pos -= N * lin
	if Input.is_key_pressed(KEY_S):
		_pos += N * lin
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
	_cart.transform = Transform3D(b, _pos)

	var rad_y := _yaw * PI / 180.0
	var rad_p := _pitch * PI / 180.0
	var off := Vector3(
		cos(rad_p) * sin(rad_y), sin(rad_p), cos(rad_p) * cos(rad_y)) * _dist
	_cam.global_position = _focus + off
	_cam.look_at(_focus, Vector3.UP)

	var top_proj: float = (_pos + b.y * (_cart_h * 0.5)).dot(N)
	var exposed: float = top_proj - PANEL_PROJ
	_hud.text = ("CART SEAT PROBE   (SPACE = print values, ESC = quit)\n"
		+ "right-drag orbit | wheel zoom | SHIFT = fine steps\n"
		+ "W/S in-out along slot   A/D x   R/F y   Q/E z\n"
		+ "arrows pitch/yaw   Z/X roll\n\n"
		+ "pos  = (%.5f, %.5f, %.5f)\n" % [_pos.x, _pos.y, _pos.z]
		+ "rot  = (%.2f, %.2f, %.2f) deg\n" % [_rot.x, _rot.y, _rot.z]
		+ "cart height %.1f mm | exposed %.1f mm | inserted %.1f mm (%.0f%%)"
			% [_cart_h * 1000.0, exposed * 1000.0, (_cart_h - exposed) * 1000.0,
				100.0 * (_cart_h - exposed) / maxf(_cart_h, 0.0001)])


func _dump() -> void:
	var b := Basis.from_euler(_rot * PI / 180.0)
	var top_proj: float = (_pos + b.y * (_cart_h * 0.5)).dot(N)
	var exposed: float = top_proj - PANEL_PROJ
	var depth: float = _cart_h - exposed
	# Express the pose the way the model stores it: the point where the cart's
	# axis crosses the panel face, plus how far past it the cart sits.
	# mouth = bottom of the cart, pushed back out by the insert depth.
	var mouth: Vector3 = _pos - b.y * (_cart_h * 0.5 - depth)
	var lines := PackedStringArray()
	lines.append("=== cart seat ===")
	lines.append("const _CART_SEAT_X := Vector3(%.5f, %.5f, %.5f)" % [b.x.x, b.x.y, b.x.z])
	lines.append("const _CART_SEAT_Y := Vector3(%.5f, %.5f, %.5f)" % [b.y.x, b.y.y, b.y.z])
	lines.append("const _CART_SEAT_Z := Vector3(%.5f, %.5f, %.5f)" % [b.z.x, b.z.y, b.z.z])
	lines.append("const _CART_MOUTH := Vector3(%.5f, %.5f, %.5f)" % [mouth.x, mouth.y, mouth.z])
	lines.append("const _CART_INSERT_DEPTH := %.5f" % depth)
	lines.append("# raw pos = (%.5f, %.5f, %.5f)  rot = (%.3f, %.3f, %.3f) deg"
		% [_pos.x, _pos.y, _pos.z, _rot.x, _rot.y, _rot.z])
	lines.append("# cart height %.1f mm, exposed %.1f mm, inserted %.1f mm"
		% [_cart_h * 1000.0, exposed * 1000.0, depth * 1000.0])
	var text := "\n".join(lines)
	print(text)
	var f := FileAccess.open("user://cart_seat.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
		f.close()
		print("[probe] also written to: %s"
			% ProjectSettings.globalize_path("user://cart_seat.txt"))
