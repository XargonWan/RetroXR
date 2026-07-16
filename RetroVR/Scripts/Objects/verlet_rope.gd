## Verlet rope — PBD rope simulation between two 3D anchor points (Obi-Rope-style
## feature set on a position-based verlet core). Attach as a child; set start_node /
## end_node and call _init_points(). Renders as a tube mesh using ArrayMesh.
##
## Constraints (all iteration-count-independent — stiffness is remapped per
## iteration like XPBD, so changing constraint_iterations doesn't change the look):
##   • Stretch  — distance constraints between neighbours, `stretch_stiffness`
##     (1 = inextensible cable, lower = springy/elastic).
##   • Bend     — distance constraints between second neighbours,
##     `bend_stiffness` + `max_bend_degrees` free-bend allowance (0 = the rope
##     always tries to straighten; e.g. 60 = only resists bends sharper than 60°).
##   • Self-collision — optional particle-vs-particle pushout (`self_collision`).
## Other Obi-style features:
##   • Smoothing — Catmull-Rom render subdivision (`smoothing` extra rings per
##     segment) so few sim particles still render as a smooth cable.
##   • Two-way coupling — `anchor_pull` > 0 applies a pulling force to the
##     RigidBody3D ancestors of the anchors when the rope is taut (a yanked
##     controller cable tugs its console).
##   • Runtime resize — `set_rope_length()` redistributes rest length (Obi
##     "cursor"-lite; particle count stays fixed).
class_name VerletRope
extends MeshInstance3D


## Number of rope segments (points = segments + 1)
@export var segment_count: int = 15

## Rest length per segment (metres). Total rope length ≈ segment_count × segment_length.
@export var segment_length: float = 0.06

## Gravity applied to each point per second² (local space, Y-down)
@export var gravity: Vector3 = Vector3(0, -9.8, 0)

## Damping factor applied to velocity each frame (0 = no damping, 1 = no movement)
@export_range(0.0, 1.0) var damping: float = 0.01

## Number of constraint satisfaction iterations per physics frame
@export var constraint_iterations: int = 5

@export_group("Stiffness")
## Resistance to stretching (1 = inextensible cable, lower = elastic/springy).
@export_range(0.0, 1.0) var stretch_stiffness: float = 1.0

## Resistance to bending (0 = perfectly floppy — pre-upgrade behaviour).
@export_range(0.0, 1.0) var bend_stiffness: float = 0.0

## Free bend allowance in degrees before bend stiffness kicks in (0 = the rope
## always tries to be straight; 90 = bends up to 90° per particle are free).
@export_range(0.0, 180.0) var max_bend_degrees: float = 0.0

@export_group("Rendering")
## Tube radius for rendering
@export var tube_radius: float = 0.005

## Number of radial segments for the tube cross-section
@export var tube_sides: int = 4

## Extra Catmull-Rom-interpolated rings per segment (0 = render sim points only).
@export_range(0, 3) var smoothing: int = 0

## Rope color
@export var rope_color: Color = Color(0.15, 0.15, 0.15, 1.0)

@export_group("Collision")
## Collision mask for rope-vs-world collision (1+2 = floor/room/table, 4 = pickables like TVs)
@export_flags_3d_physics var surface_collision_mask: int = 7

## Collision radius around each rope point (slightly larger than tube_radius so the tube doesn't clip)
@export var collision_radius: float = 0.008

## Fraction of sliding velocity removed on surface contact (0 = slick, 1 = sticky)
@export_range(0.0, 1.0) var surface_friction: float = 0.4

## Physics frames between resting-contact shape queries (motion sweeps still run every frame)
@export var raycast_interval: int = 3

## Rope-vs-itself particle collision (lets coils stack instead of passing through).
@export var self_collision: bool = false

@export_group("Coupling")
## Two-way coupling strength (N per metre of overstretch) applied to the anchors'
## RigidBody3D ancestors when the rope is pulled taut. 0 = purely visual (default).
@export var anchor_pull: float = 0.0


# Internal point data
var _points: PackedVector3Array = []       # current positions (global space)
var _prev_points: PackedVector3Array = []  # previous positions for verlet
var _inv_mass: PackedFloat32Array = []     # 0 = pinned (anchored), 1 = free

