## GripAnchor — anchors a held device onto the grip authored for the hand holding it.
##
## Without an anchor a grab keeps whatever offset the object happened to have when
## it was touched (the precise branch of grab.gd), so a pad grabbed by its corner
## hangs off the corner of the hand at whatever angle it was lying. Anchoring sets
## each grab's frame to the grip point authored for THAT hand:
##
## - One hand: the driver's destination is `hand * anchor⁻¹`, so that hand's grip
##   lands exactly in that hand, position and orientation.
## - Two hands: each grab asks for its own grip, and the driver's built-in blend
##   (grab_driver.gd — 0.5 lerp of the origins, 0.5 slerp of the bases) sits the
##   device between the two hands while keeping its grip geometry.
##
## Used by RetroController (HandLeft/HandRight nodes) and HandheldInput (anchors
## derived from the handheld model's body).
class_name GripAnchor


## Seconds to blend into a new grip, using the grab driver's own LERP state. A
## grip change is a teleport otherwise — most visibly when the second hand lets
## go and the device settles from between the hands into the remaining one.
const BLEND_TIME := 0.12

## How far the pose has to move for that blend to be worth it. Below this the
## grip barely shifted and a blend would only add lag.
const BLEND_MIN_STEP := 0.002
const BLEND_MIN_ANGLE_DEG := 2.0


## Re-anchor every active grab of `pickable`. `provider` must expose
## `grip_anchor(is_left: bool) -> Variant`, returning a Transform3D in the
## pickable's local space, or null to keep the precise as-grabbed offset.
static func refresh(pickable: XRToolsPickable, provider: Object) -> void:
	var driver: XRToolsGrabDriver = pickable._grab_driver
	if driver == null or not is_instance_valid(driver.primary):
		return

	driver.primary.transform = _frame_for(pickable, provider, driver.primary)
	if is_instance_valid(driver.secondary):
		driver.secondary.transform = _frame_for(pickable, provider, driver.secondary)

	# Blend on a real discontinuity. It is not enough to ask whether a grab frame
	# changed: gaining or losing the second hand moves the device without touching
	# either frame, because the driver's own two-hand blend appears or disappears.
	if driver.state == XRToolsGrabDriver.GrabState.SNAP \
			and _is_jump(driver.global_transform, _destination(driver)):
		driver.lerp_start = driver.global_transform
		driver.lerp_time = 0.0
		driver.lerp_duration = BLEND_TIME
		driver.state = XRToolsGrabDriver.GrabState.LERP


## Where the driver will put the device next tick — the same blend grab_driver.gd
## applies (the 0.5 vote is what its drive defaults come to; none of these devices
## use hand grab points, which are the only thing that changes those defaults).
static func _destination(driver: XRToolsGrabDriver) -> Transform3D:
	var dest := driver.primary.by.global_transform * driver.primary.transform.affine_inverse()
	if is_instance_valid(driver.secondary):
		var other := driver.secondary.by.global_transform \
			* driver.secondary.transform.affine_inverse()
		dest = Transform3D(
			dest.basis.slerp(other.basis, 0.5),
			dest.origin.lerp(other.origin, 0.5))
	return dest


static func _is_jump(from: Transform3D, to: Transform3D) -> bool:
	if from.origin.distance_to(to.origin) > BLEND_MIN_STEP:
		return true
	var angle := from.basis.get_rotation_quaternion().angle_to(
		to.basis.get_rotation_quaternion())
	return rad_to_deg(angle) > BLEND_MIN_ANGLE_DEG


static func _frame_for(pickable: XRToolsPickable, provider: Object, grab: Grab) -> Transform3D:
	var ctrl: XRController3D = grab.controller
	if is_instance_valid(ctrl) and provider != null and provider.has_method("grip_anchor"):
		var anchor: Variant = provider.grip_anchor(ctrl.tracker == &"left_hand")
		if anchor is Transform3D:
			return anchor
	# No authored grip for this grabber — a desktop hand, a snap zone, or a device
	# that defines none. Keep it exactly where it is relative to the grabber.
	return pickable.global_transform.affine_inverse() * grab.by.global_transform
