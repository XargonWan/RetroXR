## CurvedPanel — lets an XRToolsViewport2DIn3D wrap toward the viewer, with a
## flat/curved toggle sitting just outside its lower-right corner.
##
## The spawn menu is 1.1 m wide at 0.9 m, so it subtends ~63 deg and its corners
## sit ~17% further from the eye than its centre. Wrapping it onto a cylinder
## takes that out.
##
## Added as a CHILD of the Viewport2DIn3D rather than as a script on it — the
## panel already carries the addon's own script, which owns the viewport and the
## embedded scene — and rather than as an inherited scene, so neither the addon
## nor player_rig has to be restructured.
## Three things have to stay in agreement:
##
##  1. the Screen mesh — a cylindrical arc with UVs linear in ARC LENGTH, so the
##     picture neither stretches nor compresses toward the edges;
##  2. the collision — a BoxShape3D cannot bend, so it becomes a
##     ConcavePolygonShape3D built from the same arc;
##  3. where a hit lands in the viewport — viewport_2d_in_3d_body.global_to_viewport
##     maps a hit with two planar lines. Rather than subclass it, this intercepts
##     its pointer_event and rewrites the hit to the equivalent point on the flat
##     plane, so the addon's own maths still produces the right pixel.
##
## Skipping (3) is the tempting shortcut and it does not work: an arc maps angle
## as x = R*theta while a flat plane maps it as x = R*tan(theta), which at this
## panel's edge is ~14% out — far enough to press the wrong control.
class_name CurvedPanel
extends Node3D

## Cylinder radius at full curve, in metres. Not the 0.9 m spawn distance: the
## panel is grabbable between 0.3 m and 2.5 m, so a curve tuned to one distance
## looks wrong at every other. This reads as a gentle wrap across that range.
@export var curve_radius: float = 1.4
## Segments across the arc. 24 is smooth at this width and still a trivial mesh.
@export var segments: int = 24
@export var animate_seconds: float = 0.22
## Start curved.
@export var curved: bool = true

## 0 = flat, 1 = fully wrapped. Animated between the two.
var _curve: float = 0.0
var _tween: Tween = null

var _screen: MeshInstance3D = null
var _body: StaticBody3D = null
var _collision: CollisionShape3D = null
var _screen_size := Vector2(1.1, 0.75)

var _btn_flat: VRButton = null
var _btn_curved: VRButton = null

const HL_ON := Color(1.0, 0.78, 0.30)
const HL_OFF := Color(0.42, 0.45, 0.55)


var _panel: Node3D = null


func _ready() -> void:
	_panel = get_parent() as Node3D
	if _panel == null:
		push_warning("CurvedPanel: must be a child of an XRToolsViewport2DIn3D")
		return
	_screen = _panel.get_node_or_null("Screen") as MeshInstance3D
	_body = _panel.get_node_or_null("StaticBody3D") as StaticBody3D
	if _body:
		_collision = _body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if _screen == null or _body == null or _collision == null:
		push_warning("CurvedPanel: expected Screen/StaticBody3D/CollisionShape3D — panel left flat")
		return

	var size: Variant = _panel.get("screen_size")
	if size is Vector2:
		_screen_size = size

	# All deferred on purpose. Children _ready BEFORE their parent, so at this
	# point the panel has not run its own _ready yet — which wires the body's
	# pointer handler and calls _update_screen_size(), resetting the mesh to a
	# QuadMesh and the shape to a box. Deferring puts this after both.
	call_deferred("_intercept_pointer")
	call_deferred("_build_toggle")
	_curve = 1.0 if curved else 0.0
	call_deferred("_rebuild")


# ── Geometry ──────────────────────────────────────────────────────────────────

## Local-space point for an arc parameter. `s` is arc length from the centre
## (-w/2 .. w/2), so UVs stay linear and the picture does not stretch.
func _arc_point(s: float, y: float) -> Vector3:
	if _curve <= 0.001:
		return Vector3(s, y, 0.0)
	var r := curve_radius / _curve
	var theta := s / r
	return Vector3(r * sin(theta), y, r * (1.0 - cos(theta)))


func _rebuild() -> void:
	if _screen == null:
		return
	var hw := _screen_size.x * 0.5
	var hh := _screen_size.y * 0.5

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var tris := PackedVector3Array()

	for i in range(segments + 1):
		var t := float(i) / float(segments)
		var s: float = lerp(-hw, hw, t)
		var top := _arc_point(s, hh)
		var bot := _arc_point(s, -hh)
		verts.append(top)
		verts.append(bot)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		# Outward normal: away from the centre of curvature, which sits at +Z.
		var n := Vector3(0, 0, 1)
		if _curve > 0.001:
			var r := curve_radius / _curve
			n = (Vector3(top.x, 0.0, top.z) - Vector3(0.0, 0.0, r)).normalized()
		normals.append(n)
		normals.append(n)

	var idx := PackedInt32Array()
	for i in range(segments):
		var a := i * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		idx.append_array([a, b, c, c, b, d])
		tris.append_array([verts[a], verts[b], verts[c], verts[c], verts[b], verts[d]])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := _screen.get_surface_override_material(0)
	if mat == null and _screen.mesh != null:
		mat = _screen.mesh.surface_get_material(0)
	_screen.mesh = mesh
	if mat:
		_screen.set_surface_override_material(0, mat)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	_collision.shape = shape


