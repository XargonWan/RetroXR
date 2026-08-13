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
## FLUSH, not merely nearby. The rule has no notion of which side you are coming
## from, so any slack lets a control be operated through the back of the object
## housing it: the keyboard's key field sits 1 mm under the board's top face but
## 13 mm above its underside and 12 mm inside its back edge, so at 50 mm the board
## could not be picked up from below, from behind, or by its palm rest — every aim
## that happened to line up with a key gave the key.
##
## 5 mm keeps a control that is level with the surface it sits in and drops one
## that is merely inside the volume. A control recessed deeper than this needs the
## shell carved away in front of it, which is what every other case in the room
## already does.
const ENCLOSURE_DEPTH := 0.005

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
	var socket: InteractionTarget = null

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
			# A socket's REACH SPHERE is an affordance volume, not a surface: it is
			# invisible, far bigger than the part it holds, and it overlaps its
			# neighbours. The NES bay's stands 51 mm out through the top of the
			# deck, and a console's three phono sockets are 120 mm across with
			# their centres a few tens of mm apart. Taken as a surface it hands you
			# the cartridge when you point at solid casework, and the nearest plug
			# when you point at the one behind it. Held back as a fallback, the
			# plug's OWN body answers first and the sphere only catches an aim that
			# nothing else claims.
			if hit.collider is XRToolsSnapZone:
				if socket == null:
					socket = target
				exclude.append(hit.rid)
				continue
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
		return _best(found, socket)

	return _best(found, socket)


## What the walk actually reached, preferring a real surface over a socket's reach.
static func _best(found: InteractionTarget, socket: InteractionTarget) -> InteractionTarget:
	if found != null:
		return found
	if socket != null:
		return socket
	return InteractionTarget.none()


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
			if pointer_target != null and _accepts_pointer(pointer_target, hit.position):
				return _make_target(InteractionTarget.KIND_POINTER, hit.collider as Node3D,
					pointer_target, null, pointer_target,
					hit.position, distance, true, false)

		node = node.get_parent()

	return InteractionTarget.none()


## Let a pointer target refuse a point it does not actually cover.
##
## A pointable area is a box, and some of them are much bigger than the thing
## they represent: the keyboard's key field is one slab over 95% of the board,
## because the caps have no colliders of their own. Declining leaves the walk to
## carry on to whatever is behind — the board itself — so the parts of it with no
## key under them can still be picked up.
static func _accepts_pointer(node: Node3D, at: Vector3) -> bool:
	if node.has_method("accepts_pointer_at"):
		return bool(node.call("accepts_pointer_at", at))
	return true


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