# Cached per-segment midpoint contact planes (refreshed on the throttled rest
# pass, enforced every frame inside the constraint loop — see _solve_mid_contact).
var _mid_contact: PackedByteArray = []         # 1 = segment has a cached contact
var _mid_contact_point: PackedVector3Array = []
var _mid_contact_normal: PackedVector3Array = []

# Cached per-particle contact manifold: up to TWO planes (bit 1 / bit 2 of
# _c_flags). Refreshed on the throttled rest pass; the second slot carries the
# other face of an edge across refreshes (the physics query only ever reports
# the deepest one, which alternates at a corner). Enforced inside the solver.
var _c_flags: PackedByteArray = []
var _c_p1: PackedVector3Array = []
var _c_n1: PackedVector3Array = []
var _c_p2: PackedVector3Array = []
var _c_n2: PackedVector3Array = []

# Anchors
var start_node: Node3D = null
var end_node: Node3D = null

var _material: StandardMaterial3D

# Pre-cached trig tables (rebuilt when tube_sides changes)
var _cos_table: PackedFloat32Array
var _sin_table: PackedFloat32Array

# Pre-allocated render buffers (ring centres incl. smoothing + vertices)
var _ring_points: PackedVector3Array
var _vertex_array: PackedVector3Array
var _index_array: PackedInt32Array

# Raycast throttle counter
var _raycast_frame: int = 0

# Sleep state — an idle cable was one of the biggest CPU items on Quest (the
# solver, raycasts, rest-info queries and tube re-mesh all run per tick even
# when nothing moves). Once every particle has been near-still for
# SLEEP_FRAMES ticks the rope sleeps: the whole sim and the re-mesh are
# skipped until an anchor moves. Caveat: geometry sliding out from UNDER a
# sleeping rope won't wake it (anchors drive every real interaction here).
const SLEEP_FRAMES := 30
const SLEEP_POINT_EPS_SQ := 0.0015 * 0.0015   # per-tick particle movement²
const WAKE_ANCHOR_EPS_SQ := 0.0005 * 0.0005   # anchor movement² that wakes
var _asleep: bool = false
var _still_frames: int = 0
var _sleep_anchor_start: Vector3 = Vector3.ZERO
var _sleep_anchor_end: Vector3 = Vector3.ZERO
# Set by every simulated tick; cleared by _process after re-meshing, so a
# sleeping rope stops uploading vertices too.
var _mesh_dirty: bool = true

# Reusable collision queries (avoids per-point allocation)
var _ray_query: PhysicsRayQueryParameters3D
var _shape_query: PhysicsShapeQueryParameters3D
var _sphere: SphereShape3D

# Anchor RigidBody3D ancestors for two-way coupling (cached with exclusions)
var _start_body: RigidBody3D = null
var _end_body: RigidBody3D = null


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = rope_color
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	top_level = true
	global_transform = Transform3D.IDENTITY

	_build_trig_tables()
	_build_mesh_topology()
	_init_points()

	if surface_collision_mask != 0:
		_ray_query = PhysicsRayQueryParameters3D.new()
		_ray_query.collision_mask = surface_collision_mask
		_ray_query.hit_back_faces = false
		_sphere = SphereShape3D.new()
		# Query slightly beyond the contact distance so a particle RESTING at
		# exactly collision_radius keeps reporting (else its cached plane drops
		# every refresh, it re-falls, and the contact cycles).
		_sphere.radius = collision_radius * 1.3
		_shape_query = PhysicsShapeQueryParameters3D.new()
		_shape_query.shape = _sphere
		_shape_query.collision_mask = surface_collision_mask
		_refresh_exclusions()


## Rings actually rendered per segment (1 = sim points only).
func _subdiv() -> int:
	return smoothing + 1


func _build_trig_tables() -> void:
	_cos_table.resize(tube_sides)
	_sin_table.resize(tube_sides)
	for j in tube_sides:
		var angle := TAU * float(j) / float(tube_sides)
		_cos_table[j] = cos(angle)
		_sin_table[j] = sin(angle)


