## Verlet rope — purely visual rope simulation between two 3D anchor points.
## Attach as a child; call set_anchors() or set start_node / end_node.
## Renders as a tube mesh using ImmediateMesh.
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
@export var tube_sides: int = 6

## Rope color
@export var rope_color: Color = Color(0.15, 0.15, 0.15, 1.0)

## Collision mask used for raycasting rope points against surfaces (layers 1+2 = floor/table)
@export_flags_3d_physics var surface_collision_mask: int = 3


# Internal point data
var _points: PackedVector3Array = []  # current positions (global space)
var _prev_points: PackedVector3Array = []  # previous positions for verlet

# Anchors
var start_node: Node3D = null
var end_node: Node3D = null

var _material: StandardMaterial3D


func _ready() -> void:
	# Create ImmediateMesh
	mesh = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.albedo_color = rope_color
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Ensure we render as a global-space mesh (we'll supply global coords)
	top_level = true
	global_transform = Transform3D.IDENTITY
	_init_points()


func _init_points() -> void:
	var count := segment_count + 1
	_points.resize(count)
	_prev_points.resize(count)

	# Place points in a straight line between anchors (or a short droop if no anchors yet)
	var start_pos := start_node.global_position if start_node else global_position
	var end_pos := end_node.global_position if end_node else start_pos + Vector3(0, -segment_count * segment_length, 0)

	for i in count:
		var t := float(i) / float(count - 1) if count > 1 else 0.0
		_points[i] = start_pos.lerp(end_pos, t)
		_prev_points[i] = _points[i]


func _process(delta: float) -> void:
	if _points.size() == 0:
		return

	# --- Verlet integration ---
	var count := _points.size()
	for i in range(1, count):  # skip point 0 (pinned)
		var current := _points[i]
		var prev := _prev_points[i]
		var velocity := (current - prev) * (1.0 - damping)
		_prev_points[i] = current
		_points[i] = current + velocity + gravity * (delta * delta)

	# Pin first point to start anchor
	if start_node:
		_points[0] = start_node.global_position
		_prev_points[0] = _points[0]

	# Pin last point to end anchor
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
			var error := (dist - segment_length) / dist
			var correction := diff * error * 0.5

			if i == 0:
				# Point 0 is pinned — only move b
				_points[i + 1] = b - correction * 2.0
			elif i + 1 == count - 1 and end_node:
				# Last point is pinned — only move a
				_points[i] = a + correction * 2.0
			else:
				_points[i] = a + correction
				_points[i + 1] = b - correction

		# Re-pin anchors after each iteration
		if start_node:
			_points[0] = start_node.global_position
		if end_node:
			_points[count - 1] = end_node.global_position

	# --- Surface collision: raycast each point downward ---
	if surface_collision_mask != 0:
		var space_state := get_world_3d().direct_space_state
		for i in range(count):
			# Skip pinned anchor points
			if i == 0 and start_node:
				continue
			if i == count - 1 and end_node:
				continue
			var from := _points[i] + Vector3(0, 0.05, 0)
			var to := _points[i] + Vector3(0, -0.5, 0)
			var query := PhysicsRayQueryParameters3D.create(from, to, surface_collision_mask)
			var hit := space_state.intersect_ray(query)
			if hit and _points[i].y < hit["position"].y:
				_points[i].y = hit["position"].y
				_prev_points[i].y = hit["position"].y

	# --- Render ---
	_render_tube()


func _render_tube() -> void:
	var im := mesh as ImmediateMesh
	im.clear_surfaces()

	var count := _points.size()
	if count < 2:
		return

	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _material)

	# Build tube geometry — for each pair of adjacent points, emit a ring
	for i in range(count):
		# Tangent direction
		var tangent: Vector3
		if i == 0:
			tangent = (_points[1] - _points[0]).normalized()
		elif i == count - 1:
			tangent = (_points[i] - _points[i - 1]).normalized()
		else:
			tangent = (_points[i + 1] - _points[i - 1]).normalized()

		if tangent.length_squared() < 0.0001:
			tangent = Vector3.UP

		# Build a local coordinate frame
		var up := Vector3.UP if abs(tangent.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var side := tangent.cross(up).normalized()
		up = side.cross(tangent).normalized()

		for j in range(tube_sides + 1):
			var angle := TAU * float(j) / float(tube_sides)
			var offset := (side * cos(angle) + up * sin(angle)) * tube_radius
			var pos := _points[i] + offset
			var normal := offset.normalized()
			im.surface_set_normal(normal)
			im.surface_add_vertex(pos)

			# Connect to next ring — add degenerate if not last point
			if i < count - 1:
				var next_tangent: Vector3
				if i + 1 == count - 1:
					next_tangent = (_points[i + 1] - _points[i]).normalized()
				else:
					next_tangent = (_points[i + 2] - _points[i]).normalized()
				if next_tangent.length_squared() < 0.0001:
					next_tangent = tangent

				var next_up := Vector3.UP if abs(next_tangent.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
				var next_side := next_tangent.cross(next_up).normalized()
				next_up = next_side.cross(next_tangent).normalized()

				var next_offset := (next_side * cos(angle) + next_up * sin(angle)) * tube_radius
				var next_pos := _points[i + 1] + next_offset
				var next_normal := next_offset.normalized()
				im.surface_set_normal(next_normal)
				im.surface_add_vertex(next_pos)

	im.surface_end()
