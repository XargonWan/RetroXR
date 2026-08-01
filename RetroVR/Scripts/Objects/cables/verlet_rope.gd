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

## Number of radial segments for the tube cross-section.
##
## Lighting here is FLAT per facet — cable.gdshader derives its normal from
## screen-space derivatives, because the tube has no normal array to interpolate
## and adding one would cost the per-frame surface_update_vertex_region fast path.
## Flat shading makes every facet a constant-shaded band, so a low count reads as
## a visibly pixellated prism rather than a cord. Sides are cheap (verts only, no
## extra draw call), so spend them here.
@export var tube_sides: int = 8

## Extra Catmull-Rom-interpolated rings per segment (0 = render sim points only).
@export_range(0, 3) var smoothing: int = 0

## Rope color
@export var rope_color: Color = Color(0.15, 0.15, 0.15, 1.0):
	set(v):
		rope_color = v
		if _material != null:
			_material.set_shader_parameter("cable_color", v)

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

@export_group("End alignment")
## Plug-end orientation stiffness. 0 = the plug spins freely (old behaviour); 1 =
## the plug snaps to the rope direction each frame. When > 0, a free plug
## RigidBody3D anchoring either rope end is rotated so its cable-exit axis follows
## the rope's tangent there — the plug stops rotating freely and the cable emerges
## straight out of it (a strain-relief look). Only rigidbody-anchored ends that
## aren't currently held or plugged in are affected; a plain Node3D anchor (a host
## attach point) is left alone.
@export_range(0.0, 1.0) var end_align_stiffness: float = 0.0

## The plug's LOCAL axis that the cable exits along (points back up the rope).
## Default -Z matches the cable plug meshes (strain relief on the -Z back).
@export var plug_exit_axis: Vector3 = Vector3(0, 0, -1)

## WHERE on each anchor the cable leaves it, in that anchor's LOCAL space — the
## companion to plug_exit_axis, which only gives the direction. Zero (the
## default) ends the rope at the anchor's origin, which is right for the generic
## cylinder plug whose origin sits mid-barrel. A bespoke connector model whose
## origin is its SEATING reference needs its own cable boss here, or the rope
## terminates inside the shell and the tube visibly runs through the mesh.
@export var start_anchor_offset: Vector3 = Vector3.ZERO
@export var end_anchor_offset: Vector3 = Vector3.ZERO

## Rigid strain-relief stub: how straight the first/last `end_stiff_segments`
## segments are held so the cable emerges STIFF from each plug before it bends to
## join the floppy middle. 0 = off, 1 = the stub is perfectly straight.
@export_range(0.0, 1.0) var end_stiffness: float = 0.0

## Number of segments at each end kept straight by `end_stiffness` (the length of
## the rigid stub, in segments).
@export_range(0, 8) var end_stiff_segments: int = 3


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

# Consecutive rest passes a particle has been detected on the wrong side of a
# slab (see the wrong-side recovery block) — recovery fires at 2.
var _stuck_passes: PackedByteArray = []

# Indices carrying a cached contact plane this tick, gathered once per tick and
# walked on every solver iteration (see the constraint solve).
var _active_mid: PackedInt32Array = []
var _active_contact: PackedInt32Array = []

# Anchors
var start_node: Node3D = null
var end_node: Node3D = null

var _material: ShaderMaterial

# Pre-cached trig tables (rebuilt when tube_sides changes)
var _cos_table: PackedFloat32Array
var _sin_table: PackedFloat32Array

# Pre-allocated render buffers (ring centres incl. smoothing + vertices)
var _ring_points: PackedVector3Array
var _vertex_array: PackedVector3Array
var _index_array: PackedInt32Array
## Render-time copies of the last two physics states, and the lerp between them.
##
## The whole rope has to be interpolated, not just its ends. Overriding only the
## two end points put them on render time while every interior point stayed on
## physics time, and that discontinuity pulsed the final segment every frame —
## which read as the cord jittering, and pinched the tube whenever the last two
## rings closed up enough for the tangent to collapse into its fallback.
##
## Lerping all points by Engine.get_physics_interpolation_fraction() is exactly
## what Godot does for the RigidBody3D plug, so the cord end and the plug agree
## by construction. Costs one lerp per SIM point (~25), not per vertex.
var _render_points: PackedVector3Array = []
var _prev_render: PackedVector3Array = []
var _curr_render: PackedVector3Array = []
## False when the last two physics states match — a settled rope then re-meshes
## only when something actually marks it dirty.
var _interpolating: bool = false

