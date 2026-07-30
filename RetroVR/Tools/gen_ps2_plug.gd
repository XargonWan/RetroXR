## Bakes to-scale PS/2 (mini-DIN 6) plugs to Scenes/Objects/ps2_plug_*.res.
##
## Run once, out of band — a connector's dimensions are a physical fact, not
## something to rebuild every load:
##
##   godot --headless --path RetroVR --script res://Tools/gen_ps2_plug.gd
##
## Replaces the generic cylinder plug on the keyboard and mouse, which was a
## 20 mm-diameter, 40 mm-long cone — twice the diameter of a real PS/2 connector
## and four times the shroud length. At arm's length in VR that reads as a garden
## hose rather than a keyboard lead.
##
## Dimensions are the mini-DIN 6 spec:
##   * metal shroud 9.5 mm outside diameter, 9.5 mm long, 0.4 mm wall
##   * 6 pins at 0.9 mm diameter, 7 mm long, recessed inside the shroud
##   * a plastic alignment key against the shroud's inner wall, which is what stops
##     the plug going in the wrong way round
##   * a 13 mm plastic barrel behind, 22 mm long, tapering to a strain relief
##
## PIN LAYOUT and KEY follow the mini-DIN 6 pinout drawing. The six pins ring a
## rectangular plastic key that stands in the CENTRE of the bore — 5 and 6 above
## it, 3 and 4 out at the sides, 1 and 2 below:
##
##       6   5
##     4  |K|  3
##       2   1
##
## Two earlier passes had this wrong: pins fanned evenly across the top arc, and
## the key laid flat against the inner wall like a DIN notch. On the real part the
## key is central and stands tall, and it is what the pins are arranged around.
##
## Numbering is the FEMALE socket's, so a male plug mirrors it left-to-right. The
## mirror is invisible here — every pin is the same brass cylinder — but it would
## matter if anything were ever labelled.
##
## Two colourways, per PC99 (1999, so period-legal for this room): purple for the
## keyboard, green for the mouse. That colour coding is also the only thing that
## tells the two leads apart at a glance once both are plugged in.
##
## Authored in the plug's own frame — connector on +Z, cable trailing -Z — which is
## the contract ControllerPlug.set_plug_mesh expects, so it needs no transform.
##
## Winding matters here: nothing is a primitive, and SurfaceTool.generate_normals()
## derives facing from vertex order alone. Godot's convention is the one Plane(a,b,c)
## uses — normal = (a-c).cross(a-b) — so every helper below emits in that order and
## the caps, rim and box faces each had to be checked against it individually.
extends SceneTree

const PlugMats := preload("res://Tools/plug_materials.gd")

const OUT_DIR := "res://Scenes/Objects/"

const SHROUD_OD := 0.0095
const SHROUD_WALL := 0.0004
const SHROUD_LEN := 0.0095
const PIN_DIA := 0.0009
const PIN_LEN := 0.007
const BARREL_DIA := 0.013
const BARREL_LEN := 0.022
const RELIEF_LEN := 0.012
## Just proud of the 4.5 mm cord controller_cable.tscn draws, which is also what a
## real PS/2 lead measures — so this is both the true dimension and a clean meeting
## with the rope.
const RELIEF_DIA := 0.005
## Central key: tall and narrow, standing in the middle of the bore.
const KEY_W := 0.0013
const KEY_H := 0.0033

## Pin centres in the connector face, metres, in PS/2 numbering order.
##
## Clearances, all checked against a 4.35 mm bore wall and the central key's
## 0.65 x 1.65 mm half-extents, with a 0.45 mm pin radius: the outermost pins
## (3, 4) reach 3.21 mm from the axis, and the nearest pin edge to the key is
## 0.15 mm clear of it.
const PIN_XY: Array[Vector2] = [
	Vector2( 0.00125, -0.00185),   # 1  +DATA   below, right
	Vector2(-0.00125, -0.00185),   # 2  n/c     below, left
	Vector2( 0.00270,  0.00056),   # 3  GND     side, right
	Vector2(-0.00270,  0.00056),   # 4  Vcc     side, left
	Vector2( 0.00136,  0.00218),   # 5  +CLK    above, right
	Vector2(-0.00136,  0.00218),   # 6  n/c     above, left
]

const RING := 16          # radial segments; these are ~1 cm parts, 16 is plenty


func _init() -> void:
	_build("ps2_plug_keyboard.res", Color(0.42, 0.24, 0.58))   # PC99 purple
	_build("ps2_plug_mouse.res", Color(0.24, 0.52, 0.30))      # PC99 green
	quit()


