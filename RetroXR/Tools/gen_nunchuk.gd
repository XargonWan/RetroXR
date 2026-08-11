## Bakes the Wii Nunchuk's shell and its fittings to Scenes/Objects/nunchuk_*.res.
##
##   godot --headless --path RetroXR --script res://Tools/gen_nunchuk.gd
##
## The controller it replaces was a truncated cone with two slabs stuck on it, and
## every wrong thing about that came from one assumption: that the body is a solid of
## revolution. It is not. Read off a side elevation, the Nunchuk is a LOFT — a stack
## of rings whose front and back reach differ, so the silhouette can scoop in on one
## side while sweeping out on the other. A lathe cannot do that at all; the moment
## the front and back of a station disagree, a cone is the wrong tool.
##
## The shape in words, from the reference elevation:
##
##   * a broad rounded crown carrying the stick, tilted forward,
##   * a deep concave SCOOP down the front face just below the buttons, where the
##     index finger sits — the feature that makes the thing read as a Nunchuk rather
##     than as a handle,
##   * a belly that swells back out into the palm, widest around 45% down,
##   * a long taper to a blunt rounded tail, with the cord leaving dead centre and
##     straight out along the tail's own axis.
##
## The rings interpolate through _PROFILE with a Catmull-Rom, so the table is a dozen
## control stations rather than forty hand-written ones and the surface between them
## is smooth by construction. Each station gives a half-width across X and a SEPARATE
## front and back reach along Z; the ring blends between them as
##
##     z = c * (dm + ds * c)      c = cos(angle), dm = (db+df)/2, ds = (db-df)/2
##
## which hits +db at the back, -df at the front, and passes through zero at the sides
## with a continuous tangent. Taking the front or back radius by a branch on the sign
## of cos — the obvious way — creases the shell down both flanks instead.
##
## Winding is checked the way gen_wii_body.gd checks it: by enclosed volume, on the
## finished solid. An inside-out shell renders as a convincing object you can see
## straight through.
extends SceneTree

# The shell runs 105 mm from crown to tail tip. The real one is ~113 mm including
# the stick, which stands proud of the crown here.
const Y_TOP := 0.052
const Y_TIP := -0.053

## Where the buttons and the boot go, as fractions along the body. Printed with their
## resolved surface positions at the end of a run, because nunchuk.tscn authors those
## by hand and guessing at them is what floated the old slabs off the shell.
## Far enough apart that the 20 mm Z blade clears the 11.4 mm C key: 15.7 mm between
## their centres against 8.2 + 5.7 mm of half-lengths measured up the shelf. On the
## real thing they very nearly touch, and at 0.135 / 0.235 they overlapped outright.
const T_C := 0.11
const T_Z := 0.26

const RINGS := 40
const SEGS := 28

## Control stations: t down the body, half-width across X, then the FRONT and BACK
## reach along Z as positive magnitudes. Front is -Z, the face the buttons live on.
##
## t = 0 and t = 1 are poles and must stay zero — the loft closes on them rather than
## capping, which is what keeps the crown and the tail rounded instead of cut off.
const _PROFILE := [
	# t,     hx,      front,   back
	[0.00,   0.0000,  0.0000,  0.0000],
	[0.02,   0.0092,  0.0098,  0.0106],
	[0.06,   0.0144,  0.0152,  0.0172],
	[0.12,   0.0173,  0.0178,  0.0203],
	[0.20,   0.0185,  0.0166,  0.0219],
	[0.28,   0.0190,  0.0139,  0.0230],
	[0.36,   0.0190,  0.0127,  0.0233],
	[0.45,   0.0184,  0.0127,  0.0225],
	[0.55,   0.0172,  0.0130,  0.0206],
	[0.65,   0.0157,  0.0130,  0.0184],
	[0.75,   0.0141,  0.0126,  0.0160],
	[0.84,   0.0121,  0.0116,  0.0135],
	[0.91,   0.0099,  0.0099,  0.0109],
	[0.96,   0.0069,  0.0073,  0.0077],
	[1.00,   0.0000,  0.0000,  0.0000],
]


func _init() -> void:
	_build_body()
	_build_stick()
	_build_boot()
	_build_c()
	_build_z()
	_report_seats()
	quit()


# ── The shell ────────────────────────────────────────────────────────────────

func _build_body() -> void:
	var rings: Array = []
	for r in RINGS + 1:
		var t := float(r) / float(RINGS)
		rings.append(_ring(t))
	var tris := _loft(rings)
	_save(_smooth(tris), "res://Scenes/Objects/nunchuk_body.res")


## One ring of the loft, in the object's own frame.
func _ring(t: float) -> Array:
	var hx := _sample(t, 1)
	var df := _sample(t, 2)
	var db := _sample(t, 3)
	var y := lerpf(Y_TOP, Y_TIP, t)
	var dm := (db + df) * 0.5
	var ds := (db - df) * 0.5
	var out: Array = []
	for s in SEGS:
		var a := TAU * float(s) / float(SEGS)
		var c := cos(a)
		out.append(Vector3(hx * sin(a), y, c * (dm + ds * c)))
	return out