## Per-vertex normal, shipped as a CUSTOM0 attribute.
##
## The tube cannot use ARRAY_NORMAL: positions are re-uploaded every frame through
## surface_update_vertex_region, and normals share that same vertex buffer, so
## adding them means rebuilding the whole surface each frame — a GPU buffer
## reallocation per rope per frame, which is exactly what this design avoids.
## Custom attributes live in the ATTRIBUTE buffer instead, which has its own
## region-update call, so the normal rides along for one extra bulk upload.
##
## RGBA_FLOAT rather than RGB_FLOAT: 16-byte alignment, w unused.
var _normal_array: PackedFloat32Array

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

## Second, slower way to be finished: the rope is oscillating rather than
## stopping, and getting nowhere.
##
## A segment resting near the reach of the rest-info sphere drops in and out of
## detection between throttled passes, so its cached contact plane vanishes, the
## segment falls for an interval, is re-detected, and is pushed back. That is a
## stable cycle — measured at period 6 with a 10 mm snap, locked to
## raycast_interval — and per-tick motion inside it never drops under
## SLEEP_POINT_EPS_SQ, so the test above can never fire and the cable simulates
## for ever while visibly jittering.
##
## The cycle's signature is that it goes nowhere: over a window, no particle ever
## gets far from where it started. So track the furthest any particle strays from
## a reference pose and sleep when the whole window fits inside a small envelope.
## A rope genuinely still settling leaves it in a few ticks — even 1 mm a tick is
## 90 mm over the window — so this only catches motion that is not progressing.
const SLEEP_REF_FRAMES := 90
const SLEEP_EXCURSION_EPS_SQ := 0.012 * 0.012

const CABLE_SHADER := preload("res://Shaders/cable.gdshader")

const WAKE_ANCHOR_EPS_SQ := 0.0005 * 0.0005   # anchor movement² that wakes
## Render-time anchor movement² that forces a re-mesh between physics ticks.
## Tighter than the wake threshold: this only costs a tube rebuild, whereas
## waking costs a full solve, so it can afford to notice smaller motion.
const RENDER_FOLLOW_EPS_SQ := 0.0001 * 0.0001
var _asleep: bool = false
var _still_frames: int = 0
## Reference pose for the excursion window, and the furthest any particle has
## strayed from it since the window opened.
var _sleep_ref: PackedVector3Array = []
var _ref_frames: int = 0
var _max_excursion_sq: float = 0.0
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
	# Lit PVC jacket. Was SHADING_MODE_UNSHADED, which is why a cable read as a
	# flat silhouette — it took no light at all. cable.gdshader derives its normal
	# from screen-space derivatives because this mesh has no normal array, and
	# adding one would cost the per-frame surface_update_vertex_region fast path.
	_material = ShaderMaterial.new()
	_material.shader = CABLE_SHADER
	_material.set_shader_parameter("cable_color", rope_color)
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
	_normal_array = PackedFloat32Array()
	_normal_array.resize(ring_count * tube_sides * 4)

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
	# PackedFloat32Array, NOT bytes: the *_FLOAT custom formats are validated as
	# PACKED_FLOAT32_ARRAY here and the surface silently fails to build otherwise.
	# (surface_update_attribute_region below does want bytes.)
	arrays[Mesh.ARRAY_CUSTOM0] = _normal_array

	mesh = ArrayMesh.new()
	var fmt: int = Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
	(mesh as ArrayMesh).add_surface_from_arrays(
		Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, fmt)
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
	_stuck_passes.resize(count)
	for i in count:
		_c_flags[i] = 0
		_stuck_passes[i] = 0

	var start_pos := _anchor_point(start_node, start_anchor_offset, global_position)
	var end_pos   := _anchor_point(end_node, end_anchor_offset,
		start_pos + Vector3(0, -segment_count * segment_length, 0))

	for i in count:
		var t := float(i) / float(count - 1) if count > 1 else 0.0
		_points[i]      = start_pos.lerp(end_pos, t)
		_prev_points[i] = _points[i]
		_inv_mass[i] = 1.0
	_inv_mass[0] = 0.0
	if end_node:
		_inv_mass[count - 1] = 0.0

	wake()
	_sleep_anchor_start = _anchor_point(start_node, start_anchor_offset, start_pos)
	_sleep_anchor_end = _anchor_point(end_node, end_anchor_offset, end_pos)
	_refresh_exclusions()
	# Resize-and-seed: _snapshot_render_state detects the length change and fills
	# both history buffers from the fresh points.
	_curr_render.resize(0)
	_snapshot_render_state()


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


