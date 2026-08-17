## VerletRope behaviour tests — what a cord does when it meets the world.
##
##     "$godot" --headless --path RetroXR res://Tests/rope_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/rope_tests.tscn -- --only=contact
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## The rope already has two BIT-EXACT oracles — `Tools/rope_bench.tscn --settle`
## and `Tools/rope_stress.tscn` — and they are excellent at the one thing they do:
## catching arithmetic drift. Neither can tell you whether a cord lying on a table
## corner jitters, whether one draped over a pipe falls through it, or whether a
## lead dropped on a shelf tunnels. Those are the failures a player sees, and
## nothing asserted them until this file.
##
## So the assertions here are INVARIANTS WITH TOLERANCES, never poses. Settling is
## chaotic — the bench's own settle count is a chaotic integer — so "sleeps within
## 600 ticks" is a real claim and "sleeps at tick 412" is a coin toss. Every
## threshold below was measured first and then given margin; each case prints its
## measurement next to its verdict so a near-miss is visible before it fails.
##
## The rope is driven the way the bench drives it: `set_physics_process(false)` and
## `step()` called by hand, in batches inside one physics frame so the space-state
## queries the solver issues stay legal. That makes a 600-tick case cost a few
## frames rather than ten seconds.
##
## Cases are laid out along X, `CASE_PITCH` apart, so no case's geometry can reach
## another's — the same trick `rope_stress.gd` uses.
extends Node3D

const CABLE_SCENE := preload("res://Scenes/Objects/cables/cable.tscn")

## Ticks per physics frame. The solver's world queries are only legal inside a
## physics frame, so the batch runs there rather than in a tight loop of its own.
const BATCH := 30
const CASE_PITCH := 60.0
## The window a "has it stopped moving?" question is asked over.
const STILL_WINDOW := 60
## A settled cord may still move this much per tick when it is denied sleep.
## Measured across every contact case below: 0.20 mm on a pipe, 0.27 wrapping a
## ledge, 0.34 over a corner, 0.72 pulled taut round one. 1.5 is about twice the
## worst of them, so ordinary variation passes and a contact that has started
## fighting itself does not.
const STILL_MM := 1.5
## A cord heaped on itself is the one shape that keeps churning: the self-collision
## pass has dozens of near-coincident pairs to separate and never quite finishes.
## Measured at 8.9 mm/tick, and kept as its own case rather than hidden by
## loosening STILL_MM for everything.
const HEAP_STILL_MM := 15.0

var _pass := 0
var _fail := 0
var _only := ""
var _x := 0.0
var _rope: VerletRope = null
var _holder: Node3D = null


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
	# A test scene must never hang a headless run.
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	await _group_contact()
	await _group_integrity()
	await _group_anchors()
	await _group_sleep()
	await _group_budget()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ── harness ───────────────────────────────────────────────────────────────────

func _wants(group: String) -> bool:
	return _only.is_empty() or _only == group


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s%s" % [name, "  (" + detail + ")" if detail else ""])
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if detail else ""])


## A patch of world for one case, far enough along X to be its own universe.
func _new_case() -> Vector3:
	_x += CASE_PITCH
	return Vector3(_x, 0.0, 0.0)