func _build_mesh_topology() -> void:
	var sub := _subdiv()
	var ring_count := segment_count * sub + 1
	var seg_rings := ring_count - 1
	_ring_points = PackedVector3Array()
	_ring_points.resize(ring_count)
	_vertex_array = PackedVector3Array()
	_vertex_array.resize(ring_count * tube_sides)

	# Index buffer — topology never changes, built once
	_index_array = PackedInt32Array()
	_index_array.resize(seg_rings * tube_sides * 6)
	var idx := 0
	for i in seg_rings:
		for j in tube_sides:
			var a := i * tube_sides + j
			var b := i * tube_sides + (j + 1) % tube_sides
			var c := (i + 1) * tube_sides + j
			var d := (i + 1) * tube_sides + (j + 1) % tube_sides
			_index_array[idx]     = a; _index_array[idx + 1] = b; _index_array[idx + 2] = c
			_index_array[idx + 3] = b; _index_array[idx + 4] = d; _index_array[idx + 5] = c
			idx += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertex_array
	arrays[Mesh.ARRAY_INDEX]  = _index_array

	mesh = ArrayMesh.new()
	(mesh as ArrayMesh).add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	(mesh as ArrayMesh).surface_set_material(0, _material)


func _init_points() -> void:
	var count := segment_count + 1
	_points.resize(count)
	_prev_points.resize(count)
	_inv_mass.resize(count)
	_mid_contact.resize(segment_count)
	_mid_contact_point.resize(segment_count)
	_mid_contact_normal.resize(segment_count)
	for i in segment_count:
		_mid_contact[i] = 0
	_c_flags.resize(count)
	_c_p1.resize(count)
	_c_n1.resize(count)
	_c_p2.resize(count)
	_c_n2.resize(count)
	for i in count:
		_c_flags[i] = 0

	var start_pos := start_node.global_position if start_node else global_position
	var end_pos   := end_node.global_position   if end_node   else start_pos + Vector3(0, -segment_count * segment_length, 0)

	for i in count:
		var t := float(i) / float(count - 1) if count > 1 else 0.0
		_points[i]      = start_pos.lerp(end_pos, t)
		_prev_points[i] = _points[i]
		_inv_mass[i] = 1.0
	_inv_mass[0] = 0.0
	if end_node:
		_inv_mass[count - 1] = 0.0

	wake()
	_sleep_anchor_start = _anchor_pos(start_node, start_pos)
	_sleep_anchor_end = _anchor_pos(end_node, end_pos)
	_refresh_exclusions()


## Exclude the plug body and the host machine's body from rope collision —
## the anchor points sit at/inside those colliders and would jitter forever.
## Also caches the anchors' RigidBody3D ancestors for two-way coupling.
func _refresh_exclusions() -> void:
	var rids: Array[RID] = []
	_start_body = null
	_end_body = null
	var anchors: Array[Node3D] = [start_node, end_node]
	for a_idx in anchors.size():
		var n: Node = anchors[a_idx]
		while n != null:
			if n is CollisionObject3D:
				rids.append((n as CollisionObject3D).get_rid())
				if n is RigidBody3D:
					if a_idx == 0: _start_body = n as RigidBody3D
					else:          _end_body = n as RigidBody3D
				break
			n = n.get_parent()
	if _ray_query:
		_ray_query.exclude = rids
	if _shape_query:
		_shape_query.exclude = rids


# ── Public Obi-style API ────────────────────────────────────────────────────────

## Total rest length of the rope (metres).
func rest_length() -> float:
	return segment_count * segment_length


## Resize the rope at runtime by redistributing rest length across the fixed
## particle count (Obi "cursor"-lite).
func set_rope_length(length: float) -> void:
	segment_length = maxf(length, 0.01) / float(segment_count)
	wake()


## Force the rope back into active simulation.
func wake() -> void:
	_asleep = false
	_still_frames = 0


func _anchor_pos(node: Node3D, fallback: Vector3) -> Vector3:
	return node.global_position if node else fallback


