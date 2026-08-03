## HeldObjectPhysics — a held object passes through the world, and gets pushed
## back out if you let go of it inside something.
##
## Two halves, both applied to every pickable as it enters the tree, the same way
## VRKeyboardFix and TypingGuard reach every text field.
##
## ── Passing through while held ────────────────────────────────────────────────
## xr-tools already sets a held object's collision_mask to 0 and moves it to
## picked_up_layer (17, "XRHand_SnapZone"). That is only half the job: Godot
## registers a contact when EITHER body's mask matches the other's layer, and
## every pickable in this project masks 196613 — World, Pickable, SnapZone(17)
## and XRHand_Physics. Bit 17 is exactly the layer the thing in your hand just
## moved to, so loose objects went on colliding with it from their side.
##
## Clearing that bit is what actually stops it. Only PhysicsBody3D masks are
## touched: snap zones are Area3Ds and detect on their own mask (65540), so they
## still see a held object and keep working.
##
## ── Escaping on release ───────────────────────────────────────────────────────
## Because a held object passes through everything, you can let go of one while
## it is inside a shelf or a cabinet. Dropping it there would either wedge it or
## fire it across the room as the solver resolves the overlap. Instead it steps
## out toward the player, still passing through, and only rejoins the simulation
## once it is clear — so the thing it was inside is never touched.
class_name HeldObjectPhysics
extends Node

## Bit 17, "XRHand_SnapZone" — XRToolsPickable.DEFAULT_LAYER, where a held object
## lives for as long as it is held.
const HELD_BIT := 1 << 16

## Metres per step while escaping, how far it may travel, and the cap on steps so
## a bad query can never spin.
const STEP := 0.02
const MAX_TRAVEL := 0.6
const MAX_STEPS := int(MAX_TRAVEL / STEP)

# ── Falling out of the world ──────────────────────────────────────────────────
# Every room puts the top of its floor slab at y = 0, so anything this far under
# it has left through the floor or over an edge and is never coming back.
const FALL_LIMIT_Y := -2.0

## Rate the fall check runs at. A falling object is recovered wherever it got to,
## so this needs no precision — and at 60-120 Hz, per-frame checks on every
## pickable in the room would be pure waste.
const FALL_CHECK_HZ := 4.0

## An object is "at rest" — and so worth remembering as a safe spot — below this
## speed. Squared, to keep the check off sqrt.
const AT_REST_SPEED2 := 0.01

## Clear of the floor by this much before a pose counts as safe, so a body that
## has already begun sinking into geometry is never recorded as somewhere to
## return to.
const SAFE_MIN_Y := 0.02

var _fall_timer := 0.0
## Every pickable in the tree, and the last pose each was seen resting at.
## Keyed by instance id so a freed object cannot resurrect one.
var _watched: Dictionary = {}
var _safe_pose: Dictionary = {}


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	_patch_tree(get_tree().root)


func _on_node_added(node: Node) -> void:
	_patch(node)


func _patch_tree(root: Node) -> void:
	_patch(root)
	for c in root.get_children():
		_patch_tree(c)


func _patch(node: Node) -> void:
	var body := node as PhysicsBody3D
	if body != null and (body.collision_mask & HELD_BIT) != 0:
		# Before _ready, so XRToolsPickable's @onready original_collision_mask
		# captures the cleared value and a drop restores the cleared value too.
		body.collision_mask &= ~HELD_BIT

	var pickable := node as XRToolsPickable
	if pickable != null:
		_watched[pickable.get_instance_id()] = pickable
		# No pickable in this project had continuous collision detection, so a
		# hard throw could step straight through the 0.2 m floor slab in one
		# tick. A ray-thrown object is the worst case by far: swung at arm's
		# length on a 3 m beam it leaves the hand several times faster than the
		# hand ever moved.
		pickable.continuous_cd = true
	if pickable != null and not pickable.dropped.is_connected(_on_dropped):
		pickable.dropped.connect(_on_dropped)
	if pickable != null and not pickable.picked_up.is_connected(_on_picked_up):
		pickable.picked_up.connect(_on_picked_up)

	# A ray grab never creates a GrabDriver, so the pickable's own picked_up never
	# fires for one — the ray-only rows have to come off the pickup instead.
	var pickup := node as XRToolsFunctionPickup
	if pickup != null:
		if not pickup.has_picked_up.is_connected(_on_pickup_grabbed):
			pickup.has_picked_up.connect(_on_pickup_grabbed.bind(pickup))
		if not pickup.has_transferred.is_connected(_on_pickup_transferred):
			pickup.has_transferred.connect(_on_pickup_transferred.bind(pickup))


# ── Teaching the rotate verbs ─────────────────────────────────────────────────
# Every pickable can be turned while you hold it, and nothing says so. Taught
# here rather than in each object's script for the same reason the collision
# fix is: this autoload already sees every pickable as it enters the tree.