## A static box. Everything the rope collides with is built here rather than
## authored, so a case reads as its own geometry.
func _box(centre: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	col.position = centre
	body.add_child(col)
	return body


## A static cylinder, lying along X unless `upright`.
func _cylinder(centre: Vector3, radius: float, height: float, upright := false) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	col.shape = shape
	col.position = centre
	if not upright:
		col.rotation_degrees = Vector3(0, 0, 90)   # long axis along X
	body.add_child(col)
	return body


## A bare rope between two plain Node3D anchors. Plain nodes, not RigidBodies:
## the rope treats a RigidBody anchor as a PLUG and rotates it to face the cord,
## which is a different behaviour and not what most of these cases are about.
func _rope_between(a: Vector3, b: Vector3, segments := 24, seg_len := 0.06) -> VerletRope:
	_holder = Node3D.new()
	add_child(_holder)
	var na := Node3D.new()
	na.position = a
	_holder.add_child(na)
	var nb := Node3D.new()
	nb.position = b
	_holder.add_child(nb)
	var rope := VerletRope.new()
	_holder.add_child(rope)
	# Solver settings copied from cable.tscn. A bare VerletRope takes the C++
	# defaults, which are softer than anything that ships, and every threshold
	# below would then be measuring a cord the room does not contain.
	rope.constraint_iterations = 8
	rope.bend_stiffness = 0.2
	rope.collision_radius = 0.0045
	rope.surface_collision_mask = 7
	rope.self_collision = true
	rope.segment_count = segments
	rope.segment_length = seg_len
	rope.start_node = na
	rope.end_node = nb
	rope.set_process(false)
	rope.set_physics_process(false)
	rope._init_points()
	_rope = rope
	return rope


## A rope with one end loose, so it can be dropped onto something.
func _rope_from(a: Vector3, toward: Vector3, segments := 24, seg_len := 0.06) -> VerletRope:
	var rope := _rope_between(a, toward, segments, seg_len)
	rope.end_node = null
	rope._init_points()
	return rope


func _drop_case() -> void:
	if is_instance_valid(_holder):
		_holder.queue_free()
	_holder = null
	_rope = null
	await get_tree().physics_frame


## Run the solver `ticks` times, in batches inside physics frames.
func _settle(ticks: int) -> void:
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.step(1.0 / 90.0)
		done += n


## Largest distance any particle moved in a single tick, over `ticks` ticks.
func _max_step(ticks: int) -> float:
	var worst := 0.0
	var prev: PackedVector3Array = _rope.get_points()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.step(1.0 / 90.0)
			var now: PackedVector3Array = _rope.get_points()
			if now.size() == prev.size():
				for p in now.size():
					worst = maxf(worst, prev[p].distance_to(now[p]))
			prev = now
		done += n
	return worst


## Step until the cord sleeps or `limit` ticks run out, and report how much it was
## still moving in the last `STILL_WINDOW` ticks IT WAS AWAKE.
##
## Measuring movement after it sleeps is how a jitter test quietly stops testing
## anything: `step()` on a sleeping rope is a no-op, so every particle is
## identical and the answer is a confident 0.000 mm no matter how badly the cord
## chattered on its way there. The two numbers that matter are whether it settled
## at all — a contact limit cycle shows up as a cord that never sleeps — and how
## small its movement had got just before it did.
##
## Returns {slept, tick, worst_awake, last_awake}: the largest single-tick
## movement anywhere in the window, and the largest in the final tick.
func _settle_profile(limit: int) -> Dictionary:
	var ring: Array[float] = []
	var prev: PackedVector3Array = _rope.get_points()
	var tick := 0
	while tick < limit and not _rope.is_sleeping():
		await get_tree().physics_frame
		for i in BATCH:
			if tick >= limit or _rope.is_sleeping():
				break
			_rope.step(1.0 / 90.0)
			tick += 1
			var now: PackedVector3Array = _rope.get_points()
			var worst := 0.0
			if now.size() == prev.size():
				for p in now.size():
					worst = maxf(worst, prev[p].distance_to(now[p]))
			prev = now
			ring.append(worst)
			if ring.size() > STILL_WINDOW:
				ring.remove_at(0)
	var window_worst := 0.0
	for v in ring:
		window_worst = maxf(window_worst, v)
	return {
		"slept": _rope.is_sleeping(),
		"tick": tick,
		"worst_awake": window_worst,
		"last_awake": ring[ring.size() - 1] if not ring.is_empty() else 0.0,
	}


## The jitter verdict, shared by every contact case. Two independent questions,
## because either one alone can be fooled:
##
## 1. DOES IT SETTLE AT ALL. The contact-chatter limit cycle this solver has had
##    before shows up as a cord that never sleeps — it twitches a fraction of a
##    millimetre a tick, forever, and burns a physics budget the Quest does not
##    have. "Still awake after N ticks" is that failure, stated directly.
##
## 2. IS IT ACTUALLY STILL. Sleep on its own proves nothing about jitter: a
##    sleeping rope's step() is a no-op, so movement reads a confident 0.000 mm
##    however badly it chattered on the way. So the cord is held AWAKE with
##    wake() for a further window and measured there. A settled contact reads
##    micrometres; a contact fighting itself reads millimetres, and the sleep
##    system can no longer hide it.
func _assert_settles(name: String, limit: int, still_mm: float) -> void:
	var prof := await _settle_profile(limit)
	_ok("contact/%s settles" % name, prof["slept"],
		"still awake after %d ticks, moving %.3f mm/tick"
			% [prof["tick"], float(prof["worst_awake"]) * 1000.0])
	var residual := await _awake_residual(240)
	_ok("contact/%s is still when it is settled" % name, residual * 1000.0 < still_mm,
		"%.4f mm/tick held awake (slept at tick %d)" % [residual * 1000.0, prof["tick"]])


## Largest per-tick movement over `ticks`, with the rope forbidden to sleep. This
## is the chatter amplitude: whatever the cord is still doing once it has finished
## falling, measured where the sleep system cannot mask it.
func _awake_residual(ticks: int) -> float:
	var worst := 0.0
	var prev: PackedVector3Array = _rope.get_points()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			_rope.wake()
			_rope.step(1.0 / 90.0)
			var now: PackedVector3Array = _rope.get_points()
			if now.size() == prev.size():
				for pt in now.size():
					worst = maxf(worst, prev[pt].distance_to(now[pt]))
			prev = now
		done += n
	return worst


func _points() -> PackedVector3Array:
	return _rope.get_points()


func _lowest_y() -> float:
	var y := 1e9
	for p: Vector3 in _points():
		y = minf(y, p.y)
	return y


func _all_finite() -> bool:
	for p: Vector3 in _points():
		if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)):
			return false
	return true