## Simulated particle positions, in GLOBAL space. For renderers that want the
## curve without the tube — BeadPullCord threads beads along it.
func get_points() -> PackedVector3Array:
	return _points


## Shove a particle, waking the rope. Used to yank a pull cord: the tail is
## displaced and the solver takes it from there, so the swing afterwards is the
## simulation's, not an animation.
func nudge_point(index: int, delta: Vector3) -> void:
	if index < 0 or index >= _points.size() or _inv_mass[index] == 0.0:
		return
	_points[index] += delta
	wake()


## Resize the rope at runtime by redistributing rest length across the fixed
## particle count (Obi "cursor"-lite).
func set_rope_length(length: float) -> void:
	segment_length = maxf(length, 0.01) / float(segment_count)
	wake()


## Force the rope back into active simulation.
func wake() -> void:
	_asleep = false
	_still_frames = 0
	_open_excursion_window()


## Restart the excursion window from the current pose. Writes into the existing
## buffer rather than duplicating: wake() reopens the window, and a pull cord
## being yanked calls that every tick.
func _open_excursion_window() -> void:
	var n := _points.size()
	if _sleep_ref.size() != n:
		_sleep_ref.resize(n)
	for i in n:
		_sleep_ref[i] = _points[i]
	_ref_frames = 0
	_max_excursion_sq = 0.0


## Park the rope. Implied velocities are zeroed so waking doesn't inherit stale
## motion — and so a rope stopped mid-oscillation doesn't resume it.
func _sleep_now(count: int) -> void:
	_asleep = true
	for i in count:
		_prev_points[i] = _points[i]


## World point where the cable meets an anchor: its origin shifted by that
## anchor's local exit offset (see start_anchor_offset / end_anchor_offset).
func _anchor_point(node: Node3D, offset: Vector3, fallback: Vector3) -> Vector3:
	return (node.global_transform * offset) if node else fallback



## True when either anchor has moved since the rope went to sleep.
func _anchors_moved() -> bool:
	if _anchor_point(start_node, start_anchor_offset, _sleep_anchor_start) \
			.distance_squared_to(_sleep_anchor_start) > WAKE_ANCHOR_EPS_SQ:
		return true
	return _anchor_point(end_node, end_anchor_offset, _sleep_anchor_end) \
			.distance_squared_to(_sleep_anchor_end) > WAKE_ANCHOR_EPS_SQ


