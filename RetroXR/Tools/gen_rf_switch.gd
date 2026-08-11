## Bakes the RXR-003 RF Switch's shell to
## Scenes/Objects/rf_switch_body.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen_rf_switch.gd
##
## 90 x 20 x 50 mm of moulded grey plastic — X wide, Y tall, Z deep, sitting flat
## with its origin at the centre so the pickable's collision box needs no offset.
##
## Two half shells, so there is a PARTING LINE round the middle and it is worth the
## four extra rings: without it a rounded box of one colour reads as a soap bar, and
## the seam is most of what says "moulded case" at arm's length. Same reason the top
## and bottom edges are filleted rather than square.
##
## The lettering is NOT baked. rf_switch.tscn hangs Label3Ds on the top face — the
## AvLegend precedent — rather than embossing TextMesh glyphs into this mesh, so the
## bake has no font dependency (the project has no bundled face, only a SystemFont
## naming Consolas, and a machine without it would silently bake different glyphs).
##
## Matte, not plastic(): the clearcoat lobe in PlugMats.plastic reads as a WET
## surface at any roughness, and this case is a dry, slightly textured grey. Same
## call the Wii's hood makes, and for the same reason.
##
## Built by lofting one rounded-rectangle outline through a stack of Y levels, each
## with its own inset — the box equivalent of the lathe the connector generators use,
## and the winding rule is carried over unchanged: stepping to a HIGHER level faces
## outward, and a constant-Y step faces +Y when the outline shrinks. The outline is
## traced in the order the lathe's angle would sweep it, mapped axis Z -> Y by
## Rx(-90), so (x, y, z) = (cos a * rx, level, -sin a * rz). Get that mapping wrong
## and the whole box renders inside out.
extends SceneTree

const PlugMats := preload("res://Tools/plug_materials.gd")

const OUT_PATH := "res://Scenes/Objects/rf_switch_body.res"

const HX := 0.045               # 90 mm wide
const HY := 0.010               # 20 mm tall
const HZ := 0.025               # 50 mm deep
const CORNER_R := 0.004
const CORNER_SEG := 4           # samples per corner; 4 reads round at 4 mm

# (y, inset). The pair either side of y = 0 is the parting groove; the 1.6 mm
# insets top and bottom are the edge fillets.
const LEVELS := [
	[-0.0100, 0.0016],
	[-0.0084, 0.0000],
	[-0.0007, 0.0000],
	[-0.0003, 0.0004],
	[ 0.0003, 0.0004],
	[ 0.0007, 0.0000],
	[ 0.0084, 0.0000],
	[ 0.0100, 0.0016],
]


func _init() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array = []
	for lv: Array in LEVELS:
		rings.append(_outline(float(lv[0]), float(lv[1])))

	# Walls.
	for i in range(rings.size() - 1):
		_loft(st, rings[i], rings[i + 1])

	# Caps. A constant-Y step whose outline shrinks to the centre faces +Y, which
	# is the same rule _lathe states for a radius collapsing to the axis.
	_cap(st, rings[0], -HY, false)
	_cap(st, rings[rings.size() - 1], HY, true)

	st.generate_normals()
	# Mid warm grey. Read off the reference photos and then taken DOWN a long way:
	# albedo is reflectance, not the pixel value the camera saw, and the first pass
	# at 0.52 rendered as near-white plastic under ordinary room light.
	var mat := PlugMats.matte(Color(0.33, 0.31, 0.34), 0.85)
	st.set_material(mat)

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, mat)

	var err := ResourceSaver.save(mesh, OUT_PATH)
	var ab: AABB = mesh.get_aabb()
	var tris: int = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3
	print("[gen] %s err=%d  %.4f x %.4f x %.4f m  tris %d" % [
		OUT_PATH, err, ab.size.x, ab.size.y, ab.size.z, tris])
	quit()


## One closed rounded-rectangle ring at height `y`, brought in by `inset`.
##
## Traced corner by corner in the order the lathe's angle sweeps: starting on the
## +X edge and turning toward -Z, so the loft below inherits the lathe's facing
## rule verbatim.
func _outline(y: float, inset: float) -> PackedVector3Array:
	var hx: float = HX - inset
	var hz: float = HZ - inset
	var r: float = minf(CORNER_R, minf(hx, hz))
	var cx: float = hx - r
	var cz: float = hz - r
	var centres := [
		Vector2(cx, -cz),       # +X -Z
		Vector2(-cx, -cz),      # -X -Z
		Vector2(-cx, cz),       # -X +Z
		Vector2(cx, cz),        # +X +Z
	]
	var out := PackedVector3Array()
	for k in 4:
		var c: Vector2 = centres[k]
		for s in range(CORNER_SEG + 1):
			# The last sample of one corner is the first of the next, so skip it
			# rather than emit a zero-width quad column.
			if s == CORNER_SEG:
				continue
			var a: float = deg_to_rad(float(k) * 90.0 + float(s) * 90.0 / float(CORNER_SEG))
			out.append(Vector3(c.x + cos(a) * r, y, c.y - sin(a) * r))
	return out


## Wall band between two rings. `lo` is the lower level; emitting
## (lo_j, hi_j, hi_j1) then (lo_j, hi_j1, lo_j1) faces outward, which is _lathe's
## (p00, p01, p11) / (p00, p11, p10) with the angle index second.
func _loft(st: SurfaceTool, lo: PackedVector3Array, hi: PackedVector3Array) -> void:
	var n := lo.size()
	for j in n:
		var j1 := (j + 1) % n
		st.add_vertex(lo[j]); st.add_vertex(hi[j]); st.add_vertex(hi[j1])
		st.add_vertex(lo[j]); st.add_vertex(hi[j1]); st.add_vertex(lo[j1])


## Close a ring onto its own centre. `up` caps the top (faces +Y); otherwise the
## bottom (faces -Y).
func _cap(st: SurfaceTool, ring: PackedVector3Array, y: float, up: bool) -> void:
	var centre := Vector3(0.0, y, 0.0)
	var n := ring.size()
	for j in n:
		var j1 := (j + 1) % n
		if up:
			st.add_vertex(ring[j]); st.add_vertex(centre); st.add_vertex(ring[j1])
		else:
			st.add_vertex(centre); st.add_vertex(ring[j]); st.add_vertex(ring[j1])