## Desktop: middle-mouse drag rotates (Kenney names the middle button by its
## wheel, hence mouse_scroll_outline), and Shift swaps its horizontal axis from
## yaw to roll. Vertical pitches either way — hence "pitch and yaw" / "pitch and
## roll" rather than one axis each. See desktop_pickup.gd.
const DESKTOP_ROTATE_GLYPHS: Array[String] = ["mouse_scroll_outline"]
const DESKTOP_ROLL_GLYPHS: Array[String] = ["keyboard_shift_outline", "mouse_scroll_outline"]
## VR: the FREE hand's thumbstick, and grip on that same hand for roll. Only
## while ray-grabbing — a direct hand grab is turned with your wrist, so the
## rows would be advertising a control that does nothing. See
## function_pickup._compute_ray_grab_rotation.
const VR_ROTATE_GLYPHS: Array[String] = ["quest_stick_l_press"]
const VR_ROLL_GLYPHS: Array[String] = ["quest_grip_left_outline", "quest_stick_l_press"]


func _on_picked_up(pickable: Variant) -> void:
	var obj := pickable as XRToolsPickable
	if obj == null or not is_instance_valid(obj):
		return
	var by := obj.get_picked_up_by()
	# VR is driven off the pickup's own signals instead (see _apply_mode_rows) —
	# the rows differ between the hand hold and the ray hold, and only the pickup
	# knows which one is live.
	if not (is_instance_valid(by) and by.is_in_group("desktop_hand")):
		return

	var hint := HeldHint.for_node(obj)
	if hint == null:
		return
	hint.add_row(&"rotate_yaw", HeldHint.PLATFORM_DESKTOP, DESKTOP_ROTATE_GLYPHS,
		"Use {g} to pitch and yaw", HeldHint.WHEN_HELD)
	hint.add_row(&"rotate_roll", HeldHint.PLATFORM_DESKTOP, DESKTOP_ROLL_GLYPHS,
		"Use {g} to pitch and roll", HeldHint.WHEN_HELD)

	# Objects with a hint of their own call this from their own grab handler, and
	# a second call only rebuilds the same panel. Objects without one — a
	# cartridge, a disc — have nobody to call it, and these rows would never show.
	hint.on_grabbed(by)


## True when `by` is holding `obj` at the end of a laser rather than in the hand.
func _is_ray_grab(by: Node3D, obj: XRToolsPickable) -> bool:
	return is_instance_valid(by) \
		and by.has_method("is_ray_grabbing_target") \
		and by.call("is_ray_grabbing_target", obj)


## The push-out verb: only offered on objects that accept it, and only in VR.
## Unlike the rotate rows — which are the FREE hand and so hardcode left art —
## these are on the hand doing the holding, so they take the {side}/{s} tokens.
const VR_PUSH_GLYPHS: Array[String] = ["quest_trigger_{side}_outline", "quest_stick_{s}_press"]
## The catch: pull the stick to its edge and hold. Without this row an object
## parked at arm's length and refusing to come closer just reads as stuck.
const VR_CATCH_GLYPHS: Array[String] = ["quest_stick_{s}_press"]


func _on_pickup_grabbed(what: Variant, pickup: XRToolsFunctionPickup) -> void:
	var obj := what as XRToolsPickable
	if obj == null or not is_instance_valid(obj):
		return
	_apply_mode_rows(obj, pickup, _is_ray_grab(pickup, obj))


func _on_pickup_transferred(what: Variant, to_ray: bool,
		pickup: XRToolsFunctionPickup) -> void:
	var obj := what as XRToolsPickable
	if obj == null or not is_instance_valid(obj):
		return
	_apply_mode_rows(obj, pickup, to_ray)


## Swap the rows that describe how the object is being held right now. Rotating
## with the free hand's stick only works off the laser; pushing out only works
## from the hand.
func _apply_mode_rows(obj: XRToolsPickable, pickup: XRToolsFunctionPickup,
		on_ray: bool) -> void:
	var hint := HeldHint.for_node(obj)
	if hint == null:
		return

	if on_ray:
		hint.remove_row(&"push_to_ray")
		hint.add_row(&"rotate_yaw", HeldHint.PLATFORM_VR, VR_ROTATE_GLYPHS,
			"Use {g} to pitch and yaw", HeldHint.WHEN_HELD)
		hint.add_row(&"rotate_roll", HeldHint.PLATFORM_VR, VR_ROLL_GLYPHS,
			"Use {g} to pitch and roll", HeldHint.WHEN_HELD)
		hint.add_row(&"catch_from_ray", HeldHint.PLATFORM_VR, VR_CATCH_GLYPHS,
			"Pull {g} all the way back and hold to catch it", HeldHint.WHEN_HELD)
	else:
		hint.remove_row(&"rotate_yaw")
		hint.remove_row(&"rotate_roll")
		hint.remove_row(&"catch_from_ray")
		if _accepts_push(obj):
			hint.add_row(&"push_to_ray", HeldHint.PLATFORM_VR, VR_PUSH_GLYPHS,
				"Hold {g} and push forward to send it to the beam", HeldHint.WHEN_HELD)

	hint.on_grabbed(pickup)


func _accepts_push(obj: XRToolsPickable) -> bool:
	if obj.has_method("wants_ray_handoff"):
		return obj.wants_ray_handoff()
	return true


# ── Escaping on release ───────────────────────────────────────────────────────