func _build(file_name: String, barrel_tint: Color) -> void:
	var mesh := ArrayMesh.new()
	var r_out := SHROUD_OD * 0.5
	var r_in := r_out - SHROUD_WALL

	# --- surface 0: plastic barrel, strain relief, alignment key -------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# The shroud occupies z 0..SHROUD_LEN, so the barrel runs from 0 back to
	# -BARREL_LEN and the relief tapers back from there to the cable.
	_tube(st, BARREL_DIA * 0.5, BARREL_DIA * 0.5, -BARREL_LEN, 0.0, true)
	_tube(st, RELIEF_DIA * 0.5, BARREL_DIA * 0.5, -BARREL_LEN - RELIEF_LEN, -BARREL_LEN, true)
	# Key stands in the CENTRE of the bore, tall and narrow, with the pins ringing
	# it. Not a notch in the wall.
	_box(st, KEY_W, KEY_H, SHROUD_LEN * 0.62,
		Vector3(0.0, 0.0, SHROUD_LEN * 0.31))
	st.generate_normals()
	var m_barrel := PlugMats.plastic(barrel_tint)
	st.set_material(m_barrel)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(0, m_barrel)

	# --- surface 1: metal shroud --------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tube(st, r_out, r_out, 0.0, SHROUD_LEN, false)      # outside wall
	_tube(st, r_in, r_in, SHROUD_LEN, 0.0, false)        # inside wall, wound inward
	_annulus(st, r_in, r_out, SHROUD_LEN)                # rim at the open end
	st.generate_normals()
	var m_metal := PlugMats.chrome()
	st.set_material(m_metal)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(1, m_metal)

	# --- surface 2: pins -----------------------------------------------------
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for xy in PIN_XY:
		_tube(st, PIN_DIA * 0.5, PIN_DIA * 0.5, 0.0, PIN_LEN, true,
			Vector3(xy.x, xy.y, 0.0))
	st.generate_normals()
	var m_pin := PlugMats.brass()
	st.set_material(m_pin)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())
	mesh.surface_set_material(2, m_pin)

	var path := OUT_DIR + file_name
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	print("[gen] %s  err=%d  size %.4f x %.4f x %.4f m  z %.4f..%.4f" % [
		path, err, ab.size.x, ab.size.y, ab.size.z, ab.position.z, ab.end.z])


## Tube along +Z between z0 and z1, radius r0 at z0 tapering to r1 at z1.
## Wound so the outside faces out when z1 > z0 — pass them reversed for a bore.
func _tube(st: SurfaceTool, r0: float, r1: float, z0: float, z1: float,
		capped: bool, offset := Vector3.ZERO) -> void:
	for i in RING:
		var a0: float = TAU * float(i) / float(RING)
		var a1: float = TAU * float(i + 1) / float(RING)
		var p00 := offset + Vector3(cos(a0) * r0, sin(a0) * r0, z0)
		var p10 := offset + Vector3(cos(a1) * r0, sin(a1) * r0, z0)
		var p01 := offset + Vector3(cos(a0) * r1, sin(a0) * r1, z1)
		var p11 := offset + Vector3(cos(a1) * r1, sin(a1) * r1, z1)
		st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
		st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
		if capped:
			var c0 := offset + Vector3(0, 0, z0)
			var c1 := offset + Vector3(0, 0, z1)
			st.add_vertex(c0); st.add_vertex(p00); st.add_vertex(p10)
			st.add_vertex(c1); st.add_vertex(p11); st.add_vertex(p01)


## Flat ring at z facing +Z, from r_in to r_out — the shroud's front rim.
func _annulus(st: SurfaceTool, r_in: float, r_out: float, z: float) -> void:
	for i in RING:
		var a0: float = TAU * float(i) / float(RING)
		var a1: float = TAU * float(i + 1) / float(RING)
		var i0 := Vector3(cos(a0) * r_in, sin(a0) * r_in, z)
		var i1 := Vector3(cos(a1) * r_in, sin(a1) * r_in, z)
		var o0 := Vector3(cos(a0) * r_out, sin(a0) * r_out, z)
		var o1 := Vector3(cos(a1) * r_out, sin(a1) * r_out, z)
		st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(o0)
		st.add_vertex(i0); st.add_vertex(i1); st.add_vertex(o1)


func _box(st: SurfaceTool, sx: float, sy: float, sz: float, at: Vector3) -> void:
	var h := Vector3(sx, sy, sz) * 0.5
	var v: Array[Vector3] = []
	for i in 8:
		v.append(at + Vector3(
			h.x if (i & 1) else -h.x,
			h.y if (i & 2) else -h.y,
			h.z if (i & 4) else -h.z))
	var faces := [[0,2,3,1], [4,5,7,6], [0,1,5,4], [2,6,7,3], [0,4,6,2], [1,3,7,5]]
	for f in faces:
		st.add_vertex(v[f[0]]); st.add_vertex(v[f[3]]); st.add_vertex(v[f[2]])
		st.add_vertex(v[f[0]]); st.add_vertex(v[f[2]]); st.add_vertex(v[f[1]])