# ── Simulation ──────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _points.size() == 0:
		return

	if _asleep:
		if _anchors_moved():
			wake()
		else:
			# Nothing moved, so there is nothing to interpolate between; leaving
			# this true would re-mesh a settled cable every frame forever.
			_interpolating = false
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

	# End orientation authority: a plug whose orientation is externally fixed (held
	# in a hand or socketed into a port) drives the ROPE — the cable leaves it
	# stiffly along the plug's exit axis (out of the socket). A free plug is the
	# other way round: it follows the rope (see _align_anchor_plug after the solve).
	# The two are exact complements, so a socketed cable is stiff in the direction
	# it plugs in, and a dangling one hangs naturally.
	var start_fixed := _plug_is_fixed(start_node)
	var end_fixed := _plug_is_fixed(end_node)
	var start_exit := _plug_exit_dir(start_node) if start_fixed else Vector3.ZERO
	var end_exit := _plug_exit_dir(end_node) if end_fixed else Vector3.ZERO

	# Contact flags are only rewritten by the throttled rest pass further down,
	# never inside the solve, so the active planes are gathered once here rather
	# than re-tested on all eight iterations.
	_active_mid.clear()
	for i in range(count - 1):
		if _mid_contact[i] != 0:
			_active_mid.append(i)
	_active_contact.clear()
	for i in count:
		if _inv_mass[i] != 0.0 and _c_flags[i] != 0:
			_active_contact.append(i)

	# --- Constraint solve ---
	for iter_i in iters:
		# Stretch (distance) constraints, inlined: 60 pairs on each of 8
		# iterations is 480 calls per rope per tick, and at that rate GDScript's
		# call overhead costs more than the arithmetic inside.
		for i in range(count - 1):
			var w_a := _inv_mass[i]
			var w_b := _inv_mass[i + 1]
			var w_sum := w_a + w_b
			if w_sum == 0.0:
				continue
			var p_a := _points[i]
			var p_b := _points[i + 1]
			var diff := p_b - p_a
			var dist := diff.length()
			if dist < 0.0001:
				continue
			var corr := diff * ((dist - segment_length) / dist * k_stretch / w_sum)
			_points[i] = p_a + corr * w_a
			_points[i + 1] = p_b - corr * w_b
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
				var allowed_sq := allowed * allowed
				var lo := s
				var span := count - s - lo
				var forward := iter_i % 2 == 0
				# _solve_bend inlined. Two hierarchy levels over ~59 particles on
				# each of 8 iterations is ~900 calls per rope per tick — the
				# hottest thing the solver does, where GDScript's call overhead
				# outweighs the body. The sweep direction is folded into the
				# index rather than duplicating the body into two loops.
				for n in span:
					var i := (lo + n) if forward else (count - s - 1 - n)
					var a := i - s
					var c := i + s
					var w_a := _inv_mass[a]
					var w_b := _inv_mass[i]
					var w_c := _inv_mass[c]
					var w_total := w_b + 0.5 * (w_a + w_c)
					if w_total == 0.0:
						continue
					var off := (_points[a] + _points[c]) * 0.5 - _points[i]
					var dev_sq := off.length_squared()
					if dev_sq < 1e-8:
						continue
					var v: Vector3
					if allowed > 0.0:
						if dev_sq <= allowed_sq:
							continue
						var dev := sqrt(dev_sq)
						v = off * ((dev - allowed) / dev * k_bend)
					else:
						v = off * k_bend
					_points[i] += v * (w_b / w_total)
					_points[a] -= v * (0.5 * w_a / w_total)
					_points[c] -= v * (0.5 * w_c / w_total)
				s *= 2
				levels -= 1
		# End stiffness (strain-relief boot): hold the first/last few segments
		# perfectly straight (allowed_dev 0) with a strong direct stiffness, so
		# the cable emerges rigid from each plug and only bends past the stub —
		# the floppy middle is unaffected. Applied after the general bend so it
		# wins near the ends. Anchor neighbours have inv_mass 0, so the pinned
		# endpoint isn't moved; the stub straightens toward it.
		if end_stiffness > 0.0 and end_stiff_segments > 0:
			var ke := clampf(end_stiffness, 0.0, 1.0)
			var n_end := mini(end_stiff_segments, (count - 1) / 2)
			if iter_i % 2 == 0:
				for i in range(1, n_end + 1):
					_solve_bend(i, 1, 0.0, _stub_weight(ke, i, n_end))
				for i in range(count - 2, count - 2 - n_end, -1):
					_solve_bend(i, 1, 0.0, _stub_weight(ke, count - 1 - i, n_end))
			else:
				for i in range(n_end, 0, -1):
					_solve_bend(i, 1, 0.0, _stub_weight(ke, i, n_end))
				for i in range(count - 1 - n_end, count - 1):
					_solve_bend(i, 1, 0.0, _stub_weight(ke, count - 1 - i, n_end))
		# Directional stub for a FIXED end: pull the first/last few particles onto
		# the line leaving the plug along its exit axis, so a held/socketed cable
		# emerges stiffly in the direction it plugs in (then bends past the stub).
		# Absolute targets — the pinned endpoint sits at _points[end].
		if end_stiffness > 0.0 and end_stiff_segments > 0 and (start_fixed or end_fixed):
			var ked := clampf(end_stiffness, 0.0, 1.0)
			var nd := mini(end_stiff_segments, (count - 1) / 2)
			if end_fixed:
				var base_e := _points[count - 1]
				for j in range(1, nd + 1):
					var idx := count - 1 - j
					if _inv_mass[idx] != 0.0:
						_points[idx] = _points[idx].lerp(
							base_e + end_exit * (segment_length * float(j)),
							_stub_weight(ked, j, nd))
			if start_fixed:
				var base_s := _points[0]
				for j in range(1, nd + 1):
					if _inv_mass[j] != 0.0:
						_points[j] = _points[j].lerp(
							base_s + start_exit * (segment_length * float(j)),
							_stub_weight(ked, j, nd))
		# Cached contact planes (refreshed on the throttled rest pass below) —
		# solved together with the other constraints so contacts, including
		# edge wraps, are part of the equilibrium instead of oscillating.
		for i in _active_mid:
			_solve_mid_contact(i)
		# Cached contact planes, inlined for the same reason as the bend: this
		# runs for every contacting particle on every iteration.
		for i in _active_contact:
			var flags := _c_flags[i]
			var p := _points[i]
			if (flags & 1) != 0:
				var n1 := _c_n1[i]
				var d1 := (p - _c_p1[i]).dot(n1)
				if d1 < collision_radius:
					p += n1 * (collision_radius - d1)
			if (flags & 2) != 0:
				var n2 := _c_n2[i]
				var d2 := (p - _c_p2[i]).dot(n2)
				if d2 < collision_radius:
					p += n2 * (collision_radius - d2)
			_points[i] = p
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

	# Cadence shared by the two heavy passes below.
	_raycast_frame += 1
	var do_rest := _raycast_frame >= raycast_interval
	if do_rest:
		_raycast_frame = 0

	# --- Self collision ---
	# Runs every tick, not on the cadence above, despite being the only
	# O(n²) pass here. Tried it at raycast_interval and a slack cable settles
	# visibly differently: with the pushout applied on one tick in three, gravity
	# and the stretch constraints close the coils unopposed in between, and a
	# cord that should drape off a table collapses into a flat pile on it.
	if self_collision:
		var min_d := collision_radius * 2.0
		var min_d_sq := min_d * min_d
		for i in range(count):
			var w_i := _inv_mass[i]
			var p_i := _points[i]
			for j in range(i + 2, count):
				var w_j := _inv_mass[j]
				var w_sum := w_i + w_j
				if w_sum == 0.0:
					continue
				var diff := _points[j] - p_i
				# Squared reject: this pass is O(n²) — ~1800 pairs a tick — and
				# all but a handful are nowhere near touching.
				var d_sq := diff.length_squared()
				if d_sq >= min_d_sq or d_sq < 1e-8:
					continue
				var dist := sqrt(d_sq)
				var push := diff * ((dist - min_d) / dist)
				p_i += push * (w_i / w_sum)
				_points[j] -= push * (w_j / w_sum)
			_points[i] = p_i

	# --- Surface collision ---
	if surface_collision_mask != 0 and _ray_query:
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
				# Deep-penetration guard: if the particle centre is BEHIND the
				# reported plane it has passed the surface, and ejecting along
				# this normal can pop it out the FAR side of a slab (under the
				# floor / on top of the ceiling). Don't cache — the wrong-side
				# recovery pass below walks it back to the rope's side instead.
				if not rest.is_empty() and rest["normal"] != Vector3.ZERO \
						and (_points[i] - rest["point"]).dot(rest["normal"]) >= 0.0:
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
				# Same deep-penetration guard as the particle pass: a midpoint
				# behind the reported plane must not be pushed out the far side.
				if (mid - rest["point"]).dot(n) < 0.0:
					continue
				_mid_contact[i] = 1
				_mid_contact_point[i] = rest["point"]
				_mid_contact_normal[i] = n

			# Wrong-side recovery: a particle that tunnelled through a slab gets
			# locked on the far side — every time the stretch constraints pull it
			# back toward the rope, the motion sweep hits the slab's far face
			# front-on and re-strands it there, so the state is self-sustaining
			# (the weird "cable pinned under the floor / above the ceiling" look).
			# Local contact info can't detect this; CONNECTIVITY can: marching
			# from the anchored end, cast the segment ray BOTH ways. A segment
			# genuinely passing through a slab enters one face and exits through
			# an opposing face (normals antiparallel), while a legit drape over an
			# edge crosses roughly perpendicular faces. Require the state on two
			# consecutive rest passes (transient corner clips self-correct via
			# _solve_mid_contact), then teleport the particle back to the entry
			# face. Runs of stuck particles recover march-order as each recovery
			# updates the reference position for the next segment.
			for i in range(1, count):
				if _inv_mass[i] == 0.0:
					continue
				var seg_vec := _points[i] - _points[i - 1]
				var seg_len := seg_vec.length()
				if seg_len < 0.0001:
					_stuck_passes[i] = 0
					continue
				_ray_query.from = _points[i - 1]
				_ray_query.to = _points[i] + seg_vec * (collision_radius / seg_len)
				var entry := space_state.intersect_ray(_ray_query)
				var entry_n: Vector3 = entry["normal"] if not entry.is_empty() else Vector3.ZERO
				# Must be meaningfully behind the entered face (not a corner graze)…
				if entry_n == Vector3.ZERO \
						or (_points[i] - entry["position"]).dot(entry_n) > -collision_radius:
					_stuck_passes[i] = 0
					continue
				# …and the reverse ray must exit through an opposing face.
				_ray_query.from = _points[i]
				_ray_query.to = _points[i - 1]
				var exit := space_state.intersect_ray(_ray_query)
				if exit.is_empty() or entry_n.dot(exit["normal"]) > -0.7:
					_stuck_passes[i] = 0
					continue
				_stuck_passes[i] += 1
				if _stuck_passes[i] < 2:
					continue
				_stuck_passes[i] = 0
				_points[i] = entry["position"] + entry_n * collision_radius
				_prev_points[i] = _points[i]
				_c_flags[i] = 0
				_mid_contact[i - 1] = 0
				if i < segment_count:
					_mid_contact[i] = 0

	# --- Two-way anchor coupling ---
	if anchor_pull > 0.0 and start_node and end_node:
		var ps := _anchor_point(start_node, start_anchor_offset, Vector3.ZERO)
		var pe := _anchor_point(end_node, end_anchor_offset, Vector3.ZERO)
		var span := ps.distance_to(pe)
		var excess := span - rest_length()
		if excess > 0.0:
			var force := excess * anchor_pull
			if _start_body:
				var dir_s := (pe - ps).normalized()
				_start_body.apply_force(dir_s * force, ps - _start_body.global_position)
			if _end_body:
				var dir_e := (ps - pe).normalized()
				_end_body.apply_force(dir_e * force, pe - _end_body.global_position)

	# --- Plug end-direction alignment (FREE ends only) ---
	# A free plug rigidbody follows the rope: it's rotated so its cable exits along
	# the rope's tangent instead of spinning freely. A FIXED end (held/socketed) is
	# the complement — there the rope followed the plug in the solve above, so we
	# skip it here. Rotating the plug doesn't move its anchor point, so this never
	# perturbs the sim (and can't keep the rope awake).
	if end_align_stiffness > 0.0 and count >= 2:
		if not start_fixed:
			_align_anchor_plug(start_node, _points[1] - _points[0], end_align_stiffness)
		if not end_fixed:
			_align_anchor_plug(end_node, _points[count - 2] - _points[count - 1], end_align_stiffness)

	# --- Sleep detection ---
	# Still = every particle moved less than SLEEP_POINT_EPS_SQ this tick AND
	# the anchors sit where we last saw them. The same pass tracks how far the
	# rope has strayed from the excursion window's reference pose, which is what
	# catches a cable that oscillates instead of stopping (see SLEEP_REF_FRAMES).
	var still := true
	if _sleep_ref.size() != count:
		_open_excursion_window()
	for i in count:
		if _points[i].distance_squared_to(_prev_points[i]) > SLEEP_POINT_EPS_SQ:
			still = false
		var e := _points[i].distance_squared_to(_sleep_ref[i])
		if e > _max_excursion_sq:
			_max_excursion_sq = e
	var a_start := _anchor_point(start_node, start_anchor_offset, _sleep_anchor_start)
	var a_end := _anchor_point(end_node, end_anchor_offset, _sleep_anchor_end)
	var anchors_still := \
		a_start.distance_squared_to(_sleep_anchor_start) <= WAKE_ANCHOR_EPS_SQ \
		and a_end.distance_squared_to(_sleep_anchor_end) <= WAKE_ANCHOR_EPS_SQ
	if not anchors_still:
		still = false
	_sleep_anchor_start = a_start
	_sleep_anchor_end = a_end
	if still:
		_still_frames += 1
		if _still_frames >= SLEEP_FRAMES:
			_sleep_now(count)
	else:
		_still_frames = 0

	_ref_frames += 1
	if _ref_frames >= SLEEP_REF_FRAMES:
		if anchors_still and _max_excursion_sq < SLEEP_EXCURSION_EPS_SQ:
			_sleep_now(count)
		else:
			_open_excursion_window()

	# Last thing in the tick, after the anchors are pinned: roll the render
	# history forward so _process has two states to interpolate between.
	_snapshot_render_state()


