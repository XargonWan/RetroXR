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
	_build_seam()
	_build_gate()
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
	_save(_smooth(tris), "res://Scenes/Objects/controllers/wii/nunchuk_body.res")


## The moulding seam, which runs the whole length of both flanks where the two shell
## halves meet. Visible in every reference photograph and, at this scale, most of what
## says the thing is moulded plastic rather than turned from one piece.
##
## Drawn as a narrow ribbon rather than cut into the shell: the loft is a closed solid
## and a real groove would mean splitting every ring. The ribbon rides the widest line
## on each flank — where the seam actually falls, since that IS the parting line a
## two-part mould leaves — and stands 0.15 mm out so it cannot z-fight the shell.
func _build_seam() -> void:
	var tris: Array[Vector3] = []
	for side in [1.0, -1.0]:
		var prev: Array = []
		for r in RINGS + 1:
			var t := float(r) / float(RINGS)
			var a_mid := _seam_angle(t, side)
			# Skip the poles: the ring collapses there and the ribbon would pinch to
			# nothing across a face it no longer has room to sit on.
			if t < 0.04 or t > 0.965:
				prev = []
				continue
			var lo := _ring_at(t, a_mid - SEAM_HALF_ANGLE, side)
			var hi := _ring_at(t, a_mid + SEAM_HALF_ANGLE, side)
			if not prev.is_empty():
				tris.append_array([prev[0], prev[1], lo])
				tris.append_array([prev[1], hi, lo])
			prev = [lo, hi]
	# A ribbon is a sheet, not a solid, so _smooth's orientation check would read its
	# enclosed volume as meaningless. Emitted double-sided in the material instead.
	_save_sheet(_smooth_sheet(tris), "res://Scenes/Objects/controllers/wii/nunchuk_seam.res")


## How wide the seam ribbon is, as a half-angle round the ring. About 3 degrees, which
## comes out near 0.5 mm on the widest part of the body.
const SEAM_HALF_ANGLE := 0.055
## How far the ribbon stands off the shell, along the flank's outward normal (+/-X at
## the seam line, near enough).
##
## 0.35 mm, not the 0.15 it started at, and the difference is the shell's TESSELLATION
## rather than the surface. The ribbon is computed on the analytic surface, but the
## body is a 28-sided approximation to it, and mid-facet the chord cuts up to
## 0.12 mm inside — so at 0.15 the far flank's ribbon surfaced through the shell in
## flecks wherever a facet dipped under it. Clearing the chord error is what matters
## here, not clearing the surface.
const SEAM_STANDOFF := 0.00035


## Where round the ring the parting line falls, at station `t`.
##
## NOT simply the widest point in X. The ring's widest X is at z = 0 by construction,
## and z = 0 is not its mid-depth — the front and back reaches differ, so the ring's
## centre sits at (db - df)/2. A seam pinned to the widest point therefore comes out
## dead straight down the side view while the body curves around it, which is exactly
## what the first cut looked like and exactly what the reference does not.
##
## So the angle is solved for instead: the c where the ring's own z reaches its
## mid-depth, from ds*c^2 + dm*c - ds = 0. The seam then follows the flank the way a
## mould's parting line follows the body it splits.
static func _seam_angle(t: float, side: float) -> float:
	var df := _sample(t, 2)
	var db := _sample(t, 3)
	var dm := (db + df) * 0.5
	var ds := (db - df) * 0.5
	var c := 0.0
	if absf(ds) > 1e-6 and dm > 1e-6:
		c = clampf((-dm + sqrt(dm * dm + 4.0 * ds * ds)) / (2.0 * ds), -1.0, 1.0)
	var a := acos(c)                     # in (0, PI), so sin(a) >= 0 — the +X flank
	return a if side > 0.0 else TAU - a


## One point on the body's surface at station `t` and angle `a`, pushed out along the
## flank so it clears the shell.
func _ring_at(t: float, a: float, side: float) -> Vector3:
	var hx := _sample(t, 1)
	var df := _sample(t, 2)
	var db := _sample(t, 3)
	var y := lerpf(Y_TOP, Y_TIP, t)
	var dm := (db + df) * 0.5
	var ds := (db - df) * 0.5
	var c := cos(a)
	return Vector3(hx * sin(a) + side * SEAM_STANDOFF, y, c * (dm + ds * c))


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

