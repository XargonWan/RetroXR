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
## Start curved. AppPrefs.menu_curved overrides this at runtime — the export is
## only the fallback for a panel built outside the app (probes, tests).
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

var _grip: PanelResizeGrip = null
var _grip_mesh: MeshInstance3D = null
## Set while a resize drag is live: the pointer that started it, the panel-local
## point it grabbed, and the size at that moment.
var _drag_pointer: Node3D = null
var _drag_from := Vector3.ZERO
var _drag_size := Vector2.ZERO
## Scratch resources so the addon's setter has something it can write to.
var _scratch_mesh := QuadMesh.new()
var _scratch_shape := BoxShape3D.new()

## Arc length past the screen edge, and the spacing between the two buttons.
const BTN_GAP := 0.035
const BTN_PITCH := 0.055

## Resize limits, in metres. Small enough to tuck away, big enough to fill view.
const MIN_SIZE := Vector2(0.55, 0.38)
const MAX_SIZE := Vector2(2.20, 1.50)
## Arm length of the "_|" corner mark, its bar thickness, and its hit box.
const GRIP_ARM := 0.045
const GRIP_BAR := 0.008
const GRIP_HIT := 0.055

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
	call_deferred("_build_grip")
	curved = AppPrefs.menu_curved
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
		# Outward normal: FROM the surface TOWARD the centre of curvature at +Z,
		# i.e. back at the viewer. The other way round leaves the screen's lit
		# material shaded from behind (cull_mode is disabled, so it still draws —
		# the error shows only as wrong shading).
		var n := Vector3(0, 0, 1)
		if _curve > 0.001:
			var r := curve_radius / _curve
			n = (Vector3(0.0, 0.0, r) - Vector3(top.x, 0.0, top.z)).normalized()
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

	_place_buttons()
	_place_grip()


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

## A press: apply it and remember it. Kept apart from set_curved so nothing
## internal can write the prefs file as a side effect.
func _choose(on: bool) -> void:
	set_curved(on)
	AppPrefs.menu_curved = on
	AppPrefs.save_prefs()


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
	_btn_flat = _make_button("CurveToggleFlat", false)
	_btn_curved = _make_button("CurveToggleCurved", true)
	_btn_flat.button_pressed.connect(func() -> void: _choose(false))
	_btn_curved.button_pressed.connect(func() -> void: _choose(true))
	_place_buttons()
	_refresh_buttons()


## Seat the buttons ON the arc, continuing it past the screen's edge, and turn
## them to face along it. Left at z = 0 they would sit ~11 cm behind the edge
## once the panel wrapped, floating off the corner they belong to.
func _place_buttons() -> void:
	if _btn_flat == null or _btn_curved == null:
		return
	var hw := _screen_size.x * 0.5
	var hh := _screen_size.y * 0.5
	var s := hw + BTN_GAP
	var yaw := 0.0
	if _curve > 0.001:
		yaw = -s / (curve_radius / _curve)
	for pair: Array in [[_btn_flat, -hh + 0.015], [_btn_curved, -hh + 0.015 + BTN_PITCH]]:
		var btn: VRButton = pair[0]
		btn.position = _arc_point(s, pair[1])
		btn.rotation = Vector3(0.0, yaw, 0.0)


func _make_button(node_name: String, arced: bool) -> VRButton:
	var btn := VRButton.new()
	btn.name = node_name
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


# ── Resize ────────────────────────────────────────────────────────────────────

## The "_|" mark at the panel's lower-right corner.
func _build_grip() -> void:
	_grip = PanelResizeGrip.create(self, Vector3(GRIP_HIT, GRIP_HIT, 0.02))
	_grip_mesh = MeshInstance3D.new()
	_grip_mesh.name = "GripMesh"
	_grip_mesh.mesh = _grip_corner_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = HL_OFF
	_grip_mesh.set_surface_override_material(0, mat)
	_grip.add_child(_grip_mesh)
	add_child(_grip)
	_place_grip()


