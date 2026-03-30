## DesktopPickup — mouse-driven object pickup for desktop (non-VR) mode.
##
## Attach to XRCamera3D.  When XR is not active:
##   Left-click       — grab the XRToolsPickable under the cursor ray, or drop
##                      the currently held object.
##   Scroll up/down   — push/pull the held object along the camera ray.
##   Middle-mouse drag — rotate the held object (yaw = mouse X, pitch = mouse Y).
##
## Objects must have collision on layer 3 ("Pickable") to be grabbable.
##
## The "fake hand" (_hand_pivot) is an invisible Node3D child that acts as the
## grabber.  XRToolsGrabDriver follows its global_transform, so moving/rotating
## the pivot moves/rotates the held object.
extends Node3D

## Collision layer 3 ("Pickable") = bit 2 = value 4
const PICKABLE_MASK := 4

## Scroll step in metres
const SCROLL_STEP := 0.15
const MIN_DIST    := 0.3
const MAX_DIST    := 5.0

## Mouse sensitivity for rotation (radians per pixel)
const ROT_SENSITIVITY := 0.008

var _held_object : XRToolsPickable = null
var _grab_dist   : float = 1.5

var _raycast     : RayCast3D = null
var _hand_pivot  : Node3D    = null

var _middle_held : bool = false


func _ready() -> void:
	# Pickup raycast aimed straight ahead (-Z) from the camera
	_raycast = RayCast3D.new()
	_raycast.name = "PickupRay"
	_raycast.collision_mask    = PICKABLE_MASK
	_raycast.collide_with_bodies = true
	_raycast.collide_with_areas  = false
	_raycast.target_position   = Vector3(0, 0, -MAX_DIST)
	_raycast.enabled           = true
	add_child(_raycast)

	# Invisible pivot that the grabbed object follows
	_hand_pivot = Node3D.new()
	_hand_pivot.name = "DesktopHand"
	add_child(_hand_pivot)


func _unhandled_input(event: InputEvent) -> void:
	# Only active in desktop mode
	if get_viewport().use_xr:
		return

	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		match mbe.button_index:
			MOUSE_BUTTON_LEFT:
				if mbe.pressed:
					_try_grab()
				else:
					_drop()

			MOUSE_BUTTON_MIDDLE:
				_middle_held = mbe.pressed

			MOUSE_BUTTON_WHEEL_UP:
				if _held_object:
					_grab_dist = clampf(_grab_dist - SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_WHEEL_DOWN:
				if _held_object:
					_grab_dist = clampf(_grab_dist + SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _middle_held and _held_object:
		var delta := (event as InputEventMouseMotion).relative
		# Yaw around camera's up axis, pitch around camera's right axis
		_hand_pivot.rotate(global_transform.basis.y.normalized(), -delta.x * ROT_SENSITIVITY)
		_hand_pivot.rotate(global_transform.basis.x.normalized(), -delta.y * ROT_SENSITIVITY)
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	if not _held_object:
		return
	if get_viewport().use_xr:
		_drop()
		return
	# Slide the pivot along the camera's forward ray
	var fwd := -global_transform.basis.z.normalized()
	_hand_pivot.global_position = global_position + fwd * _grab_dist


## Cast ray and grab the first XRToolsPickable hit.
func _try_grab() -> void:
	if _held_object:
		_drop()
		return

	_raycast.force_raycast_update()
	if not _raycast.is_colliding():
		return

	var collider := _raycast.get_collider()
	var pickable := _find_pickable(collider)
	if not pickable or pickable.is_picked_up():
		return

	# Position the pivot at the object's origin so the grab offset is ~zero,
	# giving clean rotation behaviour when the player uses the middle mouse.
	_grab_dist = clampf(
		global_position.distance_to(pickable.global_position),
		MIN_DIST, MAX_DIST)
	_hand_pivot.global_transform = pickable.global_transform

	pickable.pick_up(_hand_pivot)
	_held_object = pickable


## Drop the currently held object.
func _drop() -> void:
	if _held_object:
		_held_object.drop()
		_held_object = null
	_middle_held = false


## Walk up the collision hierarchy to find an XRToolsPickable ancestor.
func _find_pickable(node: Node) -> XRToolsPickable:
	var n := node
	while n:
		if n is XRToolsPickable:
			return n as XRToolsPickable
		n = n.get_parent()
	return null
