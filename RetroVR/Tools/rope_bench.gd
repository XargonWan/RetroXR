## Rope solver bench — a fixed set of cables over a fixed bit of geometry, for
## A/B-ing changes to VerletRope's physics cost.
##
## The test hallway is a bad place to measure this: it costs seconds to build,
## and its ropes fall asleep at different times on every run, so the amount of
## work sampled changes between runs and swamps the effect being measured. Here
## the rope count, the anchor spacing and the tick count are all fixed.
##
## Run it headless so the number is the simulation and not the renderer:
##   godot --headless --path RetroVR res://Tools/rope_bench.tscn -- \
##       [--ropes=16] [--ticks=300] [--settle] [--nomesh]
##
## --shot=res://x.png renders the settled cables instead of timing them, for
## checking that a change meant to be behaviour-preserving actually is. That one
## needs a real window (drop --headless) — the dummy renderer returns a blank
## image.
##
## Default holds every rope awake for the whole run, so each tick does the same
## work and two runs are directly comparable. --settle instead lets them sleep
## and reports how long they take to do it, which is the other thing that
## decides the real frame cost. --nomesh stops the ropes re-meshing their tubes,
## leaving the solver on its own.
##
## The bench takes the ropes off the engine's physics callback and steps them
## itself inside a timer, so the number is CPU time actually spent in the solver.
## Measuring elapsed wall time per tick instead does NOT work: the main loop
## paces fixed-step ticks in real time, so any version that keeps up reports
## exactly 1/physics_ticks_per_second and every change looks free.
##
## Nothing is instrumented inside VerletRope, so this measures any revision of it
## as-is — including a stashed one, for an A/B.
extends Node3D

const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")

## Matches a hallway station: the cable spans system to TV across a table top.
const ANCHOR_SPAN := 0.45
const TABLE_TOP_Y := 0.75
const ANCHOR_Y := 0.80
const ROPE_PITCH := 1.0

var _ropes: Array[VerletRope] = []
var _rope_count := 16
var _measure_ticks := 300
var _warmup_ticks := 60
var _settle := false
var _nomesh := false
var _shot := ""
var _tick := 0
var _settled_at := -1
var _cpu_usec := 0
var _mesh_usec := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ropes="):
			_rope_count = maxi(int(a.get_slice("=", 1)), 1)
		elif a.begins_with("--ticks="):
			_measure_ticks = maxi(int(a.get_slice("=", 1)), 1)
		elif a == "--settle":
			_settle = true
		elif a == "--nomesh":
			_nomesh = true
		elif a.begins_with("--shot="):
			_shot = a.get_slice("=", 1)

	_build_world()
	for i in _rope_count:
		_build_rope(float(i) * ROPE_PITCH)
	for r in _ropes:
		r.set_physics_process(false)
		r.set_process(false)
	print("[bench] ropes=%d warmup=%d measure=%d mode=%s%s" % [
		_rope_count, _warmup_ticks, _measure_ticks,
		"settle" if _settle else "awake", " nomesh" if _nomesh else ""])


## Floor plus one table slab per rope — the surface-collision and rest passes
## need something to rest on or they measure nothing.
func _build_world() -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	_slab(body, Vector3(float(_rope_count) * ROPE_PITCH + 4.0, 0.2, 4.0),
		Vector3(float(_rope_count) * ROPE_PITCH * 0.5, -0.1, 0.0))
	for i in _rope_count:
		_slab(body, Vector3(0.9, 0.05, 0.7),
			Vector3(float(i) * ROPE_PITCH, TABLE_TOP_Y - 0.025, 0.0))


func _slab(body: StaticBody3D, size: Vector3, pos: Vector3) -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = pos
	body.add_child(col)


## Both ends held by plain Node3Ds, which VerletRope treats as fixed mounts —
## the same state a hallway cable is in with its plug socketed into a TV.
func _build_rope(x: float) -> void:
	var a := Node3D.new()
	a.position = Vector3(x - ANCHOR_SPAN * 0.5, ANCHOR_Y, 0.0)
	add_child(a)
	var b := Node3D.new()
	b.position = Vector3(x + ANCHOR_SPAN * 0.5, ANCHOR_Y, 0.0)
	add_child(b)

	var inst: Node3D = CABLE_SCENE.instantiate()
	add_child(inst)
	inst.get_node("CablePlug").queue_free()
	var rope := inst.get_node("VerletRope") as VerletRope
	rope.start_node = a
	rope.end_node = b
	rope.end_anchor_offset = Vector3.ZERO
	rope._init_points()
	_ropes.append(rope)


func _physics_process(delta: float) -> void:
	if not _settle:
		for r in _ropes:
			r.wake()

	var t0 := Time.get_ticks_usec()
	for r in _ropes:
		r._physics_process(delta)
	var spent := Time.get_ticks_usec() - t0

	# Tube re-mesh, timed apart from the solve: it is a per-RENDERED-frame cost
	# rather than a per-tick one, but it is the same GDScript budget and it is
	# worth knowing which of the two dominates a moving cable.
	var t1 := Time.get_ticks_usec()
	if not _nomesh:
		for r in _ropes:
			r._process(delta)
	var mesh_spent := Time.get_ticks_usec() - t1

	_tick += 1
	if _tick <= _warmup_ticks:
		return
	_cpu_usec += spent
	_mesh_usec += mesh_spent
	if _settle and _settled_at < 0 and _awake() == 0:
		_settled_at = _tick - _warmup_ticks
	if _tick < _warmup_ticks + _measure_ticks:
		return

	print("[bench] solve: ms_per_tick=%.3f us_per_rope_tick=%.1f" % [
		float(_cpu_usec) / float(_measure_ticks) / 1000.0,
		float(_cpu_usec) / float(_measure_ticks) / float(_rope_count)])
	print("[bench] remesh: ms_per_tick=%.3f us_per_rope_tick=%.1f" % [
		float(_mesh_usec) / float(_measure_ticks) / 1000.0,
		float(_mesh_usec) / float(_measure_ticks) / float(_rope_count)])
	if _settle:
		print("[bench] settled_at_tick=%d still_awake=%d" % [_settled_at, _awake()])
	if _shot.is_empty():
		get_tree().quit(0)
	else:
		_capture()


## Render the first three cables side-on into a SubViewport. The window viewport
## reads back as clear colour, so the shot has to be taken through one of these.
func _capture() -> void:
	set_physics_process(false)
	var sv := SubViewport.new()
	sv.size = Vector2i(900, 400)
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.8)
	e.ambient_light_energy = 0.6
	env.environment = e
	sv.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -35.0, 0.0)
	sv.add_child(sun)

	# The ropes are top_level at the world origin, so they must be reparented
	# rather than copied — their geometry is already in world space.
	for r in _ropes:
		var p := r.get_parent()
		if p != null:
			p.remove_child(r)
		sv.add_child(r)
	for c in get_children():
		if c is StaticBody3D:
			remove_child(c)
			sv.add_child(c)

	var cam := Camera3D.new()
	cam.position = Vector3(ROPE_PITCH, ANCHOR_Y - 0.02, 1.15)
	cam.look_at_from_position(cam.position, Vector3(ROPE_PITCH, ANCHOR_Y - 0.10, 0.0))
	sv.add_child(cam)
	cam.current = true

	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	sv.get_texture().get_image().save_png(_shot)
	print("[bench] shot=%s" % _shot)
	get_tree().quit(0)


func _awake() -> int:
	var n := 0
	for r in _ropes:
		if not r._asleep:
			n += 1
	return n
