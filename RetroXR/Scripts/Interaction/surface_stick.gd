## SurfaceStick — sticks a pickable to whatever surface it is released against, and
## makes it ride whatever it stuck to.
##
## A child component rather than a base class, for the reason FloatLock gives: the
## things that want this already extend XRToolsPickable and GDScript has one
## inheritance slot.
##
## THE RELEASE IS NOT THE `dropped` SIGNAL. A ray grab is a second, parallel hold:
## XRToolsFunctionPickup._end_ray_grab restores the body itself and never calls
## let_go(), so `dropped` never fires and is_picked_up() is false for the whole
## hold — the addon says as much in its own comment there, which is why a snap zone
## has to be handed a ray-released object explicitly. Since placing a poster on a
## far wall by ray is the main gesture, a dropped-driven stick would work in
## hand-testing and fail in use. The predicate true for ALL THREE holds (hand, snap
## zone, ray) is `freeze`, so the hold is tracked by polling that instead.
class_name SurfaceStick
extends Node

## Emitted after the body has stuck to `target`, and again with null when peeled.
signal stuck_changed(target: Node3D)

## How far in front of the sheet to look for a surface when it is let go.
## How far to look for a surface when the sheet is let go.
##
## Generous on purpose. A player holds a poster UP TO a wall at arm's length and
## lets go; they do not press it against the plaster first. At 0.12 m — which is
## what a test that placed the sheet 2 cm out and perfectly square was happy with
## — every real release missed and the poster fell on the floor.
const REACH := 0.35
## How far along the laser to look. A poster is placed across a room with it.
const AIM_REACH := 6.0
## Clear of the surface, against z-fighting. The room's own framed posters sit 17 mm
## off the wall; a bare sheet only needs enough to not fight the plaster.
const SKIN := 0.002
## What counts as something to stick to: World (1) for the room shell and its
## furniture, and Pickable (3) for the machines and decks standing in it.
##
## Pickable is not optional — a television is an XRToolsPickable on layer 3, not
## world geometry, so a probe that searched only World found the walls and went
## straight through every object in the room.
const SURFACE_MASK := (1 << 0) | (1 << 2)

var target: Node3D = null
var anchor_position := Vector3.ZERO
var anchor_normal := Vector3.FORWARD

var _body: RigidBody3D = null
var _ray: RayCast3D = null
var _was_held := false
var _orig_freeze_mode: int = RigidBody3D.FREEZE_MODE_STATIC
## Where the holder was AIMING when it let go, in world space, or zero.
##
## Set by the owner while a laser holds it. A ray-held poster floats at the
## beam's hold distance with whatever facing it was grabbed with, so probing out
## of its own face finds empty room — the surface the player means is the one
## under the laser, which can be metres away. Aim wins when it is set.
var aim_direction := Vector3.ZERO


static func attach(body: RigidBody3D, ray: RayCast3D) -> SurfaceStick:
	var s := SurfaceStick.new()
	s.name = "SurfaceStick"
	body.add_child(s)
	s._bind(body, ray)
	return s


func _bind(body: RigidBody3D, ray: RayCast3D) -> void:
	_body = body
	_ray = ray
	_orig_freeze_mode = body.freeze_mode
	set_physics_process(true)


func is_stuck() -> bool:
	return target != null and is_instance_valid(target)


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_body):
		return
	# `freeze` is the one predicate every hold sets — see the class comment.
	var held := _body.freeze and not is_stuck()
	if held:
		_was_held = true
		return
	if _was_held:
		_was_held = false
		# Deferred: the release restores a freeze snapshot and applies throw
		# velocity, and both would land on top of anything done here.
		try_stick.call_deferred()


