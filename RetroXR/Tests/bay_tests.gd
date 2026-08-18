## Cartridge-bay self-tests — how media is offered, how it goes in, and when the
## machine is actually wired to it. Headless, no core, no ROM, no headset.
##
##     "$godot" --headless --path RetroXR res://Tests/bay_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/bay_tests.tscn -- --only=tray
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## These need a REAL system in the tree — a hardware model, its GLB and its snap
## zones — which is exactly what system_tests.gd cannot have (it builds RetroSystem
## with .new() and never adds it). Hence a suite of their own.
##
## Groups:
##   perch/   what a held cart or plug is SHOWN as, and where a released one lands
##   tray/    the NES ZIF cradle: up, pushed home, lifted, and who is connected
##   plug/    a controller plug offered off its socket and slid in
##   restore/ a save comes back latched, without the slide
##   other/   a deck with no push tray is untouched by any of it
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")

var _checks := 0
var _failed := 0
var _cases_failed := 0
var _only := ""
var _spawned: Array[Node] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[bay] TIMED OUT")
		get_tree().quit(1))
	await _run()
	print("[bay] %d checks, %d case(s) failed" % [_checks, _cases_failed])
	print("[bay] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		_cases_failed += 1
	print("[bay] %s  %s" % ["PASS" if ok else "FAIL", what])


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


## A console in the tree, modelled and cabled up the way the room spawns one.
func _console(model_id: String, systemid: String) -> Node3D:
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.model_id = model_id
	sys.systemid = systemid
	sys.position = Vector3(_spawned.size() * 2.0, 1, 0)
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(90)          # the shell's GLB has to land before the bay is placed
	return sys


func _cart(systemid: String) -> Node3D:
	var cart := CART_SCENE.instantiate() as Node3D
	cart.systemid = systemid
	cart.position = Vector3(0, 3, 0)
	cart.freeze = true
	add_child(cart)
	_spawned.append(cart)
	await _wait(10)
	return cart


func _clear() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.queue_free()
	_spawned.clear()
	await _wait(10)


# --- perch ----------------------------------------------------------------------

func _group_perch() -> void:
	var sys := await _console("nes", "nes")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("nes")

	_check(slot.preview_offset.length() > 0.02,
		"perch/the bay stands a held cart proud of the mouth")

	# The offer runs along the TRAY's axis, which is tilted up while the tray is
	# up — not along the console's level front.
	var seat := slot.snap_pose_for(cart)
	var ghost := slot.preview_pose_for(cart)
	var axis: Vector3 = sys._model.get_cartridge_insert_direction()
	var offer := ghost.origin - seat.origin
	var along := offer.dot(axis)
	_check(along > 0.02, "perch/the offer is out of the machine, not into it")
	_check((offer - axis * along).length() < 0.002, "perch/and square to the mouth")
	var level: Vector3 = sys.global_transform.basis.z.normalized()
	_check(axis.dot(level) < 0.9995,
		"perch/the mouth is tilted up, so the offer is too")

	# The point of measuring the distance rather than writing one down: the ghost
	# has to stand OUTSIDE the shell, and this bay seats a cart 21.5 mm inside its
	# own front face, so a nominal centimetre would leave it buried.
	var deck := sys.find_child("NesDeck", true, false) as MeshInstance3D
	var to_model := sys.global_transform.affine_inverse()
	var front_z: float = ((to_model * deck.global_transform) * deck.get_aabb()).end.z
	var half: float = MediaDimensions.cart_size("nes").y * 0.5
	var face_z: float = (to_model * (ghost.origin + axis * half)).z
	_check(face_z > front_z, "perch/the ghost's cart stands proud of the front face")

	slot.pick_up_object(cart)
	await _wait(40)
	_check(cart.global_position.distance_to(slot.snap_pose_for(cart).origin) < 0.003,
		"perch/a released cart ends at the seat, not the perch")
	await _clear()


# --- tray -----------------------------------------------------------------------

func _group_tray() -> void:
	var sys := await _console("nes", "nes")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("nes")

	_check(sys.has_push_tray_bay(), "tray/the NES bay is a push tray")
	_check(not sys._model.is_tray_down(), "tray/an empty bay rests up")

	slot.pick_up_object(cart)
	await _wait(40)
	var up_pose := cart.global_transform
	# How far the mouth points up: sin(TRAY_UP_DEG) while the tray is sprung up,
	# nothing at all once it is home.
	var up_axis_rise: float = sys._model.get_cartridge_insert_direction().y
	_check(sys._snapped_cartridge == null,
		"tray/a cart laid in is not read yet")
	_check(sys._tray_cartridge == cart, "tray/but the bay knows it is lying there")

	sys.toggle_cart_tray()
	await _wait(20)
	var down_axis_rise: float = sys._model.get_cartridge_insert_direction().y
	_check(sys._model.is_tray_down(), "tray/a click pushes it home")
	_check(sys._snapped_cartridge == cart, "tray/and only then is it read")

	# The cart travels with the tray: its nose drops as the cradle levels out.
	var down_pose := cart.global_transform
	_check(up_pose.origin.y - down_pose.origin.y > 0.0005,
		"tray/the cart comes down with the tray")
	_check(down_axis_rise < up_axis_rise and absf(down_axis_rise) < 0.005,
		"tray/and levels out as it goes")

	sys.toggle_cart_tray()
	await _wait(20)
	_check(not sys._model.is_tray_down(), "tray/a second click lifts it")
	_check(sys._snapped_cartridge == null,
		"tray/lifting takes the cart off the machine")
	_check(slot.picked_up_object == cart, "tray/but leaves it lying in the tray")

	# Shut the bay for the move: a cart let go inside its own grab sphere is caught
	# straight back by it, which is the room's behaviour and not what this asks.
	slot.enabled = false
	slot.drop_object()
	cart.global_position += Vector3(0, 0.5, 0)
	await _wait(20)
	_check(sys._tray_cartridge == null, "tray/taking it out empties the bay")
	await _clear()


# --- plug -----------------------------------------------------------------------

func _group_plug() -> void:
	var sys := await _console("nes", "nes")
	var port := sys.get_node("ControllerPort1") as XRToolsSnapZone
	_check(port.preview_offset.length() > 0.005,
		"plug/a plug is offered off the socket, not inside it")

	var pad := PAD_SCENE.instantiate() as Node3D
	pad.position = Vector3(0, 2, 0)
	add_child(pad)
	_spawned.append(pad)
	await _wait(30)
	# RetroController hangs its cable off the current scene, not off itself.
	var plug := get_tree().current_scene.find_child("ControllerPlug", true, false) as Node3D
	if plug != null and is_instance_valid(plug.get_parent()):
		_spawned.append(plug.get_parent())
	if plug == null:
		_check(false, "plug/the pad has a plug on its cord")
		await _clear()
		return

	var ghost := port.preview_pose_for(plug)
	var seat := port.snap_pose_for(plug)
	var out: Vector3 = port.global_transform.basis.z.normalized()
	_check((ghost.origin - seat.origin).dot(out) > 0.005,
		"plug/the offer stands off the socket's own axis")

	port.pick_up_object(plug)
	await _wait(40)
	_check(plug.global_position.distance_to(port.snap_pose_for(plug).origin) < 0.003,
		"plug/a released plug ends in the socket")
	await _clear()


# --- restore --------------------------------------------------------------------

func _group_restore() -> void:
	var sys := await _console("nes", "nes")
	var cart := await _cart("nes")

	sys.restore_cartridge(cart)
	await _wait(4)
	# Four frames is far inside the 0.25 s slide: a restore that animated would
	# still be out at the perch here.
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	_check(cart.global_position.distance_to(slot.snap_pose_for(cart).origin) < 0.003,
		"restore/a restored cart does not slide in")
	_check(sys._model.is_tray_down(), "restore/it comes back with the tray home")
	_check(sys._snapped_cartridge == cart, "restore/and the machine reading it")
	await _clear()


# --- other ----------------------------------------------------------------------

func _group_other() -> void:
	var sys := await _console("atari_2600", "atari2600")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("atari2600")

	_check(not sys.has_push_tray_bay(), "other/a plain deck has no push tray")
	_check(slot.preview_offset == Vector3.ZERO,
		"other/and offers its cart at the seat, as before")

	slot.pick_up_object(cart)
	await _wait(40)
	_check(sys._snapped_cartridge == cart,
		"other/a cart it takes is read straight away")
	await _clear()


func _run() -> void:
	if _want("perch"):
		await _group_perch()
	if _want("tray"):
		await _group_tray()
	if _want("plug"):
		await _group_plug()
	if _want("restore"):
		await _group_restore()
	if _want("other"):
		await _group_other()
