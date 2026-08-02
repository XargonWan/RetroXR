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
	if pickable != null and not pickable.dropped.is_connected(_on_dropped):
		pickable.dropped.connect(_on_dropped)
	if pickable != null and not pickable.picked_up.is_connected(_on_picked_up):
		pickable.picked_up.connect(_on_picked_up)


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
	var desktop := is_instance_valid(by) and by.is_in_group("desktop_hand")
	if not desktop and not _is_ray_grab(by, obj):
		return

	var hint := HeldHint.for_node(obj)
	if hint == null:
		return
	hint.add_row(&"rotate_yaw", HeldHint.PLATFORM_BOTH,
		DESKTOP_ROTATE_GLYPHS if desktop else VR_ROTATE_GLYPHS,
		"Use {g} to pitch and yaw", HeldHint.WHEN_HELD)
	hint.add_row(&"rotate_roll", HeldHint.PLATFORM_BOTH,
		DESKTOP_ROLL_GLYPHS if desktop else VR_ROLL_GLYPHS,
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
