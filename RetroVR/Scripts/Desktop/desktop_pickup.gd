## DesktopPickup — mouse-driven object pickup for desktop (non-VR) mode.
##
## Attach to XRCamera3D.  When XR is not active:
##   Left-click             — pick up the XRToolsPickable under the cursor.
##   Shift + Left-click     — drop the currently held object.
##   Scroll up/down    — push/pull the held object along the camera ray.
##                       (Disabled for FPS-snap objects.)
##   Middle-mouse drag — rotate the held object in place (aircraft controls:
##                       mouse right yaws the far side right, mouse up pitches
##                       the far side up). Shift + horizontal drag rolls it
##                       (right = clockwise). (Disabled for FPS-snap objects.)
##
## FPS-snap mode:
##   Objects with a truthy "desktop_fps_snap" property (e.g. the RayGun) are
##   locked to a fixed lower-right offset from the camera instead of floating
##   freely on the ray.  This gives an FPS-style weapon view.  The hand pivot's
##   orientation matches the camera so the weapon always aims where you look.
##
## Objects must have collision on layer 3 ("Pickable") to be grabbable.
##
## The "fake hand" (_hand_pivot, group "desktop_hand") is an invisible Node3D
## child that acts as the grabber.  XRToolsGrabDriver follows its
## global_transform, so moving/rotating the pivot moves/rotates the held object.
extends Node3D

const InteractionTargetType := preload("res://Scripts/Interaction/interaction_target.gd")

## Collision layer 3 ("Pickable") = bit 2 = value 4
const PICKABLE_MASK := 4

## Scroll step in metres
const SCROLL_STEP := 0.15
const MIN_DIST    := 0.15
const MAX_DIST    := 5.0

## Mouse sensitivity for rotation (radians per pixel)
const ROT_SENSITIVITY := 0.008

## FPS-snap local offset from camera: right, down, forward.
## Applied as a Transform3D in camera-local space so the weapon is always
## in the same screen-space corner regardless of where the player looks.
const FPS_SNAP_LOCAL := Transform3D(Basis.IDENTITY, Vector3(0.20, -0.22, -0.45))

var _held_object : XRToolsPickable = null
var _grab_dist   : float = 1.5

var _raycast     : RayCast3D = null
var _hand_pivot  : Node3D    = null
var _desktop_pointer : XRToolsDesktopFunctionPointer = null

var _middle_held : bool = false
var _hovered_target : Node3D = null


func _ready() -> void:
	# Pickup raycast aimed straight ahead (-Z) from the camera
	_raycast = RayCast3D.new()
	_raycast.name = "PickupRay"
	_raycast.collision_mask      = PICKABLE_MASK
	_raycast.collide_with_bodies = true
	_raycast.collide_with_areas  = true
	_raycast.target_position     = Vector3(0, 0, -MAX_DIST)
	_raycast.enabled             = true
	add_child(_raycast)

	# Invisible pivot that the grabbed object follows.
	# Uses DesktopHandPivot script to satisfy XRToolsPickable's grabber interface
	# (picked_up_ranged property + drop_object() callback).
	# Placed in the "desktop_hand" group so ray_gun.gd / retro_controller.gd
	# can detect desktop-grab in their _on_grabbed_signal handlers.
	var pivot_script := load("res://Scripts/Desktop/desktop_hand_pivot.gd")
	_hand_pivot = Node3D.new()
	_hand_pivot.set_script(pivot_script)
	_hand_pivot.name = "DesktopHand"
	_hand_pivot.add_to_group("desktop_hand")
	_hand_pivot._owner_pickup = weakref(self)
	add_child(_hand_pivot)

	_desktop_pointer = get_node_or_null("FunctionDesktopPointer") as XRToolsDesktopFunctionPointer