## Stub stiffness at the k-th particle from an end (k = 1 nearest), over n stub
## particles. Full strength at the plug, easing to nothing at the far end.
##
## Applying the SAME strength across the whole stub is what made the cable look
## like sausage links near a plug: every stub particle was held hard on the exit
## line and the very next one was completely free, so a rigid run met a floppy run
## at a hard boundary. The centreline turned up to 26 degrees in a single render
## ring there, and a constant-radius tube around a corner that tight necks in on
## the inside of the bend. Tapering spreads that turn over the whole stub.
func _stub_weight(base: float, k: int, n: int) -> float:
	if n <= 1:
		return base
	return base * (1.0 - float(k - 1) / float(n))


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
	var v: Vector3
	if allowed_dev > 0.0:
		# Squared test first: this is the solver's hottest call, and a particle
		# inside its allowance needs no root.
		var dev_sq := delta.length_squared()
		if dev_sq <= allowed_dev * allowed_dev or dev_sq < 1e-8:
			return
		var dev := sqrt(dev_sq)
		v = delta * ((dev - allowed_dev) / dev) * k
	else:
		# No free-bend allowance makes the (dev - allowed) / dev scale exactly 1,
		# so the correction is delta * k and the length is never needed. This is
		# the default path: max_bend_degrees is 0 unless a rope opts in, and the
		# strain-relief stub always passes 0. The degenerate case still has to be
		# dropped rather than scaled — nudging an already-straight triple by a
		# fraction of a micrometre is what stops a settled rope going to sleep.
		if delta.length_squared() < 1e-8:
			return
		v = delta * k
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


