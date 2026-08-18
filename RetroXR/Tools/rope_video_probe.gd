## Renders each rope_tests case to PNG frames so the behaviour can be WATCHED.
## Throwaway visual companion to Tests/rope_tests.gd — same geometry, same solver
## settings, plus meshes, lights and a camera. Delete after use.
##
##   "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/rope_video_probe.tscn -- --case=table
##
## No --case runs everything. Frames land in res://probe_out/rope/<case>/.
extends Node3D

const FRAME_W := 640
const FRAME_H := 480
## Solver ticks per captured frame — 3 ticks of a 90 Hz sim per frame gives a
## 30 fps video in real time.
const TICKS_PER_FRAME := 3

var _sv: SubViewport = null
var _cam: Camera3D = null
var _stage: Node3D = null
var _only := ""


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			_only = arg.trim_prefix("--case=")
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[video] TIMEOUT"); get_tree().quit(1))

	_sv = SubViewport.new()
	_sv.size = Vector2i(FRAME_W, FRAME_H)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	_cam = Camera3D.new()
	_sv.add_child(_cam)
	_cam.current = true

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.13, 0.14, 0.17)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.62, 0.68)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, 35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	_run()


func _run() -> void:
	var cases := {
		"table": _case_table, "corner": _case_corner,
		"taut_corner": _case_taut_corner, "taut_pipe": _case_taut_pipe,
		"ledge": _case_ledge, "pipe": _case_pipe, "post": _case_post,
		"bridge": _case_bridge, "heap": _case_heap, "shelf": _case_shelf,
		"loose_table": _case_loose_table, "loose_edge": _case_loose_edge,
		"loose_height": _case_loose_height,
	}
	for name: String in cases:
		if not _only.is_empty() and _only != name:
			continue
		print("[video] ---- %s ----" % name)
		_stage = Node3D.new()
		add_child(_stage)
		await cases[name].call(name)
		_stage.queue_free()
		_stage = null
		await get_tree().physics_frame
		await get_tree().physics_frame
	print("[video] done")
	get_tree().quit(0)


# ── scenery ───────────────────────────────────────────────────────────────────

func _box(centre: Vector3, size: Vector3, col := Color(0.42, 0.44, 0.48)) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_stage.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	cs.position = centre
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.position = centre
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mi.material_override = mat
	body.add_child(mi)


func _cylinder(centre: Vector3, radius: float, height: float, upright := false) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	_stage.add_child(body)
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	cs.shape = shape
	cs.position = centre
	if not upright:
		cs.rotation_degrees = Vector3(0, 0, 90)
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	mi.mesh = m
	mi.position = centre
	if not upright:
		mi.rotation_degrees = Vector3(0, 0, 90)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.44, 0.48)
	mi.material_override = mat
	body.add_child(mi)


## A small red block standing in for whatever socket or machine the anchor is —
## a pinned rope end IS plugged into something, and without this it reads as
## the cord being held up by nothing.
func _anchor_marker(at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(0.03, 0.03, 0.03)
	mi.mesh = m
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.2, 0.2)
	mi.material_override = mat
	_stage.add_child(mi)
	return mi


var _end_marker: MeshInstance3D = null


func _rope_between(a: Vector3, b: Vector3, segments := 24, seg_len := 0.06) -> VerletRope:
	var na := Node3D.new()
	na.position = a
	_stage.add_child(na)
	var nb := Node3D.new()
	nb.position = b
	_stage.add_child(nb)
	_anchor_marker(a)
	_end_marker = _anchor_marker(b)
	var rope := VerletRope.new()
	_stage.add_child(rope)
	rope.constraint_iterations = 8
	rope.bend_stiffness = 0.2
	rope.collision_radius = 0.0045
	rope.surface_collision_mask = 7
	rope.self_collision = true
	rope.segment_count = segments
	rope.segment_length = seg_len
	rope.tube_radius = 0.006
	rope.rope_color = Color(0.9, 0.75, 0.2)
	rope.start_node = na
	rope.end_node = nb
	rope.set_process(false)
	rope.set_physics_process(false)
	rope._init_points()
	return rope


