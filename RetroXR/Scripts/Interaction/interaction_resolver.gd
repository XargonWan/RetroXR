## What the desktop pointer is aiming at: one query, nearest hit wins.
##
## The ray walks the scene front to back and stops at the first thing it can do
## something with. Three consequences worth stating, because each replaces a rule
## that used to be written out longhand:
##
##   * WORLD IS IN THE MASK, so a wall, a desk or a bookcase is a hit that ends
##     the walk. Occlusion is not a separate test bolted onto the result; a wall
##     is simply nearer than what is behind it.
##   * AN AREA IS NOT A SURFACE. A grab zone that is switched off, or holding
##     nothing, is a volume hanging in the air — the walk sees through it and
##     carries on. A BODY that yields nothing is the object itself and blocks.
##     Without this the NES's bay zone cast a dead cap over the whole console
##     whenever its flap was shut: not the cart (right) and not the console
##     (wrong), just nothing at all.
##   * A CONTROL RECESSED INTO WHAT YOU ARE POINTING AT BEATS IT, within
##     ENCLOSURE_DEPTH. A console's grab box encloses its own buttons and a
##     keyboard's encloses its keys, so the nearest surface is the shell and the
##     thing you meant is a few millimetres behind it.
##
## There is no priority ladder. Ranking button over pointer over pickable
## regardless of distance is what let a button four metres away beat a cartridge
## in front of your face; the ladder only existed because the two rays it was
## reconciling could not see each other's geometry.
class_name InteractionResolver
extends RefCounted


## 1:World, 3:Pickable, 21:XRPointer, 23:XRPointerSuppress. One mask, because a
## nearest-hit rule is meaningless across two queries that see different worlds.
const QUERY_MASK := (1 << 0) | (1 << 2) | (1 << 20) | (1 << 22)

## How far past the first grabbable thing a control still wins.
##
## Bounded, because unbounded is how a laser presses a button on the far side of
## the room. The NES's bay mouth is 26 mm deep and a keyboard's keys sit a few mm
## inside the board's grab box, so this covers the cases and is nowhere near
## across a room.
const ENCLOSURE_DEPTH := 0.05

## Hits to walk before giving up. Only volumes overlapping at one spot cost steps.
const MAX_STEPS := 8


static func resolve_desktop(
		space_state: PhysicsDirectSpaceState3D,
		from: Vector3,
		to: Vector3,
		grabber: Node3D) -> InteractionTarget:
	if space_state == null:
		return InteractionTarget.none()

	var exclude: Array[RID] = []
	var found: InteractionTarget = null

	for _step in MAX_STEPS:
		var query := PhysicsRayQueryParameters3D.create(from, to, QUERY_MASK)
		query.collide_with_bodies = true
		query.collide_with_areas = true
		query.exclude = exclude
		var hit := space_state.intersect_ray(query)
		if hit.is_empty():
			break

		var target := _classify(hit, from, grabber)
		if target.is_valid():
			if found == null:
				# Keep walking a little further: this may be the shell around the
				# control that was actually meant.
				found = target
			elif _is_control(target) and not _is_control(found) \
					and target.distance - found.distance <= ENCLOSURE_DEPTH:
				return target
			else:
				return found
			exclude.append(hit.rid)
			continue

		# Nothing doable here. See through a volume, stop at a surface — except
		# something a socket is holding, which is part of the machine around it
		# rather than an obstacle in front of it. A cart seated in a shut NES
		# stands 2 mm proud of the deck; left to block, it put a dead cap over the
		# whole console, giving neither the cart (right) nor the console (wrong).
		if hit.collider is Area3D or _is_socketed(hit.collider):
			exclude.append(hit.rid)
			continue
		return found if found != null else InteractionTarget.none()

	return found if found != null else InteractionTarget.none()


## A control is something you operate rather than pick up — the kind that is
## allowed to win from inside the object housing it.
static func _is_control(target: InteractionTarget) -> bool:
	return target.kind == InteractionTarget.KIND_BUTTON \
		or target.kind == InteractionTarget.KIND_POINTER