func _unhandled_input(event: InputEvent) -> void:
	# Only active in desktop mode
	if get_viewport().use_xr:
		return

	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		match mbe.button_index:
			MOUSE_BUTTON_LEFT:
				if mbe.pressed:
					if _held_object:
						# Shift+click drops any held object.
						# Plain click also drops non-FPS-snap objects (books, controllers, etc.)
						# so the user doesn't need Shift for those.
						# FPS-snap objects (ray gun) require Shift+click to drop because
						# plain left-click is the shoot/trigger action while the gun is held.
						# Objects with desktop_shift_drop (mouse) do too — plain click is
						# their own LEFT button while held.
						if mbe.shift_pressed or not (_is_fps_snap() or _needs_shift_drop()):
							_drop()
							get_viewport().set_input_as_handled()
					else:
						_try_grab()

			MOUSE_BUTTON_MIDDLE:
				_middle_held = mbe.pressed

			MOUSE_BUTTON_WHEEL_UP:
				if _held_object and not _is_fps_snap():
					_grab_dist = clampf(_grab_dist - SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

			MOUSE_BUTTON_WHEEL_DOWN:
				if _held_object and not _is_fps_snap():
					_grab_dist = clampf(_grab_dist + SCROLL_STEP, MIN_DIST, MAX_DIST)
					get_viewport().set_input_as_handled()

	elif event is InputEventMouseMotion and _middle_held:
		if _held_object and not _is_fps_snap():
			var delta := (event as InputEventMouseMotion).relative
			# Aircraft semantics (nose = far side, pointing away from the camera):
			# mouse right → nose yaws right, mouse up → nose pitches up.
			# Shift+drag horizontal → roll (right = roll right / clockwise).
			# Axes are built in world space and premultiplied onto the pivot's
			# global basis — Node3D.rotate() expects parent-space axes, so feeding
			# it world-space camera axes skewed the rotation whenever the camera
			# was turned.
			var pitch_axis := global_transform.basis.x.normalized()
			var roll_axis := (-global_transform.basis.z).normalized()
			var flat_fwd := -global_transform.basis.z
			flat_fwd.y = 0.0
			if flat_fwd.length_squared() > 0.0001:
				roll_axis = flat_fwd.normalized()
				pitch_axis = roll_axis.cross(Vector3.UP).normalized()
			var basis := _hand_pivot.global_basis
			if (event as InputEventMouseMotion).shift_pressed:
				basis = Basis(roll_axis, delta.x * ROT_SENSITIVITY) * basis
			else:
				basis = Basis(Vector3.UP, -delta.x * ROT_SENSITIVITY) * basis
			basis = Basis(pitch_axis, -delta.y * ROT_SENSITIVITY) * basis
			_hand_pivot.global_basis = basis.orthonormalized()
		# Always consume mouse motion while MMB is held so MovementDesktopTurn
		# doesn't also rotate the player.
		get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	_update_reticle_highlight()

	if not _held_object:
		return
	if get_viewport().use_xr:
		_drop()
		return

	if _is_fps_snap():
		# Lock weapon to camera-local FPS slot — orientation tracks camera exactly
		# so the barrel always points straight ahead.
		_hand_pivot.global_transform = global_transform * FPS_SNAP_LOCAL
	else:
		# Standard ray-hold: slide along camera forward at the stored distance
		var fwd := -global_transform.basis.z.normalized()
		_hand_pivot.global_position = global_position + fwd * _grab_dist


## True while the desktop hand is holding something (spawn-into-hand gate).
func is_holding() -> bool:
	return _held_object != null


## Grab a freshly spawned pickable into the desktop hand (spawn-into-hand).
func grab_spawned(pickable: XRToolsPickable) -> void:
	if _held_object or not is_instance_valid(pickable):
		return
	_grab_target(pickable)


## Cast ray and grab the first XRToolsPickable hit.
func _try_grab() -> void:
	if _held_object:
		_drop()
		return

	var interaction := _resolve_interaction_target(true)
	if not interaction.can_grab or not is_instance_valid(interaction.action_node):
		return

	_grab_target(interaction.action_node)


## Drop the currently held object.
func _drop() -> void:
	if _held_object:
		# Only when the modifier was actually required — a plain-click drop taught
		# the player nothing.
		if _is_fps_snap() or _needs_shift_drop():
			HeldHint.note_on(_held_object, &"drop_desktop")
		var obj := _held_object
		_held_object = null
		if obj.is_picked_up() and obj.get_picked_up_by() == _hand_pivot:
			obj.let_go(_hand_pivot, Vector3.ZERO, Vector3.ZERO)
			obj.sleeping = false
	_middle_held = false


## Called by DesktopHandPivot.drop_object() when pickable.gd notifies the
## grabber of a drop (e.g. from a snap zone or external pickable.drop() call).
func _on_pivot_drop_object() -> void:
	if _held_object and _held_object.is_picked_up() and _held_object.get_picked_up_by() == _hand_pivot:
		var obj := _held_object
		_held_object = null
		obj.let_go(_hand_pivot, Vector3.ZERO, Vector3.ZERO)
		obj.sleeping = false
		_middle_held = false
		return
	_held_object = null
	_middle_held = false


## Returns true when the held object wants FPS-snap positioning.
func _is_fps_snap() -> bool:
	return _held_object != null and _held_object.get("desktop_fps_snap")


## True when the held object claims plain left-click as its own input
## (RetroMouse) — dropping then needs Shift+click, like the ray gun.
func _needs_shift_drop() -> bool:
	return _held_object != null and _held_object.get("desktop_shift_drop") == true


func _update_reticle_highlight() -> void:
	if get_viewport().use_xr or _held_object:
		_set_hovered_target(null)
		return

	var interaction := _resolve_interaction_target(false)
	if not interaction.can_grab or not is_instance_valid(interaction.highlight_node):
		_set_hovered_target(null)
		return

	_set_hovered_target(interaction.highlight_node)


func _set_hovered_target(target: Node3D) -> void:
	if target == _hovered_target:
		return

	if _hovered_target and _hovered_target.has_method("request_highlight"):
		_hovered_target.request_highlight(self, false)

	_hovered_target = target

	if _hovered_target and _hovered_target.has_method("request_highlight"):
		_hovered_target.request_highlight(self, true)


func _grab_target(target: Node3D) -> void:
	var pickable: XRToolsPickable = null
	var snap_zone := target as XRToolsSnapZone
	if snap_zone:
		pickable = snap_zone.picked_up_object as XRToolsPickable
		if not pickable:
			return
		snap_zone.drop_object()
	else:
		pickable = target as XRToolsPickable

	if not pickable or not pickable.can_pick_up(_hand_pivot):
		return

	# Position the pivot at the object's origin so the grab offset is ~zero,
	# giving clean behaviour for both ray-hold and FPS-snap modes.
	_grab_dist = clampf(
		global_position.distance_to(pickable.global_position),
		MIN_DIST, MAX_DIST)
	_hand_pivot.global_transform = pickable.global_transform

	_set_hovered_target(null)
	pickable.pick_up(_hand_pivot)
	_held_object = pickable


func _resolve_interaction_target(refresh: bool) -> InteractionTarget:
	if not is_instance_valid(_desktop_pointer):
		return InteractionTargetType.none()

	if refresh:
		return _desktop_pointer.resolve_interaction_target()
	return _desktop_pointer.get_resolved_target()