## Two bars meeting at the bottom-right: one along the bottom, one up the right.
func _grip_corner_mesh() -> ArrayMesh:
	var a := GRIP_ARM
	var b := GRIP_BAR
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for r: Array in [[-a, 0.0, 0.0, b], [-b, 0.0, 0.0, a]]:
		# r = [x0, y0, x1, y1] as offsets from the corner at (0, 0).
		var x0: float = r[0]
		var y0: float = r[1]
		var x1: float = r[2]
		var y1: float = r[3]
		var n := verts.size()
		verts.append(Vector3(x0, y0, 0.0))
		verts.append(Vector3(x1, y0, 0.0))
		verts.append(Vector3(x1, y1, 0.0))
		verts.append(Vector3(x0, y1, 0.0))
		idx.append_array([n, n + 1, n + 2, n, n + 2, n + 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## On the arc at the lower-right corner, facing along it — same reasoning as the
## toggle buttons, which were left behind the edge when it was pinned to z = 0.
func _place_grip() -> void:
	if _grip == null:
		return
	var hw := _screen_size.x * 0.5
	var hh := _screen_size.y * 0.5
	var yaw := 0.0
	if _curve > 0.001:
		yaw = -hw / (curve_radius / _curve)
	_grip.position = _arc_point(hw, -hh)
	_grip.rotation = Vector3(0.0, yaw, 0.0)


## Called by the grip on PRESSED. Remembers which pointer owns the drag.
func resize_begin(pointer: Node3D) -> void:
	if not is_instance_valid(pointer):
		return
	_drag_pointer = pointer
	_drag_size = _screen_size
	_drag_from = _pointer_on_plane(pointer)
	if is_instance_valid(_grip_mesh):
		(_grip_mesh.get_surface_override_material(0) as StandardMaterial3D).albedo_color = HL_ON


func resize_end() -> void:
	_drag_pointer = null
	if is_instance_valid(_grip_mesh):
		(_grip_mesh.get_surface_override_material(0) as StandardMaterial3D).albedo_color = HL_OFF


func _process(_delta: float) -> void:
	if not is_instance_valid(_drag_pointer):
		return
	var now := _pointer_on_plane(_drag_pointer)
	var d := now - _drag_from
	# The panel is centred on its origin, so a corner moved by d changes the
	# half-extent by d and the full size by twice that. Down is -y.
	_apply_screen_size(Vector2(
		clampf(_drag_size.x + d.x * 2.0, MIN_SIZE.x, MAX_SIZE.x),
		clampf(_drag_size.y - d.y * 2.0, MIN_SIZE.y, MAX_SIZE.y)))


## Where this pointer is aiming, on the panel's z = 0 plane, in panel-local
## space. Following pointer MOVED events instead would end the drag the instant
## the cursor left the grip, which is immediately.
func _pointer_on_plane(pointer: Node3D) -> Vector3:
	var inv := _panel.global_transform.affine_inverse()
	var origin := inv * pointer.global_position
	var dir := (inv.basis * (-pointer.global_transform.basis.z)).normalized()
	if absf(dir.z) < 0.0001:
		return Vector3(origin.x, origin.y, 0.0)
	var t := -origin.z / dir.z
	return origin + dir * t


## Resize without tripping the addon's setter, which writes mesh.size and
## shape.size — neither of which exists on the arc mesh or its trimesh. Hand it a
## QuadMesh and a BoxShape to scribble on, let it update its own bookkeeping
## (including the body's screen_size, which the pointer mapping reads), then put
## the real geometry back.
func _apply_screen_size(new_size: Vector2) -> void:
	if new_size.is_equal_approx(_screen_size):
		return
	_screen_size = new_size
	_screen.mesh = _scratch_mesh
	_collision.shape = _scratch_shape
	_panel.set("screen_size", new_size)
	_rebuild()