## Catmull-Rom through the control stations, on column `col`. Clamped at both ends so
## the poles stay exactly zero — an overshooting spline there turns the crown inside
## out, and it does it subtly enough to survive a head-on render.
static func _sample(t: float, col: int) -> float:
	var n := _PROFILE.size()
	var i := 0
	while i < n - 2 and float(_PROFILE[i + 1][0]) < t:
		i += 1
	var p1: Array = _PROFILE[i]
	var p2: Array = _PROFILE[i + 1]
	var p0: Array = _PROFILE[maxi(i - 1, 0)]
	var p3: Array = _PROFILE[mini(i + 2, n - 1)]
	var span := float(p2[0]) - float(p1[0])
	var u := 0.0 if span <= 0.0 else clampf((t - float(p1[0])) / span, 0.0, 1.0)
	var v := _catmull(float(p0[col]), float(p1[col]), float(p2[col]), float(p3[col]), u)
	return maxf(v, 0.0)


static func _catmull(a: float, b: float, c: float, d: float, u: float) -> float:
	var u2 := u * u
	var u3 := u2 * u
	return 0.5 * ((2.0 * b) + (-a + c) * u + (2.0 * a - 5.0 * b + 4.0 * c - d) * u2
		+ (-a + 3.0 * b - 3.0 * c + d) * u3)


## Stitch a stack of rings into a closed solid. The first and last rings are poles —
## every vertex identical — so they fan instead of stitching, and the ends come out
## rounded rather than capped.
static func _loft(rings: Array) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for r in range(rings.size() - 1):
		var lo: Array = rings[r]
		var hi: Array = rings[r + 1]
		for s in lo.size():
			var s2 := (s + 1) % lo.size()
			var a: Vector3 = lo[s]
			var b: Vector3 = lo[s2]
			var c: Vector3 = hi[s]
			var d: Vector3 = hi[s2]
			# A pole ring collapses one side of the quad; emitting the degenerate
			# triangle anyway would leave a zero-area face for generate_normals to
			# average in, which dimples the crown.
			if a.is_equal_approx(b):
				out.append_array([a, d, c])
			elif c.is_equal_approx(d):
				out.append_array([a, b, c])
			else:
				out.append_array([a, b, c])
				out.append_array([b, d, c])
	return out


# ── Fittings ─────────────────────────────────────────────────────────────────

## The stick: a waisted stalk under a dished cap. The cap's top is CONCAVE — a thumb
## sits in it — and the rim stands slightly proud of the dish, which is the reading
## that separates it from a plain disc at a glance.
func _build_stick() -> void:
	var rings: Array = []
	rings.append(_disc(0.0, 0.0))                    # pole under the stalk
	rings.append(_disc(0.0, 0.0062))
	rings.append(_disc(0.0020, 0.0059))
	rings.append(_disc(0.0044, 0.0051))              # the waist
	rings.append(_disc(0.0060, 0.0057))
	rings.append(_disc(0.0072, 0.0074))              # cap flares out
	rings.append(_disc(0.0084, 0.0088))
	rings.append(_disc(0.0098, 0.0094))              # rim, the widest point
	rings.append(_disc(0.0114, 0.0095))
	rings.append(_disc(0.0126, 0.0090))              # rim rolls over
	rings.append(_disc(0.0130, 0.0080))
	rings.append(_disc(0.0124, 0.0068))              # dish falls away inside the rim
	rings.append(_disc(0.0118, 0.0045))
	rings.append(_disc(0.0114, 0.0022))
	rings.append(_disc(0.0113, 0.0000))              # centre of the dish
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/nunchuk_stick.res")


## The ribbed strain relief. Four ribs on a taper, so the cord reads as moulded into
## the tail rather than butted onto it.
func _build_boot() -> void:
	var rings: Array = []
	# Capped, even though this end is buried in the tail: an open ring leaves a hole
	# that the enclosed-volume check cannot see past, so it would report a shell with
	# a missing face as sound.
	rings.append(_disc(0.0, 0.0))
	rings.append(_disc(0.0, 0.0052))
	var ribs := 4
	for i in ribs:
		var f := float(i) / float(ribs)
		var base := lerpf(0.0052, 0.0031, f)
		var y := -0.0022 - 0.0036 * float(i)
		# 1.14, not 1.28. The ribs stood 9.2 mm out of an 8 mm tail at the larger
		# figure, which stepped OUT past the shell and read as a threaded bolt rather
		# than as moulded rubber.
		rings.append(_disc(y + 0.0010, base * 1.14))
		rings.append(_disc(y - 0.0010, base * 1.14))
		rings.append(_disc(y - 0.0014, base))
	rings.append(_disc(-0.0164, 0.0026))
	rings.append(_disc(-0.0170, 0.0000))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/nunchuk_boot.res")


## C: a small round key, domed, standing 3 mm off its shelf.
func _build_c() -> void:
	var rings: Array = []
	rings.append(_disc(0.0, 0.0))
	rings.append(_disc(0.0, 0.0057))
	rings.append(_disc(0.0016, 0.0057))
	rings.append(_disc(0.0024, 0.0053))
	rings.append(_disc(0.0029, 0.0042))
	rings.append(_disc(0.0032, 0.0023))
	rings.append(_disc(0.0033, 0.0000))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/nunchuk_c.res")


