## Bakes the Wii's shell and its front keys to Scenes/Objects/wii_*.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen_wii_body.gd
##
## Everything here exists because the machine is not made of boxes. Its FRONT-LEFT
## vertical edge is chamfered, that chamfer runs the whole height of the case, and
## every key on the front repeats the same 45 degrees as a cut across its own
## top-left corner. A photograph from above shows the first; a photograph from the
## front barely does, because it is a corner taken off the CROSS-SECTION rather than
## a detail printed on a face.
##
## The shell is therefore a prism — a pentagon extruded up Y. The keys are NOT flat
## plates on the front face: each one runs across the corner and BENDS through the
## chamfer, so part of every key lies on the 45 degree facet. Their cross-section is
## an L, which is why the caps here are triangulated rather than fanned — a fan only
## works on a convex outline.
##
## One routine builds both: give it a cross-section and an extrusion, and it returns
## the solid.
##
## The chamfer takes the flat front face from 44 mm down to 37 mm, running
## x -0.015 .. +0.022. Everything printed on that face in wii_primitive.tscn had to
## move right to stay on it.
##
## The machine is 44 x 157 x 215.4 with the 215.4 as its DEPTH, not its height: laid
## flat that reads 157 wide, 44 high, 215 deep. Getting those two the wrong way round
## is what made an earlier cut of this model wrong everywhere at once — the front face
## came out 215 long instead of 157, which put a 176 mm disc slot on a machine that
## takes a 120 mm disc. Every key height here is a fraction of the FACE, so they
## scaled with it.
##
## Winding is load-bearing and is NOT reasoned about here — it is measured, twice.
## The cross-section is normalised so the caps and the sides agree with each other,
## and then the finished solid is weighed by its own STORED normals and flipped whole
## if those face inward. Both steps are needed and neither substitutes for the other:
## opposed caps and sides cannot be fixed by flipping everything, and a consistently
## wound solid can still be consistently wrong. An inside-out solid is not obviously
## broken to look at — it renders as a convincing object you can see straight through,
## which is how one shipped twice.
extends SceneTree

const HALF_W := 0.022      # 44 mm across
const HALF_H := 0.0785     # 157 mm tall standing up
const HALF_D := 0.1077     # 215.4 mm deep
const BODY_CHAMFER := 0.007

## Front keys: name, length on the FRONT face, length on the CHAMFER, height.
##
## Both legs are measured from the fold, which is where the mesh's origin sits — so a
## key is placed in the scene at the fold line itself, x -0.015, and needs no
## centring maths.
const KEYS := [
	["power", 0.016, 0.006, 0.0073],
	["reset", 0.016, 0.006, 0.0058],
	["eject", 0.014, 0.005, 0.0055],
]

## How thick a key stands off the shell, and the seam plate behind it. The seam is
## the same bent shape reaching 0.7 mm further along each leg and 0.7 mm past each
## end, and standing 1 mm less proud — so what shows round a fitted key is an even
## dark border, and the key itself sits in it.
const KEY_T := 0.0025
const SEAM_T := 0.0015
const SEAM_GROW := 0.0007

## The SD door turns the corner exactly as the keys do, so it is the same bent plate
## 90 mm tall. Three of them, nested by thickness so none z-fights its neighbour: the
## seam sits deepest and reaches furthest, the bay recess is what shows once the door
## has swung, and the door itself stands proudest.
const DOOR_FRONT := 0.016
const DOOR_CHAM := 0.006
const DOOR_HALF_H := 0.0328
const DOOR_T := 0.0018
const DOOR_BAY_T := 0.0014
const DOOR_SEAM_T := 0.0010


