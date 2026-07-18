@tool
@icon("res://addons/godot-xr-tools/editor/icons/function.svg")
class_name XRToolsFunctionPickup
extends XRToolsHandPalmOffset


## XR Tools Function Pickup Script
##
## This script implements picking up of objects. Most pickable
## objects are instances of the [XRToolsPickable] class.
##
## Additionally this script can work in conjunction with the
## [XRToolsMovementProvider] class support climbing. Most climbable objects are
## instances of the [XRToolsClimbable] class.


## Signal emitted when the pickup picks something up
signal has_picked_up(what)

## Signal emitted when the pickup drops something
signal has_dropped


# Default pickup collision mask of 3:pickable and 19:handle
const DEFAULT_GRAB_MASK := 0b0000_0000_0000_0100_0000_0000_0000_0100

# Default pickup collision mask of 3:pickable
const DEFAULT_RANGE_MASK := 0b0000_0000_0000_0000_0000_0000_0000_0100

# Constant for worst-case grab distance
const MAX_GRAB_DISTANCE2: float = 1000000.0

# Class for storing copied collision data
class CopiedCollision extends RefCounted:
	var collision_shape : CollisionShape3D
	var org_transform : Transform3D

## Pickup enabled property
@export var enabled : bool = true

## Grip controller axis
@export var pickup_axis_action : String = "grip"

## Action controller button
@export var action_button_action : String = "trigger_click"

## Grab distance
@export var grab_distance : float = 0.3: set = _set_grab_distance

## Grab collision mask
@export_flags_3d_physics \
		var grab_collision_mask : int = DEFAULT_GRAB_MASK: set = _set_grab_collision_mask

## If true, ranged-grabbing is enabled
@export var ranged_enable : bool = true

## Ranged-grab distance
@export var ranged_distance : float = 5.0: set = _set_ranged_distance

## Ranged-grab angle
@export_range(0.0, 45.0) var ranged_angle : float = 5.0: set = _set_ranged_angle

## Ranged-grab collision mask
@export_flags_3d_physics \
		var ranged_collision_mask : int = DEFAULT_RANGE_MASK: set = _set_ranged_collision_mask

## Throw impulse factor
@export var impulse_factor : float = 1.0

## Throw velocity averaging
@export var velocity_samples: int = 5


# Public fields
var closest_object : Node3D = null
var picked_up_object : Node3D = null
var picked_up_ranged : bool = false
var grip_pressed : bool = false

# Private fields
var _object_in_grab_area := Array()
var _object_in_ranged_area := Array()
var _velocity_averager := XRToolsVelocityAverager.new(velocity_samples)
var _grab_area : Area3D
var _grab_collision : CollisionShape3D
var _ranged_area : Area3D
var _ranged_collision : CollisionShape3D
var _active_copied_collisions : Array[CopiedCollision]

# Ray-pointer grab constants
const RAY_GRAB_DISTANCE_MIN := 0.3
const RAY_GRAB_DISTANCE_MAX := 10.0
const RAY_GRAB_SPEED := 3.0  # metres per second at full stick deflection
const RAY_GRAB_ROTATE_SPEED := 2.5  # radians per second at full stick deflection

# Ray-pointer grab state
var _ray_pointer : XRToolsFunctionPointer = null   # sibling FunctionPointer
var _pointer_highlighted : XRToolsPickable = null  # object highlighted by the laser
var _ray_grab_object : XRToolsPickable = null      # object currently held via the ray
var _ray_grab_distance : float = 0.0              # hold distance along the ray
var _ray_grab_other_controller : XRController3D = null
var _locomotion_manager: LocomotionManager = null
var _ray_grab_block_owner: StringName = &"ray_grab"
# Accumulated rotation tracked independently of the physics body — prevents
# _direct_state_changed from corrupting our rotation between physics ticks.
var _ray_grab_basis : Basis = Basis.IDENTITY

## Collision hand (if applicable)
@onready var _collision_hand : XRToolsCollisionHand

## Grip threshold (from configuration)
@onready var _grip_threshold : float = XRTools.get_grip_threshold()