## What this hit means, reading the collider and then its ancestors.
##
## Order within a level is load-bearing: a RetroKeyboard IS an XRToolsPickable, so
## testing pickable before pointer_event is what makes a pointer_event on the board
## itself unreachable — which is why KeyboardKeyField exists as its own area.
static func _classify(
		hit: Dictionary,
		ray_from: Vector3,
		grabber: Node3D) -> InteractionTarget:
	var node := hit.collider as Node
	var distance: float = ray_from.distance_to(hit.position)
	while node:
		if node is VRButton:
			return _make_target(InteractionTarget.KIND_BUTTON, hit.collider as Node3D,
				node as Node3D, node as Node3D, node as Node3D,
				hit.position, distance, true, false)

		if node is XRToolsSnapZone:
			var zone := node as XRToolsSnapZone
			var snapped := held_pickable(zone)
			if snapped == null or not is_instance_valid(grabber) \
					or not zone.can_pick_up(grabber):
				return InteractionTarget.none()
			return _make_target(InteractionTarget.KIND_SNAP_PICKABLE, hit.collider as Node3D,
				zone, snapped, null, hit.position, distance, false, true)

		if node is XRToolsPickable:
			var pickable := node as XRToolsPickable
			if is_instance_valid(grabber) and pickable.can_pick_up(grabber):
				return _make_target(InteractionTarget.KIND_PICKABLE, hit.collider as Node3D,
					pickable, pickable, null, hit.position, distance, false, true)
			# Refused because a socket is holding it: the socket IS its affordance,
			# so hitting a seated cartridge means "pull it out", not "blocked". Its
			# own pointer body sits in front of the socket's reach sphere, so
			# without this a seated cart makes itself unreachable.
			var holder := _snap_zone_holding(pickable)
			if holder != null and is_instance_valid(grabber) and holder.can_pick_up(grabber):
				return _make_target(InteractionTarget.KIND_SNAP_PICKABLE, hit.collider as Node3D,
					holder, pickable, null, hit.position, distance, false, true)
			return InteractionTarget.none()

		if node.has_method("pointer_event") or node.has_signal("pointer_event"):
			var pointer_target := node as Node3D
			if pointer_target != null:
				return _make_target(InteractionTarget.KIND_POINTER, hit.collider as Node3D,
					pointer_target, null, pointer_target,
					hit.position, distance, true, false)

		node = node.get_parent()

	return InteractionTarget.none()


## True when this collider belongs to something a socket is holding.
static func _is_socketed(collider: Object) -> bool:
	var node := collider as Node
	while node:
		if node is XRToolsPickable:
			return _snap_zone_holding(node as XRToolsPickable) != null
		node = node.get_parent()
	return false


## The snap zone currently holding this pickable, or null if a hand has it.
static func _snap_zone_holding(pickable: XRToolsPickable) -> XRToolsSnapZone:
	if not is_instance_valid(pickable) or not pickable.is_picked_up():
		return null
	return pickable.get_picked_up_by() as XRToolsSnapZone


## What a snap zone is holding, or null — including when it is still pointing at
## something that has been freed. A room teardown frees a cable while its plugs
## are seated, and the socket keeps the dead reference: xr-tools guards every one
## of its own reads with is_instance_valid for exactly that reason. The read has
## to go through a Variant, because BOTH casting a freed object and assigning one
## to a typed local throw "Trying to cast a freed object".
static func held_pickable(zone: XRToolsSnapZone) -> XRToolsPickable:
	if not is_instance_valid(zone):
		return null
	var held: Variant = zone.picked_up_object
	if not is_instance_valid(held):
		return null
	return held as XRToolsPickable


static func _make_target(
		kind: StringName,
		hit_node: Node3D,
		action_node: Node3D,
		highlight_node: Node3D,
		pointer_event_target: Node3D,
		position: Vector3,
		distance: float,
		can_activate: bool,
		can_grab: bool) -> InteractionTarget:
	var target := InteractionTarget.new()
	target.kind = kind
	target.hit_node = hit_node
	target.action_node = action_node
	target.highlight_node = highlight_node
	target.pointer_event_target = pointer_event_target
	target.position = position
	target.distance = distance
	target.can_activate = can_activate
	target.can_grab = can_grab
	return target
