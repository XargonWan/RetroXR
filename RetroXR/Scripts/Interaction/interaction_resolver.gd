class_name InteractionResolver
extends RefCounted


const BUTTON_PRIORITY := 300
const POINTER_PRIORITY := 250
const SNAP_PICKABLE_PRIORITY := 200
const PICKABLE_PRIORITY := 100
const DISTANCE_EPSILON := 0.000001

## Layers a solid body has to be on to stand in the pointer's way.
## 1:World, 3:Pickable, 19:XRPickable, 20:XRButton, 21:XRPointer.
##
## 17:XRHand_SnapZone is deliberately absent: that is the layer XRToolsPickable
## moves an object to while it is held, and the thing in your hand must not
## blind your own laser. Areas never occlude either — a snap zone's reach, a
## button's touch volume and the pointer-suppress bubble are all invisible.
const OCCLUDER_MASK := (1 << 0) | (1 << 2) | (1 << 18) | (1 << 19) | (1 << 20)

## How far in front an occluder has to be before it counts. Interactive volumes
## routinely sit flush with the shell they belong to, and a hit exactly on the
## surface must not shadow itself.
const OCCLUSION_SLACK := 0.01

## Aim tolerance when testing the ray against an object's visible geometry.
const VISUAL_MARGIN := 0.005

## Hits discarded per ray before giving up. Each rejected candidate costs one
## more query, and a stack of five interactive volumes along one ray is already
## beyond anything the room builds.
const MAX_PASSES := 6


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
	var pointer_target := _resolve_ray(
		space_state,
		pointer_from,
		pointer_to,
		pointer_mask,
		pointer_collide_with_bodies,
		pointer_collide_with_areas,
		grabber,
		true)
	var pickup_target := _resolve_ray(
		space_state,
		pickup_from,
		pickup_to,
		pickup_mask,
		pickup_collide_with_bodies,
		pickup_collide_with_areas,
		grabber,
		false)
	return _choose_target(pointer_target, pickup_target)


## Walk this ray outwards until it reaches something the player can actually see
## and is actually aiming at, discarding candidates that fail either test.
##
## Discarding rather than stopping matters: an unreachable candidate is a volume
## floating in front of real geometry, so what is behind it is what the player
## meant. Aiming at the top of a loaded NES steps past the cartridge bay's grab
## sphere and lands on the console.
static func _resolve_ray(
		space_state: PhysicsDirectSpaceState3D,
		from: Vector3,
		to: Vector3,
		mask: int,
		collide_with_bodies: bool,
		collide_with_areas: bool,
		grabber: Node3D,
		pointer: bool) -> InteractionTarget:
	var exclude: Array[RID] = []
	for _pass in MAX_PASSES:
		var hit := _get_front_hit(
			space_state, from, to, mask, collide_with_bodies, collide_with_areas, exclude)
		if hit.is_empty():
			return InteractionTarget.none()

		var target: InteractionTarget = _classify_pointer_hit(hit, from, grabber) if pointer \
			else _classify_pickup_hit(hit, from, grabber)
		if not target.is_valid():
			# A solid thing the player cannot use still blocks what is behind it.
			return target

		# A snap zone stands in for whatever it holds, and its grab sphere is far
		# bigger than that object — the NES cartridge bay's reaches out through
		# the top of the shell. Aim at the cartridge, not at the socket's reach.
		var blocked: RID = hit.rid
		if target.kind == InteractionTarget.KIND_SNAP_PICKABLE:
			var entry: Variant = _visual_entry(target.highlight_node, from, to)
			if entry == null:
				exclude.append(blocked)
				continue
			var point: Vector3 = entry
			target.position = point
			target.distance = from.distance_to(point)

		if has_line_of_sight(space_state, from, target.position, _sight_node(target)):
			return target
		exclude.append(blocked)

	return InteractionTarget.none()