func _pin_anchors() -> void:
	if start_node:
		_points[0] = _anchor_point(start_node, start_anchor_offset, _points[0])
		_prev_points[0] = _points[0]
	if end_node:
		var last := _points.size() - 1
		_points[last] = _anchor_point(end_node, end_anchor_offset, _points[last])
		_prev_points[last] = _points[last]


## Snap point i to just outside a surface and convert its velocity into a
## friction-damped slide along the surface (no bounce).
func _resolve_contact(i: int, contact: Vector3, normal: Vector3) -> void:
	var vel := _points[i] - _prev_points[i]
	var tangential := vel - normal * vel.dot(normal)
	_points[i] = contact + normal * collision_radius
	_prev_points[i] = _points[i] - tangential * (1.0 - surface_friction)


## True when this anchor's orientation is externally fixed, so the cable should
## leave it stiffly along its exit axis rather than hanging freely. That's the
## case for BOTH ends' "connector" mounts: a host attach point (a plain Node3D
## rigidly bolted to a system/DVD/controller — always fixed) and a plug that's
## held in a hand or socketed into a port. A free-dangling plug is NOT fixed —
## it follows the rope instead (see _align_anchor_plug).
func _plug_is_fixed(node: Node3D) -> bool:
	if node == null:
		return false
	var rb := node as RigidBody3D
	if rb == null:
		return true   # host attach point — rigidly mounted to its device
	if rb.freeze:
		return true
	if rb.has_method("is_picked_up") and rb.is_picked_up():
		return true
	return false