# Add support for is_xr_class on XRTools classes
func is_xr_class(xr_name:  String) -> bool:
	return xr_name == "XRToolsFunctionPickup"


# Called when the node enters the scene tree for the first time.
func _ready():
	# Skip creating grab-helpers if in the editor
	if Engine.is_editor_hint():
		return

	# Create the grab collision shape
	_grab_collision = CollisionShape3D.new()
	_grab_collision.set_name("GrabCollisionShape")
	_grab_collision.shape = SphereShape3D.new()
	_grab_collision.shape.radius = grab_distance

	# Create the grab area
	_grab_area = Area3D.new()
	_grab_area.set_name("GrabArea")
	_grab_area.collision_layer = 0
	_grab_area.collision_mask = grab_collision_mask
	_grab_area.add_child(_grab_collision)
	_grab_area.area_entered.connect(_on_grab_entered)
	_grab_area.body_entered.connect(_on_grab_entered)
	_grab_area.area_exited.connect(_on_grab_exited)
	_grab_area.body_exited.connect(_on_grab_exited)
	add_child(_grab_area)

	# Create the ranged collision shape
	_ranged_collision = CollisionShape3D.new()
	_ranged_collision.set_name("RangedCollisionShape")
	_ranged_collision.shape = CylinderShape3D.new()
	_ranged_collision.transform.basis = Basis(Vector3.RIGHT, PI/2)

	# Create the ranged area
	_ranged_area = Area3D.new()
	_ranged_area.set_name("RangedArea")
	_ranged_area.collision_layer = 0
	_ranged_area.collision_mask = ranged_collision_mask
	_ranged_area.add_child(_ranged_collision)
	_ranged_area.area_entered.connect(_on_ranged_entered)
	_ranged_area.body_entered.connect(_on_ranged_entered)
	_ranged_area.area_exited.connect(_on_ranged_exited)
	_ranged_area.body_exited.connect(_on_ranged_exited)
	add_child(_ranged_area)

	# Update the colliders
	_update_colliders()

	# Find the sibling FunctionPointer (deferred so all scene nodes are ready)
	call_deferred("_find_ray_pointer")


# Called when we're added to the tree
func _enter_tree():
	super._enter_tree()

	_collision_hand = XRToolsCollisionHand.find_ancestor(self)

	# Monitor Grab Button
	if _controller:
		_controller.button_pressed.connect(_on_button_pressed)
		_controller.button_released.connect(_on_button_released)

# Called when we exit the tree
func _exit_tree():
	if _controller:
		_controller.button_pressed.disconnect(_on_button_pressed)
		_controller.button_released.disconnect(_on_button_released)

	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)

	if _collision_hand:
		_remove_copied_collisions()
		_collision_hand = null

	super._exit_tree()


# Drive the ray-grabbed body from _physics_process so the transform is written
# AFTER _direct_state_changed (which runs earlier in the same physics tick) and
# is never overwritten by the physics engine before the render.
func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if is_instance_valid(_ray_grab_object):
		_process_ray_grab(delta)


# Called on each frame to update the pickup
func _process(delta):
	super._process(delta)

	# Do not process if in the editor
	if Engine.is_editor_hint():
		return

	# Skip if disabled, or the controller isn't active
	if !enabled or !_controller.get_is_active():
		return

	# Handle our grip
	var grip_value = _controller.get_float(pickup_axis_action)
	if (grip_pressed and grip_value < (_grip_threshold - 0.1)):
		grip_pressed = false
		_on_grip_release()
	elif (!grip_pressed and grip_value > (_grip_threshold + 0.1)):
		grip_pressed = true
		_on_grip_pressed()

	# Calculate average velocity (also tracks ray-grabbed objects for throw)
	if is_instance_valid(picked_up_object) and picked_up_object.is_picked_up():
		_velocity_averager.add_transform(delta, picked_up_object.global_transform)
	elif is_instance_valid(_ray_grab_object):
		_velocity_averager.add_transform(delta, _ray_grab_object.global_transform)
	else:
		_velocity_averager.add_transform(delta, global_transform)

	_update_copied_collisions()

	# Ray-grab position/rotation is handled in _physics_process, which runs
	# after _direct_state_changed — so the physics body is never overwritten by
	# the physics tick between our write and the render.
	if is_instance_valid(_ray_grab_object):
		return

	# Always update closest proximity object first — it takes priority over the laser.
	_update_closest_object()
	# Only show pointer highlight when nothing is close enough to grab by hand.
	if not is_instance_valid(closest_object):
		_process_pointer_highlight()
	else:
		_set_pointer_highlight(null)