func _init() -> void:
	# --- the shell -----------------------------------------------------------
	# Cross-section in XZ, anticlockwise seen from ABOVE, starting on the chamfer.
	var body := PackedVector2Array([
		Vector2(-HALF_W, HALF_D - BODY_CHAMFER),   # up the left face to the cut
		Vector2(-HALF_W + BODY_CHAMFER, HALF_D),   # across the chamfer
		Vector2(HALF_W, HALF_D),                   # front-right
		Vector2(HALF_W, -HALF_D),                  # back-right
		Vector2(-HALF_W, -HALF_D),                 # back-left
	])
	_save(_solid(body, HALF_H, true), "res://Scenes/Objects/wii_body.res")

	# --- the keys ------------------------------------------------------------
	for row in KEYS:
		_save(_solid(_bent(row[1], row[2], KEY_T), row[3] * 0.5, true),
			"res://Scenes/Objects/wii_key_%s.res" % row[0])
		_save(_solid(_bent(row[1] + SEAM_GROW, row[2] + SEAM_GROW, SEAM_T),
			row[3] * 0.5 + SEAM_GROW, true),
			"res://Scenes/Objects/wii_seam_%s.res" % row[0])

	# --- the SD door ---------------------------------------------------------
	_save(_solid(_bent(DOOR_FRONT, DOOR_CHAM, DOOR_T), DOOR_HALF_H, true),
		"res://Scenes/Objects/wii_door.res")
	_save(_solid(_bent(DOOR_FRONT, DOOR_CHAM, DOOR_BAY_T), DOOR_HALF_H, true),
		"res://Scenes/Objects/wii_door_bay.res")
	_save(_solid(_bent(DOOR_FRONT + SEAM_GROW, DOOR_CHAM + SEAM_GROW, DOOR_SEAM_T),
		DOOR_HALF_H + SEAM_GROW, true),
		"res://Scenes/Objects/wii_door_seam.res")
	quit()


## The profile of a key that turns the corner, in XZ, with the FOLD at the origin:
## one leg out along +X on the front face, the other back along the chamfer, and a
## skin `t` thick over both.
##
## The outer surface of a fold is not simply each face offset by t — the two offsets
## meet further out than that. The corner point runs along the bisector by
## t / cos(22.5 deg), which is what keeps the skin an even thickness right through
## the bend instead of pinching at it.
func _bent(front_len: float, cham_len: float, t: float) -> PackedVector2Array:
	var h := sqrt(0.5)                                     # the chamfer is 45 degrees
	var n_front := Vector2(0.0, 1.0)                       # front face, outward
	var d_cham := Vector2(-h, -h)                          # along the chamfer
	var n_cham := Vector2(-h, h)                           # chamfer, outward
	var bis: Vector2 = (n_front + n_cham).normalized()
	var out: float = t / cos(deg_to_rad(22.5))
	return PackedVector2Array([
		d_cham * cham_len + n_cham * t,        # outer, far end of the chamfer leg
		bis * out,                             # outer, through the fold
		Vector2(front_len, 0.0) + n_front * t, # outer, far end of the front leg
		Vector2(front_len, 0.0),               # inner, against the shell
		Vector2.ZERO,                          # inner, the fold itself
		d_cham * cham_len,                     # inner, far end of the chamfer leg
	])


## Extrude `xz` by +/- `half` along Y when `up_axis_y`, else along Z.
##
## `sec` must run the same way round as the shell's own cross-section; the far cap is
## emitted reversed. The sides are independent quads so every face gets a flat normal
## of its own rather than one averaged round the corner.
func _solid(sec: PackedVector2Array, half: float, up_axis_y: bool) -> ArrayMesh:
	var tris := _emit(sec, half, up_axis_y)
	var mesh := _build(tris)
	# MEASURED against the normals Godot itself shades and culls with, not against a
	# right-hand-rule cross product — those disagree, which is the whole trap. Enclose
	# the solid using the STORED normals: positive means they point outward and the
	# faces are front-facing from outside. Negative and the shell renders as a
	# convincing object you can see straight through, which is how one shipped twice.
	if _enclosed(mesh) < 0.0:
		var flipped: Array[Vector3] = []
		for i in range(0, tris.size(), 3):
			flipped.append(tris[i])
			flipped.append(tris[i + 2])
			flipped.append(tris[i + 1])
		mesh = _build(flipped)
	return mesh


