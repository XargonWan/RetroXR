## PokeTip — a small visible cone on the front of a VR controller whose POINT
## is the canonical near-interaction ("poke") position: touch screens, console
## buttons, keyboard keys, sliders, book corners all test against this tip
## instead of the controller's tracked origin (which sits inside the
## controller body, ~6 cm behind where your finger visually is).
##
## Add as a child named "PokeTip" of each XRController3D (player_rig.tscn).
## Consumers call the static PokeTip.tip_of(ctrl); when the node is missing
## (e.g. desktop hands) it falls back to a computed forward offset, so callers
## never need to care.
##
## CONTACT SNAPPING. A widget under the tip may CLAIM it for the frame
## (set_contact / claim_box_face), and the nib then bends onto that point — the
## cap's top face, the knob, the glass — instead of floating in the air at
## whatever depth the hand happens to be. That is the whole feedback story for
## near interaction: the outline says WHICH widget, the nib says WHERE on it.
##
## The claim moves only the cone and disc CHILDREN. It must never move this node,
## because tip_of() IS this node's origin and every widget projects against it —
## moving it would make a widget project onto a face, the tip follow, the widget
## re-project, and the geometry chase itself. Tools/vr_snap_probe.gd asserts this.
class_name PokeTip
extends Node3D

## How far ahead of the controller origin the tip sits (metres, along -Z aim).
const TIP_FORWARD := 0.06

const CONE_HEIGHT := 0.022
const CONE_RADIUS := 0.007

# ── Contact claims ───────────────────────────────────────────────────────────

## Claim priorities. A widget merely under the tip claims HOVER; the one actually
## driving it claims ENGAGED, which wins — so poking a console's touch screen
## doesn't hand the nib to a power button whose contact box happens to overlap.
const CONTACT_HOVER := 0
const CONTACT_ENGAGED := 10

## Follow rate for the nib, via the house clampf(K * delta, 0, 1) idiom. Smoothing
## happens in THIS node's frame, so hand motion carries the nib rigidly and this
## only shapes snapping on and off — it costs no tracking lag at any value.
const CONTACT_LERP := 18.0
## Seconds a claim survives unrenewed. Sized to ride out a DROPPED TRACKING FRAME
## (~4 at 90 Hz) and nothing more: the widgets' own grace is a tail on how long a
## press lasts, so a generous value here would be felt as sticky buttons.
const CONTACT_GRACE := 0.05
## Lift off the claimed surface, applied once here so every widget gets the same
## clearance and nothing z-fights with the face it is sitting on.
const CONTACT_LIFT := 0.001
## Longest the nib may stretch. Past this it reads as snapped off the hand rather
## than reaching; larger than any engage radius that claims.
const CONTACT_MAX_REACH := 0.045
## Keeps the nib ON a face rather than balanced on its silhouette edge. Under the
## smallest cap that claims (the DS power key, 10 mm).
const FACE_INSET := 0.0015
## Contact shadow on the surface. Under the cone's own base radius so it reads as
## the nib's footprint, not a second object.
const DISC_RADIUS := 0.005

var _pickup: Node = null   # sibling XRToolsFunctionPickup (hide cone while holding)
var _cone: MeshInstance3D = null
var _disc: MeshInstance3D = null
var _disc_mat: StandardMaterial3D = null

# Winning claim for the current frame, plus the smoothed state it drives.
var _claim_point := Vector3.ZERO
var _claim_normal := Vector3.UP
var _claim_priority := -1
var _claim_dist := INF
var _claim_frame := -1
var _hold := 0.0
var _cone_local := Vector3.ZERO   # smoothed contact, in THIS node's frame
var _blend := 0.0                 # 0 free … 1 landed; drives the disc's alpha


## The poke position for a controller: its PokeTip child's origin, or a
## computed forward offset when no PokeTip node exists.
static func tip_of(ctrl: Node3D) -> Vector3:
	var tip := ctrl.get_node_or_null("PokeTip") as Node3D
	if tip:
		return tip.global_position
	return ctrl.global_position - ctrl.global_transform.basis.z * TIP_FORWARD