## Z: the trigger, a rounded oblong 14 x 20 mm standing 4.5 mm off its shelf.
##
## Lofted as a stack of shrinking superellipses with a pole at each end, so it comes
## out a domed slab with soft edges and no open face. The first cut raked its two ends
## by different amounts, on the reasoning that a finger pulls ACROSS the trigger — but
## raking a ring that is also shrinking twists the loft, and it rendered as a pair of
## fins rather than a key. The rake belongs to the SEAT, which nunchuk.tscn already
## applies to the whole button.
func _build_z() -> void:
	var hx := 0.0070          # half width across X
	var hz := 0.0100          # half length along the shelf
	var rings: Array = []
	rings.append(_oblong(0.0, 0.0, 0.0))
	rings.append(_oblong(hx, hz, 0.0))
	rings.append(_oblong(hx, hz, 0.0026))
	rings.append(_oblong(hx * 0.95, hz * 0.97, 0.0036))
	rings.append(_oblong(hx * 0.84, hz * 0.90, 0.0043))
	rings.append(_oblong(hx * 0.55, hz * 0.66, 0.0047))
	rings.append(_oblong(0.0, 0.0, 0.0048))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/nunchuk_z.res")


## A rounded-rectangle ring in the XZ plane at height `y`. A superellipse rather than
## an ellipse: squarer down the flanks, still rounded at the corners, which is what a
## moulded key looks like. Both radii zero makes it a pole.
static func _oblong(hx: float, hz: float, y: float) -> Array:
	var out: Array = []
	var p := 2.6
	for s in SEGS:
		var a := TAU * float(s) / float(SEGS)
		var sx := sin(a)
		var cz := cos(a)
		var kx: float = signf(sx) * pow(absf(sx), 2.0 / p)
		var kz: float = signf(cz) * pow(absf(cz), 2.0 / p)
		out.append(Vector3(hx * kx, y, hz * kz))
	return out


# ── Helpers ──────────────────────────────────────────────────────────────────

## A horizontal ring of radius `r` at height `y`. Radius zero makes it a pole.
static func _disc(y: float, r: float) -> Array:
	var out: Array = []
	for s in SEGS:
		var a := TAU * float(s) / float(SEGS)
		out.append(Vector3(r * sin(a), y, r * cos(a)))
	return out


## Weld, smooth-shade and pack a triangle soup. Indexing FIRST is what makes
## generate_normals average across the seams instead of faceting every quad.
func _smooth(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in _orient(tris):
		st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


## Turn a solid the right way out if it came out inside in.
##
## Which way a loft winds depends on which way its rings TRAVEL, and the five solids
## here do not agree: the shell and the boot are stacked downward from the crown and
## the tail, the stick and the keys upward from their seats. Wound by hand that is a
## sign to get wrong in three places out of five — it was, first run — so nothing here
## reasons about it. The soup is weighed and flipped whole if it encloses a negative
## volume, and _save then re-weighs the committed mesh as a genuine assertion.
static func _orient(tris: Array[Vector3]) -> Array[Vector3]:
	if _volume(tris) >= 0.0:
		return tris
	var out: Array[Vector3] = []
	for i in range(0, tris.size(), 3):
		out.append_array([tris[i], tris[i + 2], tris[i + 1]])
	return out


## Signed volume of a closed triangle soup. Independent of where the origin sits,
## which a "does this normal point away from the middle" test is not.
static func _volume(tris: Array[Vector3]) -> float:
	var v := 0.0
	for i in range(0, tris.size(), 3):
		v += tris[i].dot(tris[i + 1].cross(tris[i + 2])) / 6.0
	return v


func _save(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	var vol := _enclosed(mesh)
	print("[gen] %-44s err=%d  %.4f x %.4f x %.4f m  vol %+.9f %s" % [path, err,
		ab.size.x, ab.size.y, ab.size.z, vol, "" if vol > 0.0 else "  <-- INSIDE OUT"])


## Signed volume of the committed solid, read back from its own stored arrays.
static func _enclosed(mesh: ArrayMesh) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var v := 0.0
	for i in range(0, idx.size(), 3):
		v += verts[idx[i]].dot(verts[idx[i + 1]].cross(verts[idx[i + 2]])) / 6.0
	return v


## Where the shell's surface actually is at the stations nunchuk.tscn has to author
## by hand. The old model floated its buttons because these were guessed.
func _report_seats() -> void:
	for row: Array in [["C", T_C], ["Z", T_Z]]:
		var t: float = row[1]
		var y := lerpf(Y_TOP, Y_TIP, t)
		var front := _sample(t, 2)
		print("[gen] seat %s  t=%.3f  y=%+.4f  front z=%.4f" % [row[0], t, y, -front])
	print("[gen] crown y=%+.4f   tail tip y=%+.4f" % [Y_TOP, Y_TIP])