## Find an [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for an [XRToolsFunctionPickup]
## assuming the node is a sibling of the pickup under an [XRController3D].
static func find_instance(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_xr_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Find the left [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for the left controller
## [XRToolsFunctionPickup] assuming the node is a sibling of the [XOrigin3D].
static func find_left(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_left_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Find the right [XRToolsFunctionPickup] node.
##
## This function searches from the specified node for the right controller
## [XRToolsFunctionPickup] assuming the node is a sibling of the [XROrigin3D].
static func find_right(node : Node) -> XRToolsFunctionPickup:
	return XRTools.find_xr_child(
		XRHelpers.get_right_controller(node),
		"*",
		"XRToolsFunctionPickup") as XRToolsFunctionPickup


## Get the [XRController3D] driving this pickup.
func get_controller() -> XRController3D:
	return _controller


# Called when the grab distance has been modified
func _set_grab_distance(new_value: float) -> void:
	grab_distance = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the grab collision mask has been modified
func _set_grab_collision_mask(new_value: int) -> void:
	grab_collision_mask = new_value
	if is_inside_tree() and _grab_area:
		_grab_area.collision_mask = new_value


# Called when the ranged-grab distance has been modified
func _set_ranged_distance(new_value: float) -> void:
	ranged_distance = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the ranged-grab angle has been modified
func _set_ranged_angle(new_value: float) -> void:
	ranged_angle = new_value
	if is_inside_tree():
		_update_colliders()


# Called when the ranged-grab collision mask has been modified
func _set_ranged_collision_mask(new_value: int) -> void:
	ranged_collision_mask = new_value
	if is_inside_tree() and _ranged_area:
		_ranged_area.collision_mask = new_value


# Update the colliders geometry
func _update_colliders() -> void:
	# Update the grab sphere
	if _grab_collision:
		_grab_collision.shape.radius = grab_distance

	# Update the ranged-grab cylinder
	if _ranged_collision:
		_ranged_collision.shape.radius = tan(deg_to_rad(ranged_angle)) * ranged_distance
		_ranged_collision.shape.height = ranged_distance
		_ranged_collision.transform.origin.z = -ranged_distance * 0.5


# Called when an object enters the grab sphere
func _on_grab_entered(target: Node3D) -> void:
	# reject objects which don't support picking up
	if not target.has_method('pick_up'):
		return

	# ignore objects already known
	if _object_in_grab_area.find(target) >= 0:
		return

	# Add to the list of objects in grab area
	_object_in_grab_area.push_back(target)


# Called when an object enters the ranged-grab cylinder
func _on_ranged_entered(target: Node3D) -> void:
	# reject objects which don't support picking up rangedly
	if not 'can_ranged_grab' in target or not target.can_ranged_grab:
		return

	# ignore objects already known
	if _object_in_ranged_area.find(target) >= 0:
		return

	# Add to the list of objects in grab area
	_object_in_ranged_area.push_back(target)


# Called when an object exits the grab sphere
func _on_grab_exited(target: Node3D) -> void:
	_object_in_grab_area.erase(target)


# Called when an object exits the ranged-grab cylinder
func _on_ranged_exited(target: Node3D) -> void:
	_object_in_ranged_area.erase(target)


# Update the closest object field with the best choice of grab
func _update_closest_object() -> void:
	# Find the closest object we can pickup
	var new_closest_obj: Node3D = null
	if not picked_up_object:
		# Find the closest in grab area
		new_closest_obj = _get_closest_grab()
		if not new_closest_obj and ranged_enable:
			# Find closest in ranged area
			new_closest_obj = _get_closest_ranged()

	# Skip if no change
	if closest_object == new_closest_obj:
		return

	# remove highlight on old object
	if is_instance_valid(closest_object):
		closest_object.request_highlight(self, false)

	# add highlight to new object
	closest_object = new_closest_obj
	if is_instance_valid(closest_object):
		closest_object.request_highlight(self, true)


# Find the pickable object closest to our hand's grab location
#
# LOCAL PATCH (RetroVR): snap zones only compete when the hand is INSIDE the
# zone's own grab sphere (a deliberate reach at the socket), and then they WIN
# over pickables. Plain origin-distance ranking let a zone buried inside a
# small pickable — a handheld's cartridge slot — steal grabs aimed at the
# body (the slot origin is nearer than the body's centre from behind), while
# any bias in the other direction made short bodies (DS) steal deliberate
# pinches at the protruding cart stub.
func _get_closest_grab() -> Node3D:
	var new_closest_obj: Node3D = null
	var new_closest_distance := MAX_GRAB_DISTANCE2
	var best_zone: Node3D = null
	var best_zone_distance := MAX_GRAB_DISTANCE2
	for o in _object_in_grab_area:
		# skip objects that can not be picked up
		if not o.can_pick_up(self):
			continue

		var distance_squared := global_transform.origin.distance_squared_to(
				o.global_transform.origin)
		if o is XRToolsSnapZone:
			var zone_r: float = o.grab_distance
			if distance_squared <= zone_r * zone_r \
					and distance_squared < best_zone_distance:
				best_zone = o
				best_zone_distance = distance_squared
			continue

		# Save if this object is closer than the current best
		if distance_squared < new_closest_distance:
			new_closest_obj = o
			new_closest_distance = distance_squared

	# A directly-touched socket beats nearby pickables
	if best_zone != null:
		return best_zone

	# Return best object
	return new_closest_obj


# Find the rangedly-pickable object closest to our hand's pointing direction
func _get_closest_ranged() -> Node3D:
	var new_closest_obj: Node3D = null
	var new_closest_angle_dp := cos(deg_to_rad(ranged_angle))
	var hand_forwards := -global_transform.basis.z
	for o in _object_in_ranged_area:
		# skip objects that can not be picked up
		if not o.can_pick_up(self):
			continue

		# Save if this object is closer than the current best
		var object_direction: Vector3 = o.global_transform.origin - global_transform.origin
		object_direction = object_direction.normalized()
		var angle_dp := hand_forwards.dot(object_direction)
		if angle_dp > new_closest_angle_dp:
			new_closest_obj = o
			new_closest_angle_dp = angle_dp

	# Return best object
	return new_closest_obj


## Drop the currently held object
func drop_object() -> void:
	if not is_instance_valid(picked_up_object):
		return

	# Remove any copied collision objects
	_remove_copied_collisions()

	# let go of this object
	picked_up_object.let_go(
		self,
		_velocity_averager.linear_velocity() * impulse_factor,
		_velocity_averager.angular_velocity())
	picked_up_object = null

	if _collision_hand:
		# Reset the held weight
		_collision_hand.set_held_weight(0.0)

	emit_signal("has_dropped")


func _pick_up_object(target: Node3D) -> void:
	# check if already holding an object
	if is_instance_valid(picked_up_object):
		# skip if holding the target object
		if picked_up_object == target:
			return
		# holding something else? drop it
		drop_object()

	# skip if target null or freed
	if not is_instance_valid(target):
		return

	# Handle snap-zone
	var snap := target as XRToolsSnapZone
	if snap:
		target = snap.picked_up_object
		snap.drop_object()

	# Re-check can_pick_up here: state may have changed since closest_object was last updated
	# (e.g. another controller grabbed the same object on the same frame).
	if target.has_method("can_pick_up") and not target.can_pick_up(self):
		return

	# Pick up our target. Note, target may do instant drop_and_free
	picked_up_ranged = not _object_in_grab_area.has(target)
	picked_up_object = target
	target.pick_up(self)

	# If object picked up then emit signal
	if is_instance_valid(picked_up_object):
		_copy_collisions()

		picked_up_object.request_highlight(self, false)
		emit_signal("has_picked_up", picked_up_object)


# Copy collision shapes on the held object to our collision hand (if applicable).
# If we're two handing an object, both collision hands will get copies.
func _copy_collisions():
	if not is_instance_valid(_collision_hand):
		return

	if not is_instance_valid(picked_up_object) or not picked_up_object is RigidBody3D:
		return

	for child in picked_up_object.get_children():
		if child is CollisionShape3D and not child.disabled:

			var copied_collision : CopiedCollision = CopiedCollision.new()
			copied_collision.collision_shape = CollisionShape3D.new()
			copied_collision.collision_shape.shape = child.shape
			copied_collision.org_transform = child.transform

			_collision_hand.add_child(copied_collision.collision_shape, false, Node.INTERNAL_MODE_BACK)
			copied_collision.collision_shape.global_transform = picked_up_object.global_transform * \
				copied_collision.org_transform

			_active_copied_collisions.push_back(copied_collision)


# Adjust positions of our collisions to match actual location of object
func _update_copied_collisions():
	if is_instance_valid(_collision_hand) and is_instance_valid(picked_up_object):
		for copied_collision : CopiedCollision in _active_copied_collisions:
			if is_instance_valid(copied_collision.collision_shape):
				copied_collision.collision_shape.global_transform = picked_up_object.global_transform * \
					copied_collision.org_transform


# Remove copied collision shapes
func _remove_copied_collisions():
	if is_instance_valid(_collision_hand):
		for copied_collision : CopiedCollision in _active_copied_collisions:
			if is_instance_valid(copied_collision.collision_shape):
				_collision_hand.remove_child(copied_collision.collision_shape)
				copied_collision.collision_shape.queue_free()

	_active_copied_collisions.clear()


func _on_button_pressed(p_button) -> void:
	if p_button == action_button_action and is_instance_valid(picked_up_object):
		if picked_up_object.has_method("action"):
			picked_up_object.action()

		if picked_up_object.has_method("controller_action"):
			picked_up_object.controller_action(_controller)


func _on_button_released(p_button) -> void:
	if p_button == action_button_action and is_instance_valid(picked_up_object):
		if picked_up_object.has_method("action_release"):
			picked_up_object.action_release()

		if picked_up_object.has_method("controller_action_release"):
			picked_up_object.controller_action_release(_controller)


func _on_grip_pressed() -> void:
	if is_instance_valid(picked_up_object) and !picked_up_object.press_to_hold:
		drop_object()
	elif is_instance_valid(closest_object):
		# Proximity grab takes priority over the laser
		_pick_up_object(closest_object)
	elif is_instance_valid(_pointer_highlighted) and not is_instance_valid(picked_up_object):
		# Nothing close — grab along the ray
		_start_ray_grab(_pointer_highlighted)


func _on_grip_release() -> void:
	if is_instance_valid(_ray_grab_object):
		_end_ray_grab()
	elif is_instance_valid(picked_up_object) and picked_up_object.press_to_hold:
		drop_object()


# ----------  Ray-pointer grab helpers  ----------

# Locate the sibling FunctionPointer; deferred so all controller children are ready.
# Also cache locomotion nodes globally by name — identical to SpawnMenuController.
func _find_ray_pointer() -> void:
	if Engine.is_editor_hint() or not _controller:
		return
	for child in _controller.get_children():
		if child is XRToolsFunctionPointer:
			_ray_pointer = child
			break
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	if _controller.tracker == &"left_hand":
		_ray_grab_other_controller = XRHelpers.get_right_controller(self)
		_ray_grab_block_owner = &"ray_grab_left"
	else:
		_ray_grab_other_controller = XRHelpers.get_left_controller(self)
		_ray_grab_block_owner = &"ray_grab_right"


# Resolve a raycast collider to the owning XRToolsPickable.
# The collider may be the pickable RigidBody itself, or a PointerArea (StaticBody3D)
# that is a direct child of the pickable (see PointerArea pattern in system.tscn).
func _resolve_pickable(collider: Node3D) -> XRToolsPickable:
	if not collider:
		return null
	var direct := collider as XRToolsPickable
	if direct:
		return direct
	return collider.get_parent() as XRToolsPickable


# Each frame: highlight whichever pickable the laser is currently pointing at.
func _process_pointer_highlight() -> void:
	var new_target: XRToolsPickable = null
	if enabled and _ray_pointer:
		var ray_cast := _ray_pointer.get_node_or_null("RayCast") as RayCast3D
		if ray_cast and ray_cast.is_colliding():
			var body := _resolve_pickable(ray_cast.get_collider())
			if body and body.can_pick_up(self) and not _is_target_ray_grabbed_elsewhere(body):
				new_target = body
	_set_pointer_highlight(new_target)


# Manage the pointer-driven highlight, clearing the old one and setting the new one.
func _set_pointer_highlight(new_target: XRToolsPickable) -> void:
	if new_target == _pointer_highlighted:
		return
	if is_instance_valid(_pointer_highlighted):
		_pointer_highlighted.request_highlight(self, false)
	_pointer_highlighted = new_target
	if is_instance_valid(_pointer_highlighted):
		_pointer_highlighted.request_highlight(self, true)


# Begin holding the target at the distance the ray currently hits it.
func _start_ray_grab(target: XRToolsPickable) -> void:
	if not is_instance_valid(target) or _is_target_ray_grabbed_elsewhere(target):
		return
	# Only one ray-grab allowed at a time — prevents the free hand from grabbing
	# a second object while the other controller is already ray-holding something.
	if _is_any_other_pickup_ray_grabbing():
		return

	_ray_grab_distance = global_transform.origin.distance_to(
			target.global_transform.origin)
	_ray_grab_distance = clampf(
			_ray_grab_distance, RAY_GRAB_DISTANCE_MIN, RAY_GRAB_DISTANCE_MAX)
	_ray_grab_object = target
	_ray_grab_basis = target.global_basis  # seed our independent rotation tracker
	_set_pointer_highlight(null)  # object transitions from "highlighted" to "held"
	# Freeze physics and move to the held layer (mirrors XRToolsPickable.pick_up)
	target.restore_freeze = target.freeze
	target.freeze = true
	target.collision_layer = target.picked_up_layer
	target.collision_mask = 0
	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, true)
	emit_signal("has_picked_up", target)


# Each frame: reposition the ray-held object and adjust distance via thumbstick.
func _process_ray_grab(delta: float) -> void:
	if not is_instance_valid(_ray_grab_object):
		if _locomotion_manager:
			_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
		_ray_grab_object = null
		return
	# Thumbstick Y — up moves away, down moves toward; 10 % dead-zone
	if _controller:
		var stick_y := _controller.get_vector2("primary").y
		if absf(stick_y) > 0.1:
			_ray_grab_distance += stick_y * RAY_GRAB_SPEED * delta
			_ray_grab_distance = clampf(
					_ray_grab_distance, RAY_GRAB_DISTANCE_MIN, RAY_GRAB_DISTANCE_MAX)
	# Compute rotation and position together, then write in ONE transform assignment.
	# Writing global_basis and global_position separately causes the physics server to
	# receive two distinct body_set_state calls with an intermediate (new_basis, old_pos)
	# state. At high frame rates this intermediate state gets rendered, producing a ghost
	# at the original rotation that grows apart as total rotation accumulates.
	var new_basis := _compute_ray_grab_rotation(delta)
	if _ray_pointer:
		var ray_cast := _ray_pointer.get_node_or_null("RayCast") as RayCast3D
		if ray_cast:
			var ray_dir := -ray_cast.global_transform.basis.z
			var new_pos := ray_cast.global_transform.origin + ray_dir * _ray_grab_distance
			var new_transform := Transform3D(new_basis, new_pos)
			_ray_grab_object.global_transform = new_transform
			# Explicitly sync to the physics server — frozen bodies can silently drop the
			# node→physics update, causing _direct_state_changed to restore the stale
			# pickup-time transform on the next physics tick.
			PhysicsServer3D.body_set_state(
					_ray_grab_object.get_rid(),
					PhysicsServer3D.BODY_STATE_TRANSFORM,
					new_transform)
			return
	_ray_grab_object.global_basis = new_basis


func _compute_ray_grab_rotation(delta: float) -> Basis:
	# Read _ray_grab_basis (our own tracker), NOT _ray_grab_object.global_basis.
	# The physics body's basis can be reset by _direct_state_changed mid-sequence;
	# using our own variable keeps the accumulated rotation stable across physics ticks.
	var basis := _ray_grab_basis

	if _ray_grab_other_controller and _ray_grab_other_controller.get_is_active():
		var stick := _ray_grab_other_controller.get_vector2("primary")
		if stick.length_squared() > 0.01:
			# Grab-drag semantics: the face of the object toward the player follows
			# the stick. Stick right → that face moves right (yaw right), stick up →
			# it tips up (pitch up). Positive angle around world UP moves the near
			# face right; negative angle around the player's right axis moves it up.
			var yaw := stick.x * RAY_GRAB_ROTATE_SPEED * delta
			var pitch := -stick.y * RAY_GRAB_ROTATE_SPEED * delta

			# Rotate from the player's viewpoint using the HOLDING controller as the
			# reference (not the headset): left/right yaws around world up (a stable
			# turntable spin); up/down pitches around the holding controller's leveled
			# right axis, so the tilt follows where the ray is pointing. Both axes stay
			# level, so wrist roll never turns the stick directions diagonal.
			var pitch_axis := _controller.global_transform.basis.x.normalized()
			var roll_axis := (-_controller.global_transform.basis.z).normalized()
			var flat_fwd := -_controller.global_transform.basis.z
			flat_fwd.y = 0.0
			if flat_fwd.length_squared() > 0.0001:
				roll_axis = flat_fwd.normalized()
				pitch_axis = roll_axis.cross(Vector3.UP).normalized()

			# Roll mode: hold A/X on the rotating hand — stick X then rolls the
			# object around the ray axis (right = clockwise from the player's view)
			# instead of yawing it.
			var roll_mode := _ray_grab_other_controller.is_button_pressed("ax_button")

			if roll_mode:
				var roll := stick.x * RAY_GRAB_ROTATE_SPEED * delta
				if absf(roll) > 0.001:
					basis = Basis(roll_axis, roll) * basis
			elif absf(yaw) > 0.001:
				basis = Basis(Vector3.UP, yaw) * basis

			if absf(pitch) > 0.001:
				basis = Basis(pitch_axis, pitch) * basis

			basis = basis.orthonormalized()

	_ray_grab_basis = basis
	return basis


# Release the ray-held object and restore its physics.
func _end_ray_grab() -> void:
	if not is_instance_valid(_ray_grab_object):
		_ray_grab_object = null
		return
	_ray_grab_object.freeze = _ray_grab_object.restore_freeze
	_ray_grab_object.collision_mask = _ray_grab_object.original_collision_mask
	_ray_grab_object.collision_layer = _ray_grab_object.original_collision_layer
	# Apply throw velocity so the object can be tossed
	_ray_grab_object.linear_velocity = _velocity_averager.linear_velocity() * impulse_factor
	_ray_grab_object.angular_velocity = _velocity_averager.angular_velocity()
	_ray_grab_object = null
	if _locomotion_manager:
		_locomotion_manager.set_block(_ray_grab_block_owner, LocomotionManager.CHANNEL_ALL, false)
	emit_signal("has_dropped")


## Returns true while an object is held via the ray-pointer grab.
## Used externally (e.g. spawn_menu_controller) to avoid conflicting grabs.
func is_ray_grabbing() -> bool:
	return is_instance_valid(_ray_grab_object)


func is_ray_grabbing_target(target: XRToolsPickable) -> bool:
	return is_instance_valid(target) and _ray_grab_object == target


func _is_any_other_pickup_ray_grabbing() -> bool:
	for pickup in get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false):
		if pickup == self:
			continue
		if pickup is XRToolsFunctionPickup and pickup.is_ray_grabbing():
			return true
	return false


func _is_target_ray_grabbed_elsewhere(target: XRToolsPickable) -> bool:
	if not is_instance_valid(target):
		return false

	for pickup in get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false):
		if pickup == self:
			continue
		if pickup is XRToolsFunctionPickup and pickup.is_ray_grabbing_target(target):
			return true

	return false