## True when this controller's poke tip is "live" — the hand is NOT currently
## holding an object (grabbed or ray-grabbed). VRButton/VRSlider skip controllers
## for which this is false, so a hand busy holding a handheld can't trigger a
## nearby widget by bumping it. Desktop hands (no FunctionPickup) always poke.
static func is_poking(ctrl: Node3D) -> bool:
	var pk := ctrl.get_node_or_null("FunctionPickup")
	if pk == null:
		return true
	if is_instance_valid(pk.get("picked_up_object")):
		return false
	if pk.has_method("is_ray_grabbing") and pk.is_ray_grabbing():
		return false
	return true


## Claim this frame's contact point for `ctrl`. Claims are frame-scoped and expire
## on their own, so a widget never has to release one — it simply stops claiming.
## A controller with no PokeTip node (desktop hands) is a silent no-op.
static func set_contact(ctrl: Node3D, world_point: Vector3, world_normal: Vector3,
		priority: int = CONTACT_HOVER) -> void:
	if ctrl == null or not is_poking(ctrl):
		return
	var tip := ctrl.get_node_or_null("PokeTip") as PokeTip
	if tip != null:
		tip._claim(world_point, world_normal, priority)


## Project `tip_pos` onto a face of `mi`'s mesh-local AABB and claim it.
##
## `prefer_world_normal` picks the face — a button passes its cap's outward
## normal, so the nib always lands on the face you press. Vector3.ZERO means
## "whichever face the tip is nearest", which is what a knob grabbable from any
## side wants; that test uses NORMALISED penetration so a long thin knob picks its
## long face rather than the nearer but larger-halved one.
static func claim_box_face(ctrl: Node3D, mi: MeshInstance3D, tip_pos: Vector3,
		prefer_world_normal: Vector3, priority: int) -> void:
	if ctrl == null or mi == null or mi.mesh == null:
		return
	var xf: Transform3D = mi.global_transform
	var inv: Transform3D = xf.affine_inverse()
	var box: AABB = mi.mesh.get_aabb()
	var c: Vector3 = box.get_center()
	var half: Vector3 = box.size * 0.5
	var p: Vector3 = inv * tip_pos
	var ax := 0
	var sgn := 1.0
	if prefer_world_normal.length_squared() > 1e-12:
		var n: Vector3 = (inv.basis * prefer_world_normal).normalized()
		ax = _dominant(Vector3(absf(n.x), absf(n.y), absf(n.z)))
		sgn = signf(n[ax])
	else:
		var d: Vector3 = p - c
		ax = _dominant(Vector3(absf(d.x) / maxf(half.x, 1e-6),
			absf(d.y) / maxf(half.y, 1e-6), absf(d.z) / maxf(half.z, 1e-6)))
		sgn = signf(d[ax])
	if is_zero_approx(sgn):
		sgn = 1.0
	p[ax] = c[ax] + sgn * half[ax]
	for i in 3:
		if i == ax:
			continue
		# maxf guards a cap thinner than the inset, which would invert the clamp.
		var lim: float = maxf(half[i] - FACE_INSET, 0.0)
		p[i] = clampf(p[i], c[i] - lim, c[i] + lim)
	var face := Vector3.ZERO
	face[ax] = sgn
	set_contact(ctrl, xf * p, (xf.basis * face).normalized(), priority)


## Index of the largest component.
static func _dominant(v: Vector3) -> int:
	if v.x >= v.y and v.x >= v.z:
		return 0
	return 1 if v.y >= v.z else 2


func _ready() -> void:
	position = Vector3(0, 0, -TIP_FORWARD)
	_pickup = get_parent().get_node_or_null("FunctionPickup")
	# Consume same-frame claims: run after the widgets that make them. The
	# one-frame tolerance in _process covers any ordering this misses.
	process_priority = 100

	# Visible cone: apex exactly at this node's origin, base back toward the
	# controller body — reads as a stylus nib.
	_cone = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = CONE_RADIUS
	cone.height = CONE_HEIGHT
	_cone.mesh = cone
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.75, 0.8, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.3, 0.4)
	mat.emission_energy_multiplier = 0.4
	_cone.set_surface_override_material(0, mat)
	add_child(_cone)
	_apply_cone()   # with no claim this IS the old rest pose; see _apply_cone

	# Contact shadow. On a flat pad the cone alone cannot show WHERE the touch is
	# landing, and this sits at the smoothed, reported point — what you see is
	# what the core is told. top_level so it stays flat on the surface rather than
	# inheriting the hand's roll.
	_disc = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = DISC_RADIUS
	disc.bottom_radius = DISC_RADIUS
	disc.height = 0.0004
	disc.radial_segments = 16
	disc.rings = 1
	_disc.mesh = disc
	_disc_mat = StandardMaterial3D.new()
	_disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_disc_mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_disc_mat.albedo_color = Color(0.6, 0.9, 1.0, 0.0)
	_disc.set_surface_override_material(0, _disc_mat)
	_disc.top_level = true
	_disc.visible = false
	_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_disc)