func _on_dropped(pickable: Variant) -> void:
	var body := pickable as XRToolsPickable
	if body != null:
		_escape.call_deferred(body)


func _escape(body: XRToolsPickable) -> void:
	if not is_instance_valid(body) or not body.is_inside_tree():
		return
	# A snap zone that claimed it on release has picked it up again; leaving is
	# the whole point of a slot, so nothing to escape from.
	if body.is_picked_up():
		return

	var cs := _first_shape(body)
	# The shape's own transform, not the body's: a CollisionShape3D is usually
	# offset from its body's origin, and querying at the origin tests empty space.
	if cs == null or not _overlapping(body, cs.shape, cs.global_transform):
		return

	var cam := body.get_viewport().get_camera_3d()
	if cam == null:
		return
	var dir := cam.global_position - body.global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = Vector3.BACK
	dir = dir.normalized()

	# Pass through for the whole escape, so the thing it was inside is never
	# pushed. Frozen too: the solver must not act on the overlap we are undoing.
	var layer := body.collision_layer
	var mask := body.collision_mask
	var frozen := body.freeze
	body.collision_layer = HELD_BIT
	body.collision_mask = 0
	body.freeze = true

	var probe := cs.global_transform
	var moved := 0.0
	for i in MAX_STEPS:
		probe.origin += dir * STEP
		moved += STEP
		if not _overlapping(body, cs.shape, probe):
			break
	var t := body.global_transform
	t.origin += dir * moved
	body.global_transform = t

	body.collision_layer = layer
	body.collision_mask = mask
	body.freeze = frozen
	body.force_update_transform()
	PhysicsServer3D.body_set_state(
		body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, t)


# ── Falling out of the world ──────────────────────────────────────────────────
#
# Objects still get under the floor: released inside it (the escape above only
# moves horizontally, so it cannot lift one out), thrown through it, or simply
# dropped past the edge of a floor slab that is only as big as the room. Rather
# than chase each of those, this catches the outcome they share — the object is
# below the world and falling forever — and puts it back.
#
# "Back" is where it was last sitting still, not straight up from where it fell:
# an object that went over the edge has no floor above it to return to, and one
# that dropped through has an owner who last saw it on a shelf, not on the
# carpet beneath.

func _physics_process(delta: float) -> void:
	_fall_timer += delta
	if _fall_timer < 1.0 / FALL_CHECK_HZ:
		return
	_fall_timer = 0.0

	for id: int in _watched.keys():
		var body: XRToolsPickable = _watched[id]
		if not is_instance_valid(body) or not body.is_inside_tree():
			_watched.erase(id)
			_safe_pose.erase(id)
			continue
		# Held, socketed or flying on a beam: its position is somebody else's
		# business, and mid-flight is not a pose worth remembering.
		if body.is_picked_up() or body.freeze:
			continue
		if body.global_position.y < FALL_LIMIT_Y:
			_recover(id, body)
		elif body.global_position.y > SAFE_MIN_Y \
				and body.linear_velocity.length_squared() < AT_REST_SPEED2:
			_safe_pose[id] = body.global_transform


func _recover(id: int, body: XRToolsPickable) -> void:
	var to: Transform3D = _safe_pose.get(id, Transform3D.IDENTITY)
	if not _safe_pose.has(id):
		# Never seen at rest — it fell before it ever settled. Put it in front of
		# the player instead, where they will actually notice it came back.
		var cam := body.get_viewport().get_camera_3d()
		if cam == null:
			return          # no camera yet; try again on the next pass
		to = Transform3D(body.global_transform.basis, _in_front_of(cam))

	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.global_transform = to
	body.force_update_transform()
	# A teleported body keeps its old transform in the physics server until it is
	# pushed explicitly, and would carry on falling from where it was.
	PhysicsServer3D.body_set_state(
		body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, to)
	PhysicsServer3D.body_set_state(
		body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(
		body.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)


## A spot at chest height an arm's length in front of the player.
func _in_front_of(cam: Camera3D) -> Vector3:
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	return cam.global_position + fwd.normalized() * 0.5 + Vector3(0.0, -0.2, 0.0)


## True while `shape`, placed at `xform`, is inside another body. Areas are
## excluded: a snap zone or a trigger volume is not something to escape from.
func _overlapping(body: PhysicsBody3D, shape: Shape3D, xform: Transform3D) -> bool:
	var space := body.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = xform
	q.collide_with_areas = false
	q.collide_with_bodies = true
	q.exclude = [body.get_rid()]
	# Its own mask is 0 while held, so query against what it will collide with
	# once it is let go.
	q.collision_mask = body.collision_mask if body.collision_mask != 0 \
		else _restored_mask(body)
	return not space.intersect_shape(q, 1).is_empty()


func _restored_mask(body: PhysicsBody3D) -> int:
	var v: Variant = body.get("original_collision_mask")
	return int(v) if v != null else 1


func _first_shape(body: PhysicsBody3D) -> CollisionShape3D:
	for c in body.get_children():
		var cs := c as CollisionShape3D
		if cs != null and cs.shape != null and not cs.disabled:
			return cs
	return null
