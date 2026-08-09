class_name InteractionResolver
extends RefCounted


const BUTTON_PRIORITY := 300
const POINTER_PRIORITY := 250
const SNAP_PICKABLE_PRIORITY := 200
const PICKABLE_PRIORITY := 100
const DISTANCE_EPSILON := 0.000001


static func resolve_desktop(
		space_state: PhysicsDirectSpaceState3D,
		pointer_from: Vector3,
		pointer_to: Vector3,
		pointer_mask: int,
		pointer_collide_with_bodies: bool,
		pointer_collide_with_areas: bool,
		pickup_from: Vector3,
		pickup_to: Vector3,
		pickup_mask: int,
		pickup_collide_with_bodies: bool,
		pickup_collide_with_areas: bool,
		grabber: Node3D) -> InteractionTarget:
	var pointer_hit := _get_front_hit(
		space_state,
		pointer_from,
		pointer_to,
		pointer_mask,
		pointer_collide_with_bodies,
		pointer_collide_with_areas)
	var pickup_hit := _get_front_hit(
		space_state,
		pickup_from,
		pickup_to,
		pickup_mask,
		pickup_collide_with_bodies,
		pickup_collide_with_areas)

	var pointer_target := _classify_pointer_hit(pointer_hit, pointer_from, grabber)
	var pickup_target := _classify_pickup_hit(pickup_hit, pickup_from, grabber)
	return _choose_target(pointer_target, pickup_target)


static func _get_front_hit(
		space_state: PhysicsDirectSpaceState3D,
		from: Vector3,
		to: Vector3,
		mask: int,
		collide_with_bodies: bool,
		collide_with_areas: bool) -> Dictionary:
	if mask == 0 or (not collide_with_bodies and not collide_with_areas):
		return {}

	if collide_with_bodies and collide_with_areas:
		var area_query := PhysicsRayQueryParameters3D.create(from, to, mask)
		area_query.collide_with_bodies = false
		area_query.collide_with_areas = true
		var area_hit := space_state.intersect_ray(area_query)

		var body_query := PhysicsRayQueryParameters3D.create(from, to, mask)
		body_query.collide_with_bodies = true
		body_query.collide_with_areas = false
		var body_hit := space_state.intersect_ray(body_query)

		if area_hit.is_empty():
			return body_hit
		if body_hit.is_empty():
			return area_hit

		# An interactive pointer area wins over a body even when the body is
		# nearer. Console grab collision (the PointerArea) is a single box that
		# ENCLOSES the recessed power/reset buttons AND overlaps the touch screen,
		# so a ray reaches the box surface a couple of centimetres before the area
		# behind it. Without this the front hit collapses to the body and the area
		# — which carries BUTTON_PRIORITY (buttons) or POINTER_PRIORITY (the touch
		# screen) and is meant to win — is discarded before _choose_target sees it.
		# That is why the Genesis/DS Phat power buttons were not clickable and why
		# tapping a DS/3DS touch screen grabbed the console instead.
		if _is_pointer_interactive(area_hit.collider):
			return area_hit

		var area_dist := from.distance_squared_to(area_hit.position)
		var body_dist := from.distance_squared_to(body_hit.position)
		if area_dist <= body_dist + DISTANCE_EPSILON:
			return area_hit
		return body_hit

	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	query.collide_with_bodies = collide_with_bodies
	query.collide_with_areas = collide_with_areas
	return space_state.intersect_ray(query)


## True when this collider — or an ancestor — is something the pointer drives
## (a VRButton, or a node exposing pointer_event like the DS/3DS touch screen).
## Used to let those areas beat the enclosing grab body in _get_front_hit.
static func _is_pointer_interactive(collider: Object) -> bool:
	var node := collider as Node
	while node:
		if node is VRButton:
			return true
		if node.has_method("pointer_event") or node.has_signal("pointer_event"):
			return true
		node = node.get_parent()
	return false


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