## Record a claim, resolving against any other made this frame: higher priority
## wins, then nearest to the TRUE tip. Distance is measured from global_position
## (not the smoothed nib) so the winner cannot depend on which widget's _process
## ran first.
func _claim(world_point: Vector3, world_normal: Vector3, priority: int) -> void:
	var frame := Engine.get_process_frames()
	if frame != _claim_frame:
		_claim_frame = frame
		_claim_priority = -1
		_claim_dist = INF
	if priority < _claim_priority:
		return
	var d := global_position.distance_to(world_point)
	if priority == _claim_priority and d >= _claim_dist:
		return
	_claim_priority = priority
	_claim_dist = d
	_claim_normal = world_normal.normalized() if world_normal.length_squared() > 1e-12 \
		else Vector3.UP
	_claim_point = world_point + _claim_normal * CONTACT_LIFT


func _process(delta: float) -> void:
	# Hide the nib while this hand holds something — poking doesn't apply and
	# the cone would clip through the held object. Same signal VRButton/VRSlider
	# gate on, so the cone's visibility and the widgets' activation stay in sync.
	if _pickup:
		visible = is_poking(get_parent())
	if not visible:
		# Drop any claim rather than letting a stale one reappear on un-hide.
		_claim_priority = -1
		_claim_frame = -1
		_cone_local = Vector3.ZERO
		_blend = 0.0
		_apply_cone()
		_disc.visible = false
		return

	var live: bool = _claim_priority >= 0 and _claim_frame >= Engine.get_process_frames() - 1
	_hold = 0.0 if live else _hold + delta
	var on: bool = live or _hold < CONTACT_GRACE
	var k: float = clampf(CONTACT_LERP * delta, 0.0, 1.0)
	var target: Vector3 = to_local(_claim_point) if on else Vector3.ZERO
	_cone_local = _cone_local.lerp(target, k)
	_blend = lerpf(_blend, 1.0 if on else 0.0, k)
	_apply_cone()
	_apply_disc()


## Stretch the cone from its fixed base to the smoothed contact, rather than
## translating it — translating lets the nib float free of the hand when the
## contact is off to one side, while stretching keeps the wide end welded on and
## bends the point onto the surface.
##
## With no claim (_cone_local zero) this reduces EXACTLY to the old authored rest
## pose: d = (0,0,-CONE_HEIGHT), so the origin lands on (0, 0, CONE_HEIGHT/2) and
## the basis maps +Y (the cylinder's apex axis) to -Z. Idle looks unchanged by
## construction, which is what makes this safe to leave always-on.
func _apply_cone() -> void:
	if _cone == null:
		return
	var base := Vector3(0.0, 0.0, CONE_HEIGHT)
	var d: Vector3 = _cone_local - base
	var dist: float = d.length()
	if dist < 1e-6:
		d = Vector3(0.0, 0.0, -CONE_HEIGHT)
		dist = CONE_HEIGHT
	var reach: float = clampf(dist, CONE_HEIGHT * 0.4, CONTACT_MAX_REACH)
	var dir: Vector3 = d / dist
	var ref: Vector3 = Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD
	var bx: Vector3 = ref.cross(dir).normalized()
	var bz: Vector3 = bx.cross(dir)
	# Only the length axis scales, so the nib keeps its radius.
	_cone.transform = Transform3D(Basis(bx, dir * (reach / CONE_HEIGHT), bz),
		base + dir * (reach * 0.5))


func _apply_disc() -> void:
	if _disc == null:
		return
	_disc.visible = _blend > 0.02
	if not _disc.visible:
		return
	_disc_mat.albedo_color = Color(0.6, 0.9, 1.0, _blend * 0.55)
	var n: Vector3 = _claim_normal
	var ref: Vector3 = Vector3.RIGHT if absf(n.y) > 0.9 else Vector3.UP
	var dx: Vector3 = ref.cross(n).normalized()
	_disc.global_transform = Transform3D(Basis(dx, n, n.cross(dx)),
		to_global(_cone_local))