## Longest segment as a multiple of its rest length.
func _max_stretch() -> float:
	var pts := _points()
	var rest: float = _rope.segment_length
	var worst := 0.0
	for i in range(mini(pts.size(), _rope.segment_count + 1) - 1):
		worst = maxf(worst, pts[i].distance_to(pts[i + 1]) / rest)
	return worst


## How deep any particle sits inside an axis-aligned box, in metres. Zero means
## the cord stayed outside it.
func _deepest_in_box(centre: Vector3, size: Vector3) -> float:
	var half := size * 0.5
	var worst := 0.0
	for p: Vector3 in _points():
		var d := Vector3(half.x - absf(p.x - centre.x),
			half.y - absf(p.y - centre.y), half.z - absf(p.z - centre.z))
		if d.x > 0.0 and d.y > 0.0 and d.z > 0.0:
			worst = maxf(worst, minf(d.x, minf(d.y, d.z)))
	return worst


## How far inside a cylinder lying along X any particle sits.
func _deepest_in_cylinder(centre: Vector3, radius: float, half_len: float) -> float:
	var worst := 0.0
	for p: Vector3 in _points():
		if absf(p.x - centre.x) > half_len:
			continue
		var r := Vector2(p.y - centre.y, p.z - centre.z).length()
		worst = maxf(worst, radius - r)
	return worst


func _centroid() -> Vector3:
	var pts := _points()
	var sum := Vector3.ZERO
	for p: Vector3 in pts:
		sum += p
	return sum / maxf(float(pts.size()), 1.0)


# ── contact ───────────────────────────────────────────────────────────────────
# What a cord does when it meets furniture. Every case here is something a player
# does to a lead without thinking about it.

