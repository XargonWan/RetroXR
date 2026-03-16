## Verlet rope — purely visual rope simulation between two 3D anchor points.
## Attach as a child; call set_anchors() or set start_node / end_node.
## Renders as a tube mesh using ArrayMesh with indexed triangles.
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

## Tube radius for rendering
@export var tube_radius: float = 0.005

## Number of radial segments for the tube cross-section
@export var tube_sides: int = 4

## Rope color
@export var rope_color: Color = Color(0.15, 0.15, 0.15, 1.0)

## Collision mask used for raycasting rope points against surfaces (layers 1+2 = floor/table)
@export_flags_3d_physics var surface_collision_mask: int = 3

## How many physics frames to skip between surface raycasts (higher = cheaper)
@export var raycast_interval: int = 3


# Internal point data
var _points: PackedVector3Array = []       # current positions (global space)
var _prev_points: PackedVector3Array = []  # previous positions for verlet

# Anchors
var start_node: Node3D = null
var end_node: Node3D = null

var _material: StandardMaterial3D

# Pre-cached trig tables (rebuilt when tube_sides changes)
var _cos_table: PackedFloat32Array
var _sin_table: PackedFloat32Array

# Pre-allocated vertex buffer updated each frame
var _vertex_array: PackedVector3Array

# Raycast throttle counter
var _raycast_frame: int = 0

# Reusable raycast query (avoids per-point allocation)
var _ray_query: PhysicsRayQueryParameters3D


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


func _build_trig_tables() -> void:
	_cos_table.resize(tube_sides)
	_sin_table.resize(tube_sides)
	for j in tube_sides:
		var angle := TAU * float(j) / float(tube_sides)
		_cos_table[j] = cos(angle)
		_sin_table[j] = sin(angle)


func _build_mesh_topology() -> void:
	var ring_count := segment_count + 1
	_vertex_array = PackedVector3Array()
	_vertex_array.resize(ring_count * tube_sides)

	# Index buffer — topology never changes, built once
	var indices := PackedInt32Array()
	indices.resize(segment_count * tube_sides * 6)
	var idx := 0
	for i in segment_count:
		for j in tube_sides:
			var a := i * tube_sides + j
			var b := i * tube_sides + (j + 1) % tube_sides
			var c := (i + 1) * tube_sides + j
			var d := (i + 1) * tube_sides + (j + 1) % tube_sides
			indices[idx]     = a; indices[idx + 1] = b; indices[idx + 2] = c
			indices[idx + 3] = b; indices[idx + 4] = d; indices[idx + 5] = c
			idx += 6

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertex_array
	arrays[Mesh.ARRAY_INDEX]  = indices

	mesh = ArrayMesh.new()
	(mesh as ArrayMesh).add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	(mesh as ArrayMesh).surface_set_material(0, _material)


func _init_points() -> void:
	var count := segment_count + 1
	_points.resize(count)
	_prev_points.resize(count)

	var start_pos := start_node.global_position if start_node else global_position
	var end_pos   := end_node.global_position   if end_node   else start_pos + Vector3(0, -segment_count * segment_length, 0)

	for i in count:
		var t := float(i) / float(count - 1) if count > 1 else 0.0
		_points[i]      = start_pos.lerp(end_pos, t)
		_prev_points[i] = _points[i]


func _physics_process(delta: float) -> void:
	if _points.size() == 0:
		return

	var count := _points.size()

	# --- Verlet integration ---
	for i in range(1, count):
		var current := _points[i]
		var velocity := (current - _prev_points[i]) * (1.0 - damping)
		_prev_points[i] = current
		_points[i] = current + velocity + gravity * (delta * delta)

	# Pin anchors
	if start_node:
		_points[0] = start_node.global_position
		_prev_points[0] = _points[0]
	if end_node:
		_points[count - 1] = end_node.global_position
		_prev_points[count - 1] = _points[count - 1]

	# --- Distance constraints ---
	for _iter in constraint_iterations:
		for i in range(count - 1):
			var a := _points[i]
			var b := _points[i + 1]
			var diff := b - a
			var dist := diff.length()
			if dist < 0.0001:
				continue
			var correction := diff * ((dist - segment_length) / dist) * 0.5
			if i == 0:
				_points[i + 1] = b - correction * 2.0
			elif i + 1 == count - 1 and end_node:
				_points[i] = a + correction * 2.0
			else:
				_points[i]     = a + correction
				_points[i + 1] = b - correction

		if start_node:
			_points[0] = start_node.global_position
		if end_node:
			_points[count - 1] = end_node.global_position

	# --- Surface collision (throttled) ---
	if surface_collision_mask != 0 and _ray_query:
		_raycast_frame += 1
		if _raycast_frame >= raycast_interval:
			_raycast_frame = 0
			var space_state := get_world_3d().direct_space_state
			for i in range(count):
				if (i == 0 and start_node) or (i == count - 1 and end_node):
					continue
				_ray_query.from = _points[i] + Vector3(0, 0.05, 0)
				_ray_query.to   = _points[i] + Vector3(0, -0.5, 0)
				var hit := space_state.intersect_ray(_ray_query)
				if hit and _points[i].y < hit["position"].y:
					_points[i].y      = hit["position"].y
					_prev_points[i].y = hit["position"].y


func _process(_delta: float) -> void:
	if _points.size() >= 2:
		_render_tube()


func _render_tube() -> void:
	var count := _points.size()

	# Pre-compute one ring frame per ring (avoids recomputing per vertex)
	var sides:  Array[Vector3] = []
	var ups:    Array[Vector3] = []
	sides.resize(count)
	ups.resize(count)

	for i in count:
		var tangent: Vector3
		if i == 0:
			tangent = _points[1] - _points[0]
		elif i == count - 1:
			tangent = _points[i] - _points[i - 1]
		else:
			tangent = _points[i + 1] - _points[i - 1]
		if tangent.length_squared() < 0.0001:
			tangent = Vector3.UP
		else:
			tangent = tangent.normalized()
		var ref := Vector3.UP if abs(tangent.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var side := tangent.cross(ref).normalized()
		sides[i] = side
		ups[i]   = side.cross(tangent).normalized()

	# Fill vertex buffer
	for i in count:
		var base := i * tube_sides
		var side := sides[i]
		var up   := ups[i]
		for j in tube_sides:
			_vertex_array[base + j] = _points[i] + (side * _cos_table[j] + up * _sin_table[j]) * tube_radius

	# Single bulk upload to GPU
	(mesh as ArrayMesh).surface_update_vertex_region(0, 0, _vertex_array.to_byte_array())