## True when nothing solid stands between `from` and `at`.
##
## Interactive volumes live on their own thin layers, so the ray that finds them
## passes straight through every wall, desk and console shell in the room. This
## is the check that puts them back: a button on the far side of a cabinet, or a
## plug buried inside it, is not something the player is pointing at.
static func has_line_of_sight(
		space_state: PhysicsDirectSpaceState3D,
		from: Vector3,
		at: Vector3,
		target: Node) -> bool:
	if space_state == null:
		return true
	var span := from.distance_to(at)
	if span <= OCCLUSION_SLACK:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, at, OCCLUDER_MASK)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var exclude: Array[RID] = []
	for _pass in MAX_PASSES:
		var hit := space_state.intersect_ray(query)
		if hit.is_empty():
			return true
		if from.distance_to(hit.position) >= span - OCCLUSION_SLACK:
			return true
		if not _same_object(hit.collider as Node, target):
			return false
		# The target's own shell cannot hide it — look past this one and on.
		var passed: RID = hit.rid
		exclude.append(passed)
		query.exclude = exclude

	return true


## True when these two nodes are parts of one object rather than two.
##
## A console's pointer box encloses its own recessed buttons, so judging by the
## scene tree alone would make every console hide its own controls. An object
## that is a pickable in its own right is its own answer even when it is parented
## into another one: a seated cartridge is not part of the console holding it.
static func _same_object(a: Node, b: Node) -> bool:
	if not is_instance_valid(a) or not is_instance_valid(b):
		return true
	if a == b:
		return true

	var root_a := _pickable_root(a)
	var root_b := _pickable_root(b)
	if root_a != null or root_b != null:
		return root_a == root_b

	return a.is_ancestor_of(b) or b.is_ancestor_of(a)


## Nearest XRToolsPickable at or above this node, or null.
static func _pickable_root(node: Node) -> XRToolsPickable:
	var n := node
	while is_instance_valid(n):
		if n is XRToolsPickable:
			return n as XRToolsPickable
		n = n.get_parent()
	return null


## The node whose own geometry is allowed to stand in front of this target.
static func _sight_node(target: InteractionTarget) -> Node:
	if target.kind == InteractionTarget.KIND_SNAP_PICKABLE:
		return target.highlight_node
	return target.hit_node


## Where this ray first enters the visible geometry of `node`, or null when it
## misses it entirely. Tested against each mesh's own AABB in that mesh's local
## space, so a rotated part is judged in its own frame.
static func _visual_entry(node: Node3D, from: Vector3, to: Vector3) -> Variant:
	if not is_instance_valid(node):
		return null
	var span := from.distance_to(to)
	if span <= 0.0:
		return null
	var dir := (to - from) / span

	var best: Variant = null
	var best_distance := INF
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.append(child)
		var mesh_instance := n as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null \
				or not mesh_instance.is_visible_in_tree():
			continue
		var to_local := mesh_instance.global_transform.affine_inverse()
		var box := mesh_instance.mesh.get_aabb().grow(VISUAL_MARGIN)
		var local_hit: Variant = box.intersects_ray(to_local * from, to_local.basis * dir)
		if local_hit == null:
			continue
		var local_point: Vector3 = local_hit
		var world: Vector3 = mesh_instance.global_transform * local_point
		var along := (world - from).dot(dir)
		if along < -VISUAL_MARGIN or along > span:
			continue
		if along < best_distance:
			best_distance = along
			best = world

	return best


static func _get_front_hit(
		space_state: PhysicsDirectSpaceState3D,
		from: Vector3,
		to: Vector3,
		mask: int,
		collide_with_bodies: bool,
		collide_with_areas: bool,
		exclude: Array[RID]) -> Dictionary:
	if mask == 0 or (not collide_with_bodies and not collide_with_areas):
		return {}

	if collide_with_bodies and collide_with_areas:
		var area_query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
		area_query.collide_with_bodies = false
		area_query.collide_with_areas = true
		var area_hit := space_state.intersect_ray(area_query)

		var body_query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
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

	var query := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
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