## World-space direction the cable should leave this anchor along: the anchor's
## plug_exit_axis (local -Z) rotated into world space. For a plug that's its
## authored cable-exit end; for a host attach point that's the port face normal
## (all the video-out attach points sit identity-oriented on the device's -Z
## back, so the cable leaves straight out the back — perpendicular, not angled).
func _plug_exit_dir(node: Node3D) -> Vector3:
	if node == null:
		return Vector3.ZERO
	return (node.global_transform.basis.orthonormalized() * plug_exit_axis).normalized()


## Rotate a free plug rigidbody so its cable-exit axis (plug_exit_axis, local)
## points along `target_dir` (the rope's tangent at this end, world space),
## easing by `k` per frame. No-op unless the anchor is a RigidBody3D that isn't
## frozen (plugged into a port) or currently picked up — those cases are driven
## by the socket / grab and must not be fought.
func _align_anchor_plug(node: Node3D, target_dir: Vector3, k: float) -> void:
	var rb := node as RigidBody3D
	if rb == null or rb.freeze:
		return
	if rb.has_method("is_picked_up") and rb.is_picked_up():
		return
	if target_dir.length_squared() < 1e-8:
		return
	target_dir = target_dir.normalized()
	# We own this plug's rotation while it dangles free — kill any residual spin
	# so the physics engine doesn't drift it between our frames.
	rb.angular_velocity = Vector3.ZERO
	var basis := rb.global_transform.basis.orthonormalized()
	var cur_axis := (basis * plug_exit_axis).normalized()
	if cur_axis.length_squared() < 1e-8:
		return
	var dot := clampf(cur_axis.dot(target_dir), -1.0, 1.0)
	if dot > 0.9999:
		return   # already aligned
	var arc: Quaternion
	if dot < -0.9999:
		# Opposite directions — pick any perpendicular for the 180° flip.
		var perp := cur_axis.cross(Vector3.UP)
		if perp.length_squared() < 1e-6:
			perp = cur_axis.cross(Vector3.RIGHT)
		arc = Quaternion(perp.normalized(), PI)
	else:
		arc = Quaternion(cur_axis, target_dir)
	var cur_q := basis.get_rotation_quaternion()
	var target_q := (arc * cur_q).normalized()
	var new_q := cur_q.slerp(target_q, clampf(k, 0.0, 1.0))
	var xf := rb.global_transform
	xf.basis = Basis(new_q)
	rb.global_transform = xf