# ── Pointer remap ─────────────────────────────────────────────────────────────

func _intercept_pointer() -> void:
	if _body == null or not _body.has_signal("pointer_event"):
		return
	if _body.has_method("_on_pointer_event") \
			and _body.pointer_event.is_connected(_body._on_pointer_event):
		_body.pointer_event.disconnect(_body._on_pointer_event)
	if not _body.pointer_event.is_connected(_on_pointer_event):
		_body.pointer_event.connect(_on_pointer_event)


## Flatten the hit, then hand it to the addon's planar handler unchanged.
func _on_pointer_event(event: XRToolsPointerEvent) -> void:
	if _curve > 0.001:
		event.position = _flatten(event.position)
		event.last_position = _flatten(event.last_position)
	if _body.has_method("_on_pointer_event"):
		_body._on_pointer_event(event)


## Curved-surface hit -> the point on the flat plane that maps to the same pixel.
## theta = atan2(x, R - z) recovers the angle about the centre of curvature, and
## arc length R*theta is exactly the flat-plane x the addon expects.
func _flatten(at: Vector3) -> Vector3:
	var t := _collision.global_transform
	var local := t.affine_inverse() * at
	var r := curve_radius / _curve
	var theta := atan2(local.x, r - local.z)
	return t * Vector3(r * theta, local.y, 0.0)


# ── Flat / curved toggle ──────────────────────────────────────────────────────

func set_curved(on: bool, animate := true) -> void:
	curved = on
	_refresh_buttons()
	var target := 1.0 if on else 0.0
	if _tween and _tween.is_valid():
		_tween.kill()
	if not animate or animate_seconds <= 0.0:
		_curve = target
		_rebuild()
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_set_curve_step, _curve, target, animate_seconds)


func _set_curve_step(v: float) -> void:
	_curve = v
	_rebuild()


func _refresh_buttons() -> void:
	if _btn_flat:
		_btn_flat.set_latched_pressed(not curved)
		_btn_flat.set_color(HL_OFF if curved else HL_ON)
	if _btn_curved:
		_btn_curved.set_latched_pressed(curved)
		_btn_curved.set_color(HL_ON if curved else HL_OFF)


## Two buttons just outside the lower-right corner. The icons are the shapes
## themselves — a straight bar and an arced one — so they need no legend.
func _build_toggle() -> void:
	var hw := _screen_size.x * 0.5
	var hh := _screen_size.y * 0.5
	var gap := 0.035
	var pitch := 0.055

	_btn_flat = _make_button("CurveToggleFlat",
		Vector3(hw + gap, -hh + 0.015, 0.0), false)
	_btn_curved = _make_button("CurveToggleCurved",
		Vector3(hw + gap, -hh + 0.015 + pitch, 0.0), true)
	_btn_flat.button_pressed.connect(func() -> void: set_curved(false))
	_btn_curved.button_pressed.connect(func() -> void: set_curved(true))
	_refresh_buttons()


func _make_button(node_name: String, pos: Vector3, arced: bool) -> VRButton:
	var btn := VRButton.new()
	btn.name = node_name
	btn.position = pos
	btn.depress_axis = Vector3(0, 0, -1)
	btn.depress_depth = 0.004

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.044, 0.044, 0.012)
	shape.shape = box
	btn.add_child(shape)

	# Named ButtonMesh and parented BEFORE the button enters the tree:
	# VRButton._ready resolves `@onready _mesh = $ButtonMesh` and immediately
	# reads _mesh.position, so a later add_child would have it dereference null.
	var mi := MeshInstance3D.new()
	mi.name = "ButtonMesh"
	mi.mesh = _icon_mesh(arced)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Flat ribbons with no back to speak of — without this the winding decides
	# whether you can see them at all.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = HL_OFF
	mi.set_surface_override_material(0, mat)
	btn.add_child(mi)

	add_child(btn)
	return btn


## A pictogram, not a miniature: a straight ribbon for flat, an arched one for
## curved. The bow runs in Y — in the plane facing the player — because a bow in
## Z is exactly edge-on from where they stand and reads as a plain rectangle.
func _icon_mesh(arced: bool) -> ArrayMesh:
	var half := 0.018
	var thick := 0.0035
	var bow: float = 0.010 if arced else 0.0
	var steps := 12

	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var x: float = lerp(-half, half, t)
		# Parabolic arch — indistinguishable from a true arc at this size.
		var mid: float = bow * (1.0 - pow(x / half, 2.0))
		verts.append(Vector3(x, mid + thick, 0.0))
		verts.append(Vector3(x, mid - thick, 0.0))
	for i in range(steps):
		var a := i * 2
		idx.append_array([a, a + 1, a + 2, a + 2, a + 1, a + 3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