func _group_contact() -> void:
	if not _wants("contact"):
		return

	# Slack cord dropped onto a table top. The floor of everything else: if a cord
	# cannot lie still on a flat surface, nothing below is worth reading.
	var base := _new_case()
	_box(base + Vector3(0, 0.70, 0), Vector3(2.0, 0.10, 2.0))
	_rope_between(base + Vector3(-0.3, 0.95, 0), base + Vector3(0.3, 0.95, 0))
	await _assert_settles("a cord on a table", 1500, STILL_MM)
	var top := base.y + 0.75
	var sink := top - _lowest_y()
	_ok("contact/lies on a table", sink < _rope.collision_radius + 0.005,
		"rests %.1f mm above the surface" % (-sink * 1000.0))
	await _drop_case()

	# THE JITTER CASE. A cord half on a table and half over its edge is the shape
	# that has produced a contact-chatter limit cycle in this solver before: the
	# overhang pulls, the contact pushes back, and the pair never agree. Measured
	# as movement, not as sleep, so it fails even if the sleep test is loosened.
	base = _new_case()
	_box(base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.0))
	_rope_between(base + Vector3(-0.9, 0.95, 0), base + Vector3(-0.2, 0.95, 0))
	await _assert_settles("a cord over a table corner", 1500, STILL_MM)
	await _drop_case()

	# TAUT around the corner, which is the shape that actually chatters: the cord
	# is pulled hard against the top face AND the front face at once, so the
	# contact normal at the edge particle flips between them. Slack drapes settle
	# by falling; this one has to settle against a live tension.
	base = _new_case()
	_box(base + Vector3(-0.5, 0.70, 0), Vector3(1.0, 0.10, 1.0))
	_rope_between(base + Vector3(-0.9, 0.80, 0), base + Vector3(0.35, 0.05, 0), 24)
	await _assert_settles("a cord pulled taut round a corner", 1800, STILL_MM)
	await _drop_case()

	# The same question on a round edge, where the contact normal turns
	# continuously instead of flipping between two faces.
	base = _new_case()
	_cylinder(base + Vector3(0, 1.00, 0), 0.12, 1.6)
	_rope_between(base + Vector3(0, 1.30, -0.30), base + Vector3(0, 0.30, 0.45), 24)
	await _assert_settles("a cord pulled taut over a pipe", 1800, STILL_MM)
	await _drop_case()

	# Wrapped over a ledge, anchored on both sides of it. The cord has to bend
	# round the edge and stay outside the solid.
	# Laid ALONG the top and over the front edge, not strung from one side to the
	# other: a straight lay between two sides cuts the corner, and a particle that
	# starts deep inside a solid has no contact plane to be pushed out along. This
	# is also how a lead actually gets there — dropped on the surface, and the
	# overhang drapes.
	base = _new_case()
	var ledge_c := base + Vector3(0, 0.50, -0.10)
	var ledge_s := Vector3(1.2, 0.50, 0.80)
	_box(ledge_c, ledge_s)
	_rope_between(base + Vector3(0, 0.80, -0.40), base + Vector3(0, 0.80, 0.55), 20)
	await _assert_settles("a cord wrapping a ledge", 1800, STILL_MM)
	var into := _deepest_in_box(ledge_c, ledge_s)
	_ok("contact/wrapping a ledge stays out of the solid", into < 0.01,
		"deepest %.1f mm inside" % (into * 1000.0))
	var over := false
	for p: Vector3 in _points():
		if p.z > base.z + 0.32 and p.y < base.y + 0.70:
			over = true
	_ok("contact/the overhang drapes down the face", over)
	await _drop_case()

	# Draped over a horizontal pipe. A round surface is where a plane-cache
	# contact model shows its seams: the contact normal turns under the cord.
	base = _new_case()
	var pipe := base + Vector3(0, 1.00, 0)
	_cylinder(pipe, 0.12, 1.6)
	_rope_between(base + Vector3(0, 1.30, -0.35), base + Vector3(0, 1.30, 0.35), 30)
	await _assert_settles("a cord draped on a pipe", 1800, STILL_MM)
	var into_pipe := _deepest_in_cylinder(pipe, 0.12, 0.8)
	_ok("contact/draping a pipe stays out of it", into_pipe < 0.02,
		"deepest %.1f mm inside" % (into_pipe * 1000.0))
	# "Not inside the pipe" is only half the claim: a cord that ignores collision
	# entirely falls PAST it and reads a clean zero. It also has to be lying ON it.
	var touching := false
	for pt: Vector3 in _points():
		if absf(pt.x - pipe.x) > 0.8 or pt.y < pipe.y:
			continue
		var r := Vector2(pt.y - pipe.y, pt.z - pipe.z).length()
		if absf(r - 0.12) < 0.02:
			touching = true
	_ok("contact/the cord actually rests on the pipe", touching)
	await _drop_case()

	# Over a thin upright post: the cord must end up hanging down BOTH sides
	# rather than sliding off one.
	base = _new_case()
	_cylinder(base + Vector3(0, 0.50, 0), 0.05, 1.0, true)
	_rope_between(base + Vector3(-0.35, 1.15, 0), base + Vector3(0.35, 1.15, 0), 30)
	await _settle(900)
	var left := false
	var right := false
	for p: Vector3 in _points():
		if p.y < base.y + 0.95:
			if p.x < base.x - 0.05:
				left = true
			elif p.x > base.x + 0.05:
				right = true
	_ok("contact/a cord over a post hangs both sides", left and right)
	await _drop_case()

	# Bridging two supports with a gap between them: it should sag into the gap
	# and stop, not sink through to the floor.
	base = _new_case()
	_box(base + Vector3(-0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(base + Vector3(0.45, 0.70, 0), Vector3(0.6, 0.10, 1.0))
	_box(base + Vector3(0, -0.05, 0), Vector3(4.0, 0.10, 4.0))     # the floor
	_rope_between(base + Vector3(-0.5, 0.95, 0), base + Vector3(0.5, 0.95, 0), 30)
	await _settle(900)
	var sag := base.y + 0.75 - _lowest_y()
	_ok("contact/a bridged cord sags without reaching the floor",
		_lowest_y() > base.y + 0.1, "lowest point %.0f mm above the floor"
			% ((_lowest_y() - base.y) * 1000.0))
	_ok("contact/a bridged cord does sag into the gap", sag > 0.01,
		"sagged %.0f mm" % (sag * 1000.0))
	await _drop_case()

	# A long cord heaped on a small table, which is what a spare lead dropped in a
	# corner looks like. It settles and sleeps like the rest, but held awake it
	# keeps churning an order of magnitude more than any single-surface contact —
	# the self-collision pass separating a pile it can never quite finish. Kept as
	# its own case with its own bound so the wrap cases can stay tight.
	base = _new_case()
	_box(base + Vector3(0, 0.50, -0.10), Vector3(1.2, 0.50, 0.80))
	_rope_between(base + Vector3(0, 0.80, -0.40), base + Vector3(0, 0.80, 0.55), 30)
	await _assert_settles("a cord heaped on itself", 2400, HEAP_STILL_MM)
	await _drop_case()

	# Dropped from a height onto a thin plate. This is the motion-sweep path: at
	# 2 m the tail is doing ~6 m/s, which is 70 mm per tick against a 20 mm plate,
	# so a solver that only tested the END of the step would put the cord through
	# the table.
	base = _new_case()
	var plate_c := base + Vector3(0, 0.50, 0)
	var plate_s := Vector3(2.0, 0.02, 2.0)
	_box(plate_c, plate_s)
	_rope_from(base + Vector3(0, 2.60, 0), base + Vector3(0.4, 2.60, 0), 40)
	await _settle(900)
	_ok("contact/a cord dropped from height does not tunnel",
		_lowest_y() > base.y + 0.49, "lowest point %.0f mm" % ((_lowest_y() - base.y) * 1000.0))
	await _drop_case()


# ── integrity ─────────────────────────────────────────────────────────────────
# The cord is a cord: it does not stretch, it does not explode, and it does the
# same thing twice.

func _group_integrity() -> void:
	if not _wants("integrity"):
		return

	# Hanging under its own weight is the everyday load. A rope that stretches
	# here reads as elastic in the room.
	var base := _new_case()
	_rope_from(base + Vector3(0, 2.0, 0), base + Vector3(0.3, 2.0, 0), 40)
	await _settle(600)
	var stretch := _max_stretch()
	var pts := _points()
	var span := 0.0
	for i in range(pts.size() - 1):
		span += pts[i].distance_to(pts[i + 1])
	var elong: float = span / (float(_rope.segment_count) * _rope.segment_length)
	_ok("integrity/hanging under its own weight does not stretch", stretch < 1.25,
		"worst segment %.3f x rest, whole cord %.3f x" % [stretch, elong])
	_ok("integrity/the cord as a whole keeps its length", elong < 1.12,
		"%.3f x rest" % elong)
	await _drop_case()

	# Abuse: anchors 20x further apart than the cord is long, then shaken. The
	# question is only whether the arithmetic survives it.
	base = _new_case()
	var rope := _rope_between(base + Vector3(-18.0, 1.2, 0), base + Vector3(18.0, 1.2, 0))
	var far_end: Node3D = rope.end_node
	for batch in 20:
		await get_tree().physics_frame
		for i in BATCH:
			far_end.position.x += 0.35 if i % 2 == 0 else -0.35
			rope.step(1.0 / 90.0)
	_ok("integrity/over-extended and shaken stays finite", _all_finite())
	await _drop_case()

	# Energy has to leave the system. Compared as movement early vs late, which
	# is the same measure the jitter cases use.
	base = _new_case()
	_rope_between(base + Vector3(-0.3, 1.4, 0), base + Vector3(0.3, 1.4, 0), 30)
	var early := await _max_step(60)
	await _settle(600)
	var late := await _max_step(60)
	_ok("integrity/a swinging cord loses energy", late < early * 0.05,
		"%.2f mm/tick early, %.4f mm/tick late" % [early * 1000.0, late * 1000.0])
	await _drop_case()

	# Two identical ropes, stepped identically, must land on identical points.
	# Anything that leaks uninitialised memory or reads a global clock fails here.
	base = _new_case()
	_rope_between(base + Vector3(-0.3, 1.2, 0), base + Vector3(0.3, 1.2, 0), 20)
	await _settle(300)
	var first := _points()
	var first_base := base
	await _drop_case()
	base = _new_case()
	_rope_between(base + Vector3(-0.3, 1.2, 0), base + Vector3(0.3, 1.2, 0), 20)
	await _settle(300)
	var second := _points()
	var worst := 0.0
	if first.size() == second.size():
		for i in first.size():
			worst = maxf(worst, (first[i] - first_base).distance_to(second[i] - base))
	_ok("integrity/the same cord twice settles the same way",
		first.size() == second.size() and worst < 1e-9,
		"worst difference %.9f m" % worst)
	await _drop_case()


# ── anchors ───────────────────────────────────────────────────────────────────
# What the ends are for.

func _group_anchors() -> void:
	if not _wants("anchors"):
		return

	# A pinned particle IS its anchor, every tick — this is the property the
	# whole cable system leans on to keep a seated plug seated.
	var base := _new_case()
	var rope := _rope_between(base + Vector3(-0.4, 1.2, 0), base + Vector3(0.4, 1.2, 0))
	var a: Node3D = rope.start_node
	var b: Node3D = rope.end_node
	var drift := 0.0
	for batch in 10:
		await get_tree().physics_frame
		for i in BATCH:
			rope.step(1.0 / 90.0)
			var pts := rope.get_points()
			drift = maxf(drift, pts[0].distance_to(a.global_position))
			drift = maxf(drift, pts[rope.segment_count].distance_to(b.global_position))
	_ok("anchors/a pinned end never leaves its anchor", drift < 1e-6,
		"worst drift %.9f m" % drift)
	await _drop_case()

	# An anchor that jumps further than it could have travelled is a teleport,
	# and the cord is re-laid rather than swept — otherwise it catches on every
	# wall between where it was and where it now is.
	base = _new_case()
	_box(base + Vector3(1.5, 1.0, 0), Vector3(0.1, 3.0, 3.0))    # a wall in the way
	rope = _rope_between(base + Vector3(-0.3, 1.2, 0), base + Vector3(0.3, 1.2, 0))
	await _settle(300)
	var moved: Node3D = rope.end_node
	moved.position += Vector3(3.0, 0, 0)                          # straight through it
	await _settle(300)
	var caught := _deepest_in_box(base + Vector3(1.5, 1.0, 0), Vector3(0.1, 3.0, 3.0))
	_ok("anchors/a teleported anchor does not drag the cord through a wall",
		caught < 0.02, "deepest %.1f mm inside the wall" % (caught * 1000.0))
	await _drop_case()

	# set_rope_length is the one setter that rewrites the rest table. Halving it
	# must halve how far the free end can get — a cached rest length once made
	# this silently do nothing.
	base = _new_case()
	rope = _rope_from(base + Vector3(0, 2.0, 0), base + Vector3(0.3, 2.0, 0), 30)
	await _settle(900)
	var top_anchor := base + Vector3(0, 2.0, 0)
	var reach_before: float = _points()[rope.segment_count].distance_to(top_anchor)
	rope.set_rope_length(rope.rest_length() * 0.5)
	await _settle(900)
	var reach_after: float = _points()[rope.segment_count].distance_to(top_anchor)
	var new_rest: float = float(rope.segment_count) * rope.segment_length
	_ok("anchors/a halved rope cannot reach past its new length",
		reach_after < new_rest * 1.05,
		"%.0f mm reach against %.0f mm of cord" % [reach_after * 1000.0, new_rest * 1000.0])
	# The regression this exists for: set_rope_length once wrote the length and
	# nothing else, so the solver kept using the old rest table and the reach did
	# not move at all. A tail that coils rather than hanging taut is why this is
	# "much shorter" rather than "exactly half".
	_ok("anchors/halving the rope really shortens it",
		reach_after < reach_before * 0.6,
		"%.0f mm -> %.0f mm" % [reach_before * 1000.0, reach_after * 1000.0])
	await _drop_case()


# ── sleep ─────────────────────────────────────────────────────────────────────
# A cord that never sleeps costs a Quest frame budget it does not have, and one
# that will not wake is a cable you cannot move.

func _group_sleep() -> void:
	if not _wants("sleep"):
		return

	var base := _new_case()
	_box(base + Vector3(0, 0.70, 0), Vector3(2.0, 0.10, 2.0))
	var rope := _rope_between(base + Vector3(-0.3, 0.95, 0), base + Vector3(0.3, 0.95, 0))
	await _settle(900)
	_ok("sleep/a settled cord sleeps", rope.is_sleeping())

	# Still asleep after being left alone — the anti-jitter claim in the cheap
	# form, and the one that catches a cord that re-wakes itself forever.
	await _settle(300)
	_ok("sleep/a sleeping cord stays asleep", rope.is_sleeping())

	# The smallest move a hand can make must bring it back.
	var a: Node3D = rope.start_node
	a.position += Vector3(0.002, 0, 0)
	await _settle(2)
	_ok("sleep/moving an anchor wakes it", not rope.is_sleeping())

	await _settle(900)
	_ok("sleep/it settles again", rope.is_sleeping())
	rope.nudge_point(int(rope.segment_count / 2), Vector3(0, -0.05, 0))
	await _settle(2)
	_ok("sleep/nudging a point wakes it", not rope.is_sleeping())
	await _drop_case()


# ── budget ────────────────────────────────────────────────────────────────────

func _group_budget() -> void:
	if not _wants("budget"):
		return
	var base := _new_case()
	var ropes: Array[VerletRope] = []
	_holder = Node3D.new()
	add_child(_holder)
	for i in 16:
		var na := Node3D.new()
		na.position = base + Vector3(float(i) * 0.5, 1.2, -0.3)
		_holder.add_child(na)
		var nb := Node3D.new()
		nb.position = base + Vector3(float(i) * 0.5, 1.2, 0.3)
		_holder.add_child(nb)
		var r := VerletRope.new()
		_holder.add_child(r)
		r.segment_count = 24
		r.segment_length = 0.06
		r.start_node = na
		r.end_node = nb
		r.set_process(false)
		r.set_physics_process(false)
		r._init_points()
		ropes.append(r)
	var ticks := 400
	var started := Time.get_ticks_usec()
	var done := 0
	while done < ticks:
		await get_tree().physics_frame
		var n: int = mini(BATCH, ticks - done)
		for i in n:
			for r in ropes:
				r.step(1.0 / 90.0)
		done += n
	var us_per := float(Time.get_ticks_usec() - started) / float(ticks * ropes.size())
	# A ceiling, not a target: this is a debug build on a desktop, and the point
	# is to catch a solver that got several times slower, not to police µs.
	_ok("budget/solver cost per rope-tick", us_per < 400.0, "%.0f us" % us_per)
	await _drop_case()