func _build(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# -1 is the FLAT smooth group. Without it generate_normals() averages every face
	# meeting at a shared position, and a prism's corners are shared by three: the
	# top cap came back with a normal of (0.66, -0.73, -0.17) instead of straight up,
	# and the whole shell shaded as if it were a lump.
	st.set_smooth_group(-1)
	for v in tris:
		st.add_vertex(v)
	st.generate_normals()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	return mesh


## Volume enclosed by the surface as its STORED normals describe it: (1/3) of the sum
## of centroid . normal x area. Positive when those normals face out. Independent of
## where the origin sits, unlike any "does this point away from the middle" test.
static func _enclosed(mesh: ArrayMesh) -> float:
	var arr := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var total := 0.0
	for i in range(0, v.size(), 3):
		var c: Vector3 = (v[i] + v[i + 1] + v[i + 2]) / 3.0
		var area: float = (v[i + 1] - v[i]).cross(v[i + 2] - v[i]).length() * 0.5
		total += c.dot(n[i]) * area
	return total / 3.0


## Caps plus sides, as a flat list of triangle corners.
##
## The cross-section is normalised to anticlockwise FIRST, and that is not tidiness:
## Geometry2D.triangulate_polygon returns triangles in the polygon's own winding while
## the side quads below are built from the point order directly, so the two only agree
## if the polygon has a known orientation. Fed a clockwise one they came out opposed —
## the caps facing in while the sides faced out — which no amount of flipping the whole
## solid can correct, and which showed up as a shell exactly a third of its own volume.
func _emit(sec_in: PackedVector2Array, half: float, up_axis_y: bool) -> Array[Vector3]:
	var area := 0.0
	for i in sec_in.size():
		var a: Vector2 = sec_in[i]
		var b: Vector2 = sec_in[(i + 1) % sec_in.size()]
		area += a.x * b.y - b.x * a.y
	var sec := sec_in
	if area < 0.0:
		sec = PackedVector2Array()
		for i in range(sec_in.size() - 1, -1, -1):
			sec.append(sec_in[i])
	var out: Array[Vector3] = []
	# Triangulated, not fanned: a key's cross-section is an L and a fan from one
	# vertex would lay triangles outside it.
	var idx := Geometry2D.triangulate_polygon(sec)
	for i in range(0, idx.size(), 3):
		out.append_array([_at(sec[idx[i]], half, up_axis_y),
			_at(sec[idx[i + 1]], half, up_axis_y), _at(sec[idx[i + 2]], half, up_axis_y)])
		out.append_array([_at(sec[idx[i]], -half, up_axis_y),
			_at(sec[idx[i + 2]], -half, up_axis_y), _at(sec[idx[i + 1]], -half, up_axis_y)])
	# One quad per edge, emitted independently so every face gets a flat normal of
	# its own rather than one averaged round the corner.
	for i in sec.size():
		var a: Vector2 = sec[i]
		var b: Vector2 = sec[(i + 1) % sec.size()]
		out.append_array([_at(a, -half, up_axis_y), _at(b, -half, up_axis_y),
			_at(b, half, up_axis_y)])
		out.append_array([_at(a, -half, up_axis_y), _at(b, half, up_axis_y),
			_at(a, half, up_axis_y)])
	return out


## Signed volume of a closed triangle soup. Positive when the winding faces outward,
## and independent of where the origin sits — which a "does this normal point away
## from the middle" test is not, since duplicated cap vertices drag that middle off.
static func _volume(tris: Array[Vector3]) -> float:
	var v := 0.0
	for i in range(0, tris.size(), 3):
		v += tris[i].dot(tris[i + 1].cross(tris[i + 2])) / 6.0
	return v


func _save(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var vol := _enclosed(mesh)
	print("[gen] %-40s err=%d  %.4f x %.4f x %.4f m  vol %+.8f %s" % [path, err,
		ab.size.x, ab.size.y, ab.size.z, vol, "" if vol > 0.0 else "  <-- INSIDE OUT"])


static func _at(p: Vector2, d: float, up_axis_y: bool) -> Vector3:
	return Vector3(p.x, d, p.y) if up_axis_y else Vector3(p.x, p.y, d)