## The OCTAGONAL gate the stick sits in — the stepped well moulded into the crown,
## which the thumbstick overhangs. Unmistakable in a photograph taken straight down
## the stick's axis, and absent from the first cut of this model entirely: the stick
## grew out of a bare dome, which is what made the crown read as unfinished.
##
## A raised collar rather than a recess cut into the shell. The shell is a closed loft
## and cutting a well into it would mean splitting every ring near the crown around an
## octagon; a collar set into the dome gets the same silhouette for a fraction of the
## machinery, and the dome is convex there so nothing floats.
##
## Eight sides, flats top and bottom (phase 22.5 degrees). The reference does not say
## which way the octagon is clocked and this is the reading that looks deliberate.
func _build_gate() -> void:
	var rings: Array = []
	rings.append(_poly(-0.0060, 0.0000))      # buried, closes the bottom
	rings.append(_poly(-0.0060, 0.0112))
	rings.append(_poly(0.0000, 0.0112))       # outer wall, most of it inside the dome
	rings.append(_poly(0.0016, 0.0106))       # chamfer up to the rim
	rings.append(_poly(0.0018, 0.0094))       # rim's inner edge
	rings.append(_poly(-0.0024, 0.0091))      # bore wall dropping away under the cap
	rings.append(_poly(-0.0028, 0.0000))      # bore floor
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_gate.res")


## NOTE — there is no separate dark floor to this bore, and that is a retreat rather
## than a design. One was built (a flat octagonal puck, darkness by MATERIAL, the same
## call gen_rca_jack.gd makes for its socket) and it rendered OVER the stick cap: a
## 17 mm puck measured at world y 0.0455..0.0491 winning the depth test against a cap
## whose top is at 0.0597, under an orthographic camera looking straight down. Proven
## by bisection — hiding that one node made the cap reappear — and not explained. The
## cap was ruled out as the cause: rendered alone against a green field it is solid,
## with no hole for anything to show through.
##
## It is dropped because the cap covers all but a rim of the bore anyway, so the part
## bought almost nothing. If a dark bore is ever wanted here, expect this to recur.


## An eight-sided ring at height `y`. Radius zero makes it a pole.
static func _poly(y: float, r: float) -> Array:
	var out: Array = []
	for s in 8:
		var a := TAU * (float(s) + 0.5) / 8.0
		out.append(Vector3(r * sin(a), y, r * cos(a)))
	return out


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
	rings.append(_disc(0.0130, 0.0082))              # the rim land, the cap's high point
	# The concentric groove. Plainly there in a photograph taken down the stick's
	# axis, and the detail that stops the cap reading as a plain disc: the top is a
	# flat outer land, a turned groove, then a shallow centre inside it.
	rings.append(_disc(0.0124, 0.0076))
	rings.append(_disc(0.0123, 0.0070))
	rings.append(_disc(0.0128, 0.0064))              # inner land climbs back out of it
	rings.append(_disc(0.0126, 0.0044))              # centre, dished a little
	rings.append(_disc(0.0122, 0.0022))
	rings.append(_disc(0.0121, 0.0000))
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_stick.res")


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
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_boot.res")


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
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_c.res")


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
	_save(_smooth(_loft(rings)), "res://Scenes/Objects/controllers/wii/nunchuk_z.res")


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


## Weld and smooth-shade a SHEET. No orientation pass: _orient weighs enclosed volume,
## which is only an oracle for a closed solid — a ribbon encloses nothing and would be
## flipped or not on the strength of a rounding error. The material draws it
## double-sided instead, so which way it faces cannot matter.
func _smooth_sheet(tris: Array[Vector3]) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in tris:
		st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


## …and save it without the closed-solid check, for the same reason.
func _save_sheet(mesh: ArrayMesh, path: String) -> void:
	var err := ResourceSaver.save(mesh, path)
	var ab: AABB = mesh.get_aabb()
	print("[gen] %-44s err=%d  %.4f x %.4f x %.4f m  (sheet)"
		% [path, err, ab.size.x, ab.size.y, ab.size.z])


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