func _look(from: Vector3, at: Vector3) -> void:
	_cam.position = from
	_cam.look_at(at)


## Step a hand-driven rope and capture: TICKS_PER_FRAME solver ticks per frame.
## Returns the next frame index so a case can record in stages.
func _record(name: String, rope: VerletRope, ticks: int, start_frame := 0) -> int:
	var dir := "res://probe_out/rope/%s" % name
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var frame := start_frame
	var done := 0
	while done < ticks:
		for i in TICKS_PER_FRAME:
			rope.step(1.0 / 90.0)
		done += TICKS_PER_FRAME
		rope.remesh()
		await RenderingServer.frame_post_draw
		_sv.get_texture().get_image().save_png("%s/f%04d.png" % [dir, frame])
		frame += 1
	return frame


## Carry the rope's end anchor (and its socket marker) to `to`, capturing as it
## goes. Returns the next frame index.
func _record_carry(name: String, rope: VerletRope, to: Vector3, ticks: int, start_frame: int) -> int:
	var dir := "res://probe_out/rope/%s" % name
	var node: Node3D = rope.end_node
	var stride: Vector3 = (to - node.position) / float(ticks)
	var f := start_frame
	for i in ticks:
		node.position += stride
		if _end_marker != null:
			_end_marker.position = node.position
		rope.step(1.0 / 90.0)
		if i % TICKS_PER_FRAME == 0:
			rope.remesh()
			await RenderingServer.frame_post_draw
			_sv.get_texture().get_image().save_png("%s/f%04d.png" % [dir, f])
			f += 1
	return f


## Capture an engine-ticked scene (loose leads): every 3rd physics frame.
func _record_engine(name: String, frames: int) -> void:
	var dir := "res://probe_out/rope/%s" % name
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var frame := 0
	for f in frames:
		await get_tree().physics_frame
		if f % TICKS_PER_FRAME != 0:
			continue
		await RenderingServer.frame_post_draw
		_sv.get_texture().get_image().save_png("%s/f%04d.png" % [dir, frame])
		frame += 1


func _drop_lead(at: Vector3, yaw := 0.0) -> Node3D:
	var lead: Node3D = preload("res://Scenes/Objects/cables/trs_cable.tscn").instantiate()
	lead.position = at
	lead.rotation.y = yaw
	_stage.add_child(lead)
	return lead


# ── the cases, geometry copied from Tests/rope_tests.gd ───────────────────────

func _case_table(name: String) -> void:
	_box(Vector3(0, 0.70, 0), Vector3(2.0, 0.10, 2.0))
	var rope := _rope_between(Vector3(-0.3, 0.76, 0), Vector3(0.66, 0.76, 0), 16)
	_look(Vector3(0.5, 1.15, 1.1), Vector3(0.1, 0.78, 0))
	var f: int = await _record(name, rope, 120)
	f = await _record_carry(name, rope, Vector3(0.3, 0.76, 0), 90, f)
	await _record(name, rope, 690, f)


func _case_corner(name: String) -> void:
	_box(Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.0))
	_box(Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	var rope := _rope_between(Vector3(-0.9, 0.76, 0), Vector3(0.35, 0.76, 0), 34)
	_look(Vector3(1.1, 1.05, 1.7), Vector3(-0.25, 0.45, 0))
	var f: int = await _record(name, rope, 120)
	f = await _record_carry(name, rope, Vector3(0.30, 0.03, 0), 90, f)
	await _record(name, rope, 690, f)


func _case_taut_corner(name: String) -> void:
	_box(Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.0))
	var rope := _rope_between(Vector3(-0.9, 0.80, 0), Vector3(0.35, 0.05, 0), 24)
	_look(Vector3(0.6, 1.15, 1.6), Vector3(-0.2, 0.5, 0))
	await _record(name, rope, 900)