## True when either anchor has moved since the rope went to sleep.
func _anchors_moved() -> bool:
	if _anchor_pos(start_node, _sleep_anchor_start) \
			.distance_squared_to(_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ:
		return true
	return _anchor_pos(end_node, _sleep_anchor_end) \
			.distance_squared_to(_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ


# ── Simulation ──────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _points.size() == 0:
		return

	if _asleep:
		if _anchors_moved():
			wake()
		else:
			return
	_mesh_dirty = true

	var count := _points.size()

	# --- Verlet integration ---
	for i in count:
		if _inv_mass[i] == 0.0:
			continue
		var current := _points[i]
		var velocity := (current - _prev_points[i]) * (1.0 - damping)
		_prev_points[i] = current
		_points[i] = current + velocity + gravity * (delta * delta)

	_pin_anchors()

	# Per-iteration stiffness so the look is independent of the iteration count
	# (same remapping XPBD-style solvers use: k' = 1-(1-k)^(1/n)).
	var iters := maxi(constraint_iterations, 1)
	# Stretch stiffness is remapped so the rope's extensibility is independent of
	# the iteration count (k' = 1-(1-k)^(1/n); 1.0 stays fully rigid).
	var k_stretch := 1.0 - pow(1.0 - clampf(stretch_stiffness, 0.0, 1.0), 1.0 / float(iters))
	# Bend stiffness is applied directly per iteration — remapping it the same
	# way crushes mid-range values into "floppy" at typical iteration counts.
	# (Consequence: more iterations = a somewhat stiffer-feeling rope.)
	var k_bend := clampf(bend_stiffness, 0.0, 1.0)
	# Bend: each interior particle is pulled toward the midpoint of its
	# neighbours (angular PBD bending — unlike a second-neighbour distance
	# constraint, its gradient does NOT vanish near-straight, so stiff ropes
	# actually resist gravity sag). A bend of angle β deviates the particle
	# L·sin(β/2) from the midpoint; bends up to max_bend_degrees are free.
	var allowed_dev := segment_length * sin(deg_to_rad(max_bend_degrees) * 0.5)

	# --- Constraint solve ---
	for iter_i in iters:
		# Stretch (distance) constraints
		for i in range(count - 1):
			_solve_pair(i, i + 1, segment_length, k_stretch, false)
		# Bend constraints, hierarchical: besides adjacent triples (spacing 1),
		# also constrain toward midpoints at spacing 2/4/8… — plain PBD bending
		# saturates with chain length (corrections propagate one particle per
		# pass while gravity acts on all of them), so long ropes stay droopy no
		# matter the stiffness; the long-range constraints fix that in O(log n)
		# passes. The hierarchy depth scales with stiffness: soft cables
		# (k ≲ 0.2) bend locally only — long-range constraints would leverage
		# surface contacts and prop the rope up rod-like — while stiff ropes
		# engage the full hierarchy. Sweep direction alternates per iteration.
		# The free-bend allowance grows ~s² with spacing (sagitta of an arc).
		if k_bend > 0.0:
			var levels := 1 + roundi(k_bend * 3.0)
			var s := 1
			while s * 2 <= count - 1 and levels > 0:
				var allowed := allowed_dev * float(s * s)
				if iter_i % 2 == 0:
					for i in range(s, count - s):
						_solve_bend(i, s, allowed, k_bend)
				else:
					for i in range(count - s - 1, s - 1, -1):
						_solve_bend(i, s, allowed, k_bend)
				s *= 2
				levels -= 1
		# Cached contact planes (refreshed on the throttled rest pass below) —
		# solved together with the other constraints so contacts, including
		# edge wraps, are part of the equilibrium instead of oscillating.
		for i in range(count - 1):
			if _mid_contact[i] != 0:
				_solve_mid_contact(i)
		for i in count:
			if _inv_mass[i] == 0.0 or _c_flags[i] == 0:
				continue
			if (_c_flags[i] & 1) != 0:
				_project_plane(i, _c_p1[i], _c_n1[i])
			if (_c_flags[i] & 2) != 0:
				_project_plane(i, _c_p2[i], _c_n2[i])
		_pin_anchors()

	# Friction for cached resting contacts (once per frame, not per iteration):
	# damp the tangential velocity of every particle a contact plane is holding,
	# mirroring what _resolve_contact does for sweep hits.
	for i in count:
		if _inv_mass[i] == 0.0 or _c_flags[i] == 0:
			continue
		for slot in 2:
			if (_c_flags[i] & (1 << slot)) == 0:
				continue
			var n := _c_n1[i] if slot == 0 else _c_n2[i]
			var cp := _c_p1[i] if slot == 0 else _c_p2[i]
			if (_points[i] - cp).dot(n) > collision_radius * 1.05:
				continue
			var vel := _points[i] - _prev_points[i]
			var tangential := vel - n * vel.dot(n)
			_prev_points[i] = _points[i] - tangential * (1.0 - surface_friction)

	# --- Self collision ---
	if self_collision:
		var min_d := collision_radius * 2.0
		for i in range(count):
			for j in range(i + 2, count):
				var w_sum := _inv_mass[i] + _inv_mass[j]
				if w_sum == 0.0:
					continue
				var diff := _points[j] - _points[i]
				var dist := diff.length()
				if dist >= min_d or dist < 0.0001:
					continue
				var push := diff * ((dist - min_d) / dist)
				_points[i] += push * (_inv_mass[i] / w_sum)
				_points[j] -= push * (_inv_mass[j] / w_sum)

	# --- Surface collision ---
	if surface_collision_mask != 0 and _ray_query:
		_raycast_frame += 1
		var do_rest := _raycast_frame >= raycast_interval
		if do_rest:
			_raycast_frame = 0
		var space_state := get_world_3d().direct_space_state
		for i in range(count):
			if _inv_mass[i] == 0.0:
				continue
			# Sweep this frame's motion so a point can't tunnel through thin
			# geometry, even between rest-query frames.
			var from := _prev_points[i]
			var to := _points[i]
			var motion := to - from
			if motion.length_squared() > 0.000001:
				_ray_query.from = from
				_ray_query.to = to + motion.normalized() * collision_radius
				var hit := space_state.intersect_ray(_ray_query)
				if hit:
					var hit_normal: Vector3 = hit["normal"]
					if hit_normal != Vector3.ZERO:
						var hit_point: Vector3 = hit["position"]
						_resolve_contact(i, hit_point, hit_normal)
						continue
			# Resting contact (throttled — heavier query): refresh the particle's
			# cached contact-plane manifold. The planes are enforced every frame
			# INSIDE the constraint loop, so contacts are part of the solver's
			# equilibrium — snapping the particle here instead fights the other
			# constraints and jitters edge wraps. The query only reports the
			# deepest plane (which alternates at a corner), so a still-valid
			# previous plane with a different normal is kept as a second slot.
			if do_rest:
				_shape_query.transform = Transform3D(Basis.IDENTITY, _points[i])
				var rest := space_state.get_rest_info(_shape_query)
				var keep1 := (_c_flags[i] & 1) != 0 and _plane_valid(i, _c_p1[i], _c_n1[i])
				var keep2 := (_c_flags[i] & 2) != 0 and _plane_valid(i, _c_p2[i], _c_n2[i])
				if not rest.is_empty() and rest["normal"] != Vector3.ZERO:
					var np: Vector3 = rest["point"]
					var nn: Vector3 = rest["normal"]
					if keep1 and nn.dot(_c_n1[i]) > 0.9:
						_c_p1[i] = np; _c_n1[i] = nn
					elif keep2 and nn.dot(_c_n2[i]) > 0.9:
						_c_p2[i] = np; _c_n2[i] = nn
					elif not keep1:
						_c_p1[i] = np; _c_n1[i] = nn; keep1 = true
					else:
						_c_p2[i] = np; _c_n2[i] = nn; keep2 = true
				_c_flags[i] = (1 if keep1 else 0) | (2 if keep2 else 0)

		# Segment-midpoint contact CACHE refresh (same throttled pass): particle
		# collision alone lets the straight span BETWEEN two particles cut
		# through a convex corner (each endpoint rests on its own face while
		# the chord clips the edge). We only query here — the cached plane is
		# enforced every frame inside the constraint loop (_solve_mid_contact),
		# so the corner contact is part of the solver's equilibrium. Applying a
		# push directly from this throttled pass instead fights the other
		# constraints and makes an edge-wrapped rope visibly oscillate.
		if do_rest:
			for i in range(count - 1):
				_mid_contact[i] = 0
				if _inv_mass[i] + _inv_mass[i + 1] == 0.0:
					continue
				var mid := (_points[i] + _points[i + 1]) * 0.5
				_shape_query.transform = Transform3D(Basis.IDENTITY, mid)
				var rest := space_state.get_rest_info(_shape_query)
				if rest.is_empty():
					continue
				var n: Vector3 = rest["normal"]
				if n == Vector3.ZERO:
					continue
				_mid_contact[i] = 1
				_mid_contact_point[i] = rest["point"]
				_mid_contact_normal[i] = n

	# --- Two-way anchor coupling ---
	if anchor_pull > 0.0 and start_node and end_node:
		var span := start_node.global_position.distance_to(end_node.global_position)
		var excess := span - rest_length()
		if excess > 0.0:
			var force := excess * anchor_pull
			if _start_body:
				var dir_s := (end_node.global_position - start_node.global_position).normalized()
				_start_body.apply_force(dir_s * force,
					start_node.global_position - _start_body.global_position)
			if _end_body:
				var dir_e := (start_node.global_position - end_node.global_position).normalized()
				_end_body.apply_force(dir_e * force,
					end_node.global_position - _end_body.global_position)

	# --- Sleep detection ---
	# Still = every particle moved less than SLEEP_POINT_EPS_SQ this tick AND
	# the anchors sit where we last saw them.
	var still := true
	for i in count:
		if _points[i].distance_squared_to(_prev_points[i]) > SLEEP_POINT_EPS_SQ:
			still = false
			break
	var a_start := _anchor_pos(start_node, _sleep_anchor_start)
	var a_end := _anchor_pos(end_node, _sleep_anchor_end)
	if a_start.distance_squared_to(_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ \
			or a_end.distance_squared_to(_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ:
		still = false
	_sleep_anchor_start = a_start
	_sleep_anchor_end = a_end
	if still:
		_still_frames += 1
		if _still_frames >= SLEEP_FRAMES:
			_asleep = true
			# Zero implied velocities so waking doesn't inherit stale motion.
			for i in count:
				_prev_points[i] = _points[i]
	else:
		_still_frames = 0


## Positional constraint between points a/b toward rest distance, split by
## inverse mass. one_sided = only correct when closer than rest.
func _solve_pair(a: int, b: int, rest: float, k: float, one_sided: bool) -> void:
	var w_a := _inv_mass[a]
	var w_b := _inv_mass[b]
	var w_sum := w_a + w_b
	if w_sum == 0.0:
		return
	var diff := _points[b] - _points[a]
	var dist := diff.length()
	if dist < 0.0001:
		return
	if one_sided and dist >= rest:
		return
	var correction := diff * ((dist - rest) / dist) * k
	_points[a] += correction * (w_a / w_sum)
	_points[b] -= correction * (w_b / w_sum)


## Angular bend constraint: pull particle b toward the midpoint of its
## neighbours at ±spacing (momentum-balanced: neighbours get half the opposite
## correction), ignoring deviation below allowed_dev (max_bend_degrees).
func _solve_bend(b: int, spacing: int, allowed_dev: float, k: float) -> void:
	var a := b - spacing
	var c := b + spacing
	var w_a := _inv_mass[a]
	var w_b := _inv_mass[b]
	var w_c := _inv_mass[c]
	var w_total := w_b + 0.5 * (w_a + w_c)
	if w_total == 0.0:
		return
	var delta := (_points[a] + _points[c]) * 0.5 - _points[b]
	var dev := delta.length()
	if dev <= allowed_dev or dev < 0.0001:
		return
	var v := delta * ((dev - allowed_dev) / dev) * k
	_points[b] += v * (w_b / w_total)
	_points[a] -= v * (0.5 * w_a / w_total)
	_points[c] -= v * (0.5 * w_c / w_total)


## Keep segment i's midpoint outside its cached contact plane, splitting the
## correction so the midpoint clears fully (Δa+Δb = 2·push). The distance cap
## guards against stale planes (they're only refreshed every raycast_interval
## frames and extend infinitely).
func _solve_mid_contact(i: int) -> void:
	var w_a := _inv_mass[i]
	var w_b := _inv_mass[i + 1]
	var w_sum := w_a + w_b
	if w_sum == 0.0:
		return
	var mid := (_points[i] + _points[i + 1]) * 0.5
	if mid.distance_squared_to(_mid_contact_point[i]) > segment_length * segment_length * 4.0:
		return
	var n := _mid_contact_normal[i]
	var d := (mid - _mid_contact_point[i]).dot(n)
	if d >= collision_radius:
		return
	var push := n * (collision_radius - d)
	_points[i] += push * (2.0 * w_a / w_sum)
	_points[i + 1] += push * (2.0 * w_b / w_sum)


## Whether a cached contact plane is still plausible for particle i: the
## particle hasn't slid far from the contact and still sits near the plane.
func _plane_valid(i: int, cp: Vector3, n: Vector3) -> bool:
	var p := _points[i]
	if p.distance_squared_to(cp) > segment_length * segment_length * 4.0:
		return false
	return absf((p - cp).dot(n)) < collision_radius * 3.0


## Positional projection: keep particle i at least collision_radius outside
## the cached plane (runs every solver iteration).
func _project_plane(i: int, cp: Vector3, n: Vector3) -> void:
	var d := (_points[i] - cp).dot(n)
	if d < collision_radius:
		_points[i] += n * (collision_radius - d)


func _pin_anchors() -> void:
	if start_node:
		_points[0] = start_node.global_position
		_prev_points[0] = _points[0]
	if end_node:
		var last := _points.size() - 1
		_points[last] = end_node.global_position
		_prev_points[last] = _points[last]


## Snap point i to just outside a surface and convert its velocity into a
## friction-damped slide along the surface (no bounce).
func _resolve_contact(i: int, contact: Vector3, normal: Vector3) -> void:
	var vel := _points[i] - _prev_points[i]
	var tangential := vel - normal * vel.dot(normal)
	_points[i] = contact + normal * collision_radius
	_prev_points[i] = _points[i] - tangential * (1.0 - surface_friction)


# ── Rendering ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _points.size() >= 2 and _mesh_dirty:
		_render_tube()
		_mesh_dirty = false


## Fill _ring_points from the sim points — straight copy, or Catmull-Rom
## subdivision when smoothing > 0.
func _fill_ring_points() -> void:
	var count := _points.size()
	var sub := _subdiv()
	if sub == 1:
		for i in count:
			_ring_points[i] = _points[i]
		return
	var r := 0
	for i in range(count - 1):
		var p0 := _points[maxi(i - 1, 0)]
		var p1 := _points[i]
		var p2 := _points[i + 1]
		var p3 := _points[mini(i + 2, count - 1)]
		for s in sub:
			var t := float(s) / float(sub)
			var t2 := t * t
			var t3 := t2 * t
			_ring_points[r] = 0.5 * ((2.0 * p1)
				+ (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
			r += 1
	_ring_points[r] = _points[count - 1]


func _render_tube() -> void:
	_fill_ring_points()
	var count := _ring_points.size()

	# Pre-compute one ring frame per ring (avoids recomputing per vertex)
	var sides:  Array[Vector3] = []
	var ups:    Array[Vector3] = []
	sides.resize(count)
	ups.resize(count)

	# Parallel-transport (rotation-minimizing) frames: build the first ring's
	# basis from any perpendicular, then carry it along the tube by projecting
	# the previous side vector onto each new tangent plane. Computing frames
	# independently from a fixed reference vector twists neighbouring rings
	# against each other whenever the tangent nears that reference (e.g. a
	# vertically hanging cable), which pinches the tube like sausage links.
	var prev_side := Vector3.ZERO
	for i in count:
		var tangent: Vector3
		if i == 0:
			tangent = _ring_points[1] - _ring_points[0]
		elif i == count - 1:
			tangent = _ring_points[i] - _ring_points[i - 1]
		else:
			tangent = _ring_points[i + 1] - _ring_points[i - 1]
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.UP
		else:
			tangent = tangent.normalized()
		var side := prev_side - tangent * prev_side.dot(tangent)
		if side.length_squared() < 0.000001:
			var ref := Vector3.UP if absf(tangent.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
			side = tangent.cross(ref)
		side = side.normalized()
		prev_side = side
		sides[i] = side
		ups[i]   = side.cross(tangent).normalized()

	# Fill vertex buffer
	for i in count:
		var base := i * tube_sides
		var side := sides[i]
		var up   := ups[i]
		for j in tube_sides:
			_vertex_array[base + j] = _ring_points[i] + (side * _cos_table[j] + up * _sin_table[j]) * tube_radius

	# Single bulk upload to GPU
	(mesh as ArrayMesh).surface_update_vertex_region(0, 0, _vertex_array.to_byte_array())

	# Keep culling bounds in sync — surface_update_vertex_region() does NOT
	# recompute the mesh AABB (it stays a zero-size box at the origin), and this
	# node is top_level at the world origin, so without this the rope gets
	# frustum-culled (goes invisible) whenever the origin is off-screen.
	var aabb := AABB(_points[0], Vector3.ZERO)
	for i in range(1, _points.size()):
		aabb = aabb.expand(_points[i])
	custom_aabb = aabb.grow(collision_radius * 2.0)