static func _classify_pointer_hit(
		hit: Dictionary,
		ray_from: Vector3,
		grabber: Node3D) -> InteractionTarget:
	if hit.is_empty():
		return InteractionTarget.none()

	var node := hit.collider as Node
	while node:
		if node is VRButton:
			var button := node as Node3D
			return _make_target(
				InteractionTarget.KIND_BUTTON,
				hit.collider as Node3D,
				button,
				button,
				button,
				hit.position,
				ray_from.distance_to(hit.position),
				BUTTON_PRIORITY,
				true,
				false)

		if node is XRToolsPickable:
			var pickable := node as XRToolsPickable
			if not is_instance_valid(grabber) or not pickable.can_pick_up(grabber):
				return InteractionTarget.none()
			return _make_target(
				InteractionTarget.KIND_PICKABLE,
				hit.collider as Node3D,
				pickable,
				pickable,
				null,
				hit.position,
				ray_from.distance_to(hit.position),
				PICKABLE_PRIORITY,
				false,
				true)

		if node.has_method("pointer_event") or node.has_signal("pointer_event"):
			var pointer_target := node as Node3D
			if pointer_target:
				return _make_target(
					InteractionTarget.KIND_POINTER,
					hit.collider as Node3D,
					pointer_target,
					null,
					pointer_target,
					hit.position,
					ray_from.distance_to(hit.position),
					POINTER_PRIORITY,
					true,
					false)

		node = node.get_parent()

	return InteractionTarget.none()


static func _classify_pickup_hit(
		hit: Dictionary,
		ray_from: Vector3,
		grabber: Node3D) -> InteractionTarget:
	if hit.is_empty():
		return InteractionTarget.none()

	var node := hit.collider as Node
	while node:
		if node is XRToolsSnapZone:
			var snap_zone := node as XRToolsSnapZone
			var snapped_pickable := held_pickable(snap_zone)
			if (
				not is_instance_valid(grabber) or
				snapped_pickable == null or
				not snap_zone.can_pick_up(grabber)
			):
				return InteractionTarget.none()

			return _make_target(
				InteractionTarget.KIND_SNAP_PICKABLE,
				hit.collider as Node3D,
				snap_zone,
				snapped_pickable,
				null,
				hit.position,
				ray_from.distance_to(hit.position),
				SNAP_PICKABLE_PRIORITY,
				false,
				true)

		if node is XRToolsPickable:
			var pickable := node as XRToolsPickable
			if not is_instance_valid(grabber) or not pickable.can_pick_up(grabber):
				return InteractionTarget.none()
			return _make_target(
				InteractionTarget.KIND_PICKABLE,
				hit.collider as Node3D,
				pickable,
				pickable,
				null,
				hit.position,
				ray_from.distance_to(hit.position),
				PICKABLE_PRIORITY,
				false,
				true)

		node = node.get_parent()

	return InteractionTarget.none()


static func _make_target(
		kind: StringName,
		hit_node: Node3D,
		action_node: Node3D,
		highlight_node: Node3D,
		pointer_event_target: Node3D,
		position: Vector3,
		distance: float,
		priority: int,
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
	target.priority = priority
	target.can_activate = can_activate
	target.can_grab = can_grab
	return target


static func _choose_target(
		pointer_target: InteractionTarget,
		pickup_target: InteractionTarget) -> InteractionTarget:
	if not pointer_target.is_valid():
		return pickup_target
	if not pickup_target.is_valid():
		return pointer_target

	if (
		pointer_target.action_node == pickup_target.action_node and
		pointer_target.kind == pickup_target.kind
	):
		if is_instance_valid(pointer_target.pointer_event_target):
			pickup_target.pointer_event_target = pointer_target.pointer_event_target
		return pickup_target

	if pointer_target.priority > pickup_target.priority:
		return pointer_target
	if pickup_target.priority > pointer_target.priority:
		return pickup_target

	if pointer_target.distance <= pickup_target.distance + DISTANCE_EPSILON:
		return pointer_target
	return pickup_target
