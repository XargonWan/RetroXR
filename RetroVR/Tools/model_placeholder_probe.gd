extends Node

# Placeholder-model validation probe.
#   Spawns every system that has a bespoke model, in whatever mode the command
#   line selected, and for each one reports the model class, whether a licensed
#   "Shell" subtree survived, whether a "Primitive" stand-in is present, and
#   whether the generic grey box (SystemBody) is showing. Renders each into a
#   SubViewport and writes a PNG.

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")

const CASES: Array = [
	# Consoles with a bespoke model — every one must fall back to the grey box.
	["nes", ""], ["nes", "famicom"], ["atari_2600", ""], ["atari_5200", ""],
	["mega_drive", ""], ["mega_drive", "megadrive"], ["sega_saturn", ""],
	["dreamcast", ""], ["playstation", ""], ["playstation", "original"],
	["playstation2", ""], ["playstation2", "silver"], ["gamecube", ""],
	["nintendo_64", ""], ["dos", ""],
	# Handhelds — each must keep its screen/controls and wear a primitive shell.
	["game_boy", ""], ["game_boy_advance", ""], ["game_boy_advance", "sp"],
	["playstation_portable", ""], ["nds", ""], ["nds", "lite"], ["3ds", ""],
	["virtual_boy", ""], ["atari_lynx", ""], ["wonderswan", ""],
	["neo_geo_pocket", ""], ["pokemon_mini", ""], ["supervision", ""],
	# Control: a system with no bespoke model at all — the grey box baseline.
	["super_nes", ""],
]

var _sv: SubViewport = null
var _cam: Camera3D = null
var _out_dir := "user://model_probe_shots"


func _ready() -> void:
	get_tree().create_timer(600.0).timeout.connect(func() -> void: get_tree().quit(1))
	DirAccess.make_dir_recursive_absolute(_out_dir)
	print("[probe] mode=%s" % RetroModelPolicy.describe())
	print("[probe] placeholder_models=%s" % RetroModelPolicy.placeholder_models())
	_build_viewport()
	await get_tree().process_frame
	for c in CASES:
		await _run_case(c[0] as String, c[1] as String)
	print("[probe] DONE")
	get_tree().quit(0)


func _build_viewport() -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(640, 520)
	_sv.own_world_3d = true
	_sv.transparent_bg = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.17, 0.20)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 1.1
	env.environment = e
	_sv.add_child(env)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, -38, 0)
	key.light_energy = 1.5
	_sv.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, 140, 0)
	fill.light_energy = 0.5
	_sv.add_child(fill)

	_cam = Camera3D.new()
	_sv.add_child(_cam)
	_cam.current = true


func _run_case(systemid: String, variant: String) -> void:
	var sys: Node = SYSTEM_SCENE.instantiate()
	sys.systemid = systemid
	sys.model_variant = variant
	if sys is RigidBody3D:
		(sys as RigidBody3D).freeze = true
	_sv.add_child(sys)
	# Models do their shell work in _ready; a couple of them await a frame first.
	for i in range(6):
		await get_tree().process_frame

	var label := systemid if variant.is_empty() else "%s:%s" % [systemid, variant]
	var model: Node = null
	for ch in sys.get_children():
		if ch is RetroSystemModel:
			model = ch
			break

	var model_class := "<none>"
	var handheld := false
	if model != null:
		model_class = model.get_script().resource_path.get_file()
		handheld = model.is_handheld()
	var shells := _count_named(sys, "Shell")
	var prims := _count_named(sys, "Primitive")
	var body := sys.get_node_or_null("SystemBody") as MeshInstance3D
	var greybox := body != null and body.visible
	var meshes := _count_meshes(sys)
	# The invariant a placeholder build has to hold: imported GLB geometry always
	# bakes down to an ArrayMesh, so ANY that still renders is licensed trade
	# dress that leaked through.
	var imported := _imported_meshes(sys)
	var verdict := "OK" if imported.is_empty() else "LEAK"
	if RetroModelPolicy.licensed_models():
		verdict = "-"

	print("[probe] %-26s %-4s model=%-32s handheld=%-5s shell=%d primitive=%d greybox=%-5s meshes=%d imported=%d" % [
		label, verdict, model_class, str(handheld), shells, prims, str(greybox), meshes, imported.size()])
	for leak in imported:
		print("[probe]      LEAK %s -> %s" % [label, leak])

	_frame_camera(sys)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var img := _sv.get_texture().get_image()
	var fname := label.replace(":", "_")
	img.save_png("%s/%s.png" % [_out_dir, fname])

	sys.queue_free()
	await get_tree().process_frame


## Count nodes named exactly `want` anywhere under `root`.
func _count_named(root: Node, want: String) -> int:
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur.name == want:
			n += 1
		for ch in cur.get_children():
			stack.append(ch)
	return n


## Paths of every VISIBLE MeshInstance3D still carrying imported (ArrayMesh)
## geometry — i.e. licensed trade dress that survived into a placeholder build.
func _imported_meshes(root: Node) -> Array[String]:
	var out: Array[String] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D:
			var mi := cur as MeshInstance3D
			if mi.is_visible_in_tree() and mi.mesh is ArrayMesh:
				out.append(str(root.get_path_to(mi)))
		for ch in cur.get_children():
			stack.append(ch)
	return out


func _count_meshes(root: Node) -> int:
	var n := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D and (cur as MeshInstance3D).visible and (cur as MeshInstance3D).mesh != null:
			n += 1
		for ch in cur.get_children():
			stack.append(ch)
	return n


func _visible_aabb(root: Node) -> AABB:
	var out := AABB()
	var have := false
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D:
			var mi := cur as MeshInstance3D
			if mi.is_visible_in_tree() and mi.mesh != null:
				var a: AABB = mi.global_transform * mi.get_aabb()
				if not have:
					out = a
					have = true
				else:
					out = out.merge(a)
		for ch in cur.get_children():
			stack.append(ch)
	return out


func _frame_camera(sys: Node) -> void:
	var ab := _visible_aabb(sys)
	var ctr := ab.position + ab.size * 0.5
	var radius := maxf(ab.size.length() * 0.5, 0.06)
	var dist := radius / tan(deg_to_rad(_cam.fov * 0.5)) * 1.5
	var dir := Vector3(0.62, 0.52, 0.62).normalized()
	_cam.global_position = ctr + dir * dist
	_cam.look_at(ctr, Vector3.UP)
	_cam.near = maxf(dist * 0.01, 0.001)
	_cam.far = dist * 6.0