## Look straight out of the sheet's face. Not from the hand: under a ray grab the
## body floats metres away from the controller, so a controller-origin probe finds
## whatever is in front of the PLAYER instead of what the poster is against.
func try_stick() -> void:
	if not is_instance_valid(_body) or is_stuck() or not _body.is_inside_tree():
		return
	var space := _body.get_world_3d().direct_space_state
	if space == null:
		return
	var from := _body.global_position

	# The laser first, when there is one: that is the surface the player chose, and
	# a ray-held sheet floats at the beam's hold distance facing however it was
	# grabbed, so its own face usually looks at nothing.
	if aim_direction.length_squared() > 0.0001:
		var aq := PhysicsRayQueryParameters3D.create(
			from, from + aim_direction.normalized() * AIM_REACH)
		aq.collision_mask = SURFACE_MASK
		aq.exclude = [_body.get_rid()]
		var ah := space.intersect_ray(aq)
		if not ah.is_empty():
			stick_to(ah["collider"] as Node3D, ah["position"] as Vector3,
				(ah["normal"] as Vector3).normalized())
			return

	# Otherwise both faces, nearest wins. Which way round a sheet is held is
	# arbitrary — a poster has a front but a hand does not — so looking only out of
	# its -Z made "held back-to-front" a poster that fell on the floor. Sticking
	# squares it up either way, so the two cases end identically.
	var best: Dictionary = {}
	var best_d := REACH + 1.0
	for dir: Vector3 in [-_body.global_transform.basis.z, _body.global_transform.basis.z]:
		var q := PhysicsRayQueryParameters3D.create(from, from + dir.normalized() * REACH)
		q.collision_mask = SURFACE_MASK
		q.exclude = [_body.get_rid()]
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			continue
		var d: float = from.distance_to(hit["position"] as Vector3)
		if d < best_d:
			best_d = d
			best = hit
	if best.is_empty():
		return
	stick_to(best["collider"] as Node3D, best["position"] as Vector3,
		(best["normal"] as Vector3).normalized())


## Commit against a surface. `point`/`normal` are world space.
func stick_to(collider: Node3D, point: Vector3, normal: Vector3) -> void:
	var host := _host_for(collider)
	if host == null:
		return
	var n := normal.normalized()
	_body.global_transform = _surface_basis(n, point + n * SKIN)

	# Ride it. Same recipe MediaSlot uses to make a disc ride the tray: static
	# freeze, reparent, and an exception so the two colliders do not shove each
	# other. Everything after this is expressed in the host's frame, so carrying
	# the host costs nothing.
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	_body.freeze = true
	if _body.get_parent() != host:
		_body.reparent(host, true)
	if host is CollisionObject3D:
		_body.add_collision_exception_with(host)
	# Physics interpolation is on project-wide; without this the first drawn frame
	# slides in from wherever the body was before the reparent.
	_body.reset_physics_interpolation()

	target = host
	anchor_position = host.to_local(_body.global_position)
	anchor_normal = host.global_transform.basis.inverse() * n
	stuck_changed.emit(host)


## Hand the body back to the room. Called when something picks it up again — a
## grab IS the peel, since every hold restores `freeze` on its own.
func peel() -> void:
	if not is_stuck():
		return
	var host := target
	target = null
	if is_instance_valid(_body):
		if is_instance_valid(host) and host is CollisionObject3D:
			_body.remove_collision_exception_with(host)
		var scene := _body.get_tree().current_scene if _body.is_inside_tree() else null
		if scene != null and _body.get_parent() != scene:
			_body.reparent(scene, true)
		_body.freeze_mode = _orig_freeze_mode
		_body.reset_physics_interpolation()
	stuck_changed.emit(null)


## Re-park after a slot restore. The restore's own _let_go hands gravity back to
## everything it froze, so a poster that was saved stuck has to re-assert itself
## after that sweep rather than during it.
func repark() -> void:
	if not is_instance_valid(_body) or not is_stuck():
		return
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	_body.freeze = true


## The node a poster should hang off: the nearest ancestor that is a spawned object
## or a pickable, else the body that was hit. A wall's StaticBody3D is its own host,
## which is what makes a wall poster reparent to something that never moves.
func _host_for(collider: Node3D) -> Node3D:
	var node: Node = collider
	while node != null:
		if node is XRToolsPickable or node.is_in_group("spawned"):
			return node as Node3D
		if node is StaticBody3D:
			return node as Node3D
		node = node.get_parent()
	return collider


## The sheet's +Z along the surface normal, up as near world-up as the surface
## allows. Same construction retro_mouse uses to lie a mouse on a desk, turned for
## a face rather than a base.
static func _surface_basis(n: Vector3, origin: Vector3) -> Transform3D:
	var up := Vector3.UP - n * Vector3.UP.dot(n)
	if up.length_squared() < 0.0001:
		# Floor or ceiling: no world-up component survives, so pick any axis in
		# the plane and let the sheet lie flat.
		up = Vector3.FORWARD - n * Vector3.FORWARD.dot(n)
	up = up.normalized()
	return Transform3D(Basis(up.cross(n), up, n).orthonormalized(), origin)