# ── Rendering ───────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _points.size() < 2:
		return
	if _interpolating and _render_points.size() == _curr_render.size():
		# Same fraction Godot uses to draw the plug, so the two cannot disagree.
		var f := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
		for i in _render_points.size():
			_render_points[i] = _prev_render[i].lerp(_curr_render[i], f)
		_mesh_dirty = true
	if _mesh_dirty:
		_render_tube()
		_mesh_dirty = false


## Roll the render history forward one physics tick. Called at the end of every
## simulated tick, after the anchors are pinned.
func _snapshot_render_state() -> void:
	var n := _points.size()
	if _curr_render.size() != n:
		_prev_render.resize(n)
		_curr_render.resize(n)
		_render_points.resize(n)
		for i in n:
			_prev_render[i] = _points[i]
			_curr_render[i] = _points[i]
			_render_points[i] = _points[i]
		_interpolating = false
		return
	var moved := false
	for i in n:
		_prev_render[i] = _curr_render[i]
		_curr_render[i] = _points[i]
		_render_points[i] = _points[i]
		if not moved and _prev_render[i].distance_squared_to(_curr_render[i]) > RENDER_FOLLOW_EPS_SQ:
			moved = true
	_interpolating = moved


## Fill _ring_points from the sim points — straight copy, or Catmull-Rom
## subdivision when smoothing > 0.
func _fill_ring_points() -> void:
	var count := _render_points.size()
	var sub := _subdiv()
	if sub == 1:
		for i in count:
			_ring_points[i] = _render_points[i]
		return
	var r := 0
	for i in range(count - 1):
		var p0 := _render_points[maxi(i - 1, 0)]
		var p1 := _render_points[i]
		var p2 := _render_points[i + 1]
		var p3 := _render_points[mini(i + 2, count - 1)]
		for s in sub:
			var t := float(s) / float(sub)
			var t2 := t * t
			var t3 := t2 * t
			_ring_points[r] = 0.5 * ((2.0 * p1)
				+ (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
			r += 1
	_ring_points[r] = _render_points[count - 1]


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
	var prev_tangent := Vector3.UP
	for i in count:
		var tangent: Vector3
		if i == 0:
			tangent = _ring_points[1] - _ring_points[0]
		elif i == count - 1:
			tangent = _ring_points[i] - _ring_points[i - 1]
		else:
			tangent = _ring_points[i + 1] - _ring_points[i - 1]
		# Degeneracy guard, so it has to sit far below the ring spacing
		# (segment_length / (smoothing + 1)) — this is metres SQUARED. At 0.0001
		# it meant 10 mm and fired on both END rings every frame: their tangent is
		# one-sided, and Catmull-Rom compresses the first and last sub-step to
		# ~8 mm. The ring then got built around Vector3.UP, putting its plane
		# ALONG the cable instead of across it, and the tube ended in a flat
		# sliver at every plug. Falling back to the previous ring's tangent also
		# beats a fixed axis: a real degeneracy is two coincident points, where
		# carrying the frame forward is what the parallel transport wants anyway.
		if tangent.length_squared() < 1e-12:
			tangent = prev_tangent
		else:
			tangent = tangent.normalized()
		prev_tangent = tangent
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
			var radial := side * _cos_table[j] + up * _sin_table[j]
			_vertex_array[base + j] = _ring_points[i] + radial * tube_radius
			var n4 := (base + j) * 4
			_normal_array[n4]     = radial.x
			_normal_array[n4 + 1] = radial.y
			_normal_array[n4 + 2] = radial.z

	# Two bulk uploads: positions to the vertex buffer, smooth normals to the
	# attribute buffer. Without the second the shader had to fall back on
	# screen-space derivatives, which shade each facet FLAT — a 12-sided tube then
	# reads as a visibly banded prism rather than a cord.
	(mesh as ArrayMesh).surface_update_vertex_region(0, 0, _vertex_array.to_byte_array())
	(mesh as ArrayMesh).surface_update_attribute_region(0, 0, _normal_array.to_byte_array())

	# Keep culling bounds in sync — surface_update_vertex_region() does NOT
	# recompute the mesh AABB (it stays a zero-size box at the origin), and this
	# node is top_level at the world origin, so without this the rope gets
	# frustum-culled (goes invisible) whenever the origin is off-screen.
	var aabb := AABB(_render_points[0], Vector3.ZERO)
	for i in range(1, _render_points.size()):
		aabb = aabb.expand(_render_points[i])
	custom_aabb = aabb.grow(collision_radius * 2.0)