func _case_taut_pipe(name: String) -> void:
	_cylinder(Vector3(0, 1.00, 0), 0.12, 1.6)
	var rope := _rope_between(Vector3(0, 1.30, -0.30), Vector3(0, 0.30, 0.45), 24)
	_look(Vector3(1.6, 1.25, 0.9), Vector3(0, 0.85, 0.05))
	await _record(name, rope, 900)


func _case_ledge(name: String) -> void:
	_box(Vector3(0, 0.50, -0.10), Vector3(1.2, 0.50, 0.80))
	var rope := _rope_between(Vector3(0, 0.80, -0.40), Vector3(0, 0.80, 0.55), 20)
	_look(Vector3(1.5, 1.2, 1.2), Vector3(0, 0.6, 0.1))
	await _record(name, rope, 900)


func _case_pipe(name: String) -> void:
	_cylinder(Vector3(0, 1.00, 0), 0.12, 1.6)
	var rope := _rope_between(Vector3(0, 1.16, -0.40), Vector3(0, 1.16, 0.40), 21)
	_look(Vector3(1.5, 1.25, 0.9), Vector3(0, 1.0, 0))
	await _record(name, rope, 900)


func _case_post(name: String) -> void:
	_cylinder(Vector3(0, 0.50, 0), 0.05, 1.0, true)
	var rope := _rope_between(Vector3(-0.35, 1.15, 0), Vector3(0.35, 1.15, 0), 30)
	_look(Vector3(0.9, 1.1, 1.5), Vector3(0, 0.85, 0))
	await _record(name, rope, 900)


func _case_bridge(name: String) -> void:
	_box(Vector3(-0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(Vector3(0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	var rope := _rope_between(Vector3(-0.5, 0.76, 0), Vector3(0.5, 0.76, 0), 30)
	_look(Vector3(0.9, 1.3, 1.7), Vector3(0, 0.7, 0))
	await _record(name, rope, 900)


func _case_heap(name: String) -> void:
	_box(Vector3(0, 0.50, -0.10), Vector3(1.2, 0.50, 0.80))
	var rope := _rope_between(Vector3(0, 0.80, -0.30), Vector3(0, 0.80, 0.10), 40)
	_look(Vector3(0.55, 1.05, 0.5), Vector3(0, 0.76, -0.1))
	await _record(name, rope, 1200)


func _case_shelf(name: String) -> void:
	_box(Vector3(0, 0.50, -0.10), Vector3(1.2, 0.50, 0.80))
	_box(Vector3(0, -0.05, 0.60), Vector3(2.0, 0.10, 1.2))
	var rope := _rope_between(Vector3(0, 0.80, -0.30), Vector3(0, 0.03, 0.75), 40)
	_look(Vector3(1.7, 1.1, 1.4), Vector3(0, 0.45, 0.2))
	await _record(name, rope, 1200)


func _case_loose_table(name: String) -> void:
	_box(Vector3(0, 0.70, 0), Vector3(1.6, 0.10, 1.6))
	_drop_lead(Vector3(0, 1.10, 0))
	_look(Vector3(1.3, 1.5, 1.6), Vector3(0, 0.85, 0))
	await _record_engine(name, 480)


func _case_loose_edge(name: String) -> void:
	_box(Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.6))
	_box(Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))
	_drop_lead(Vector3(-0.20, 1.10, 0), PI * 0.5)
	_look(Vector3(1.3, 1.3, 1.9), Vector3(-0.2, 0.6, 0))
	await _record_engine(name, 660)


func _case_loose_height(name: String) -> void:
	_box(Vector3(0, 0.50, 0), Vector3(2.0, 0.02, 2.0))
	_drop_lead(Vector3(0, 2.00, 0))
	_look(Vector3(1.8, 1.7, 2.2), Vector3(0, 1.1, 0))
	await _record_engine(name, 540)
