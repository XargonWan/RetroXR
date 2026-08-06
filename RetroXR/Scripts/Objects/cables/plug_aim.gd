## PlugAim — turns a plug reeled in on the ray to face the way the hand points.
##
## A plug authors no hand grab point, so a ranged grab falls through grab.gd to an
## IDENTITY frame: the plug's local axes are laid straight onto the controller's.
## Every plug here is modelled connector-on-+Z (the cable trails -Z, matching
## VerletRope.plug_exit_axis) and a controller's +Z points back at the wearer — so
## the plug arrives aimed at the player's face and has to be turned around by hand
## before it will go into anything.
##
## Half a turn about the plug's own up axis puts the connector along the way the
## hand is pointing. About Y, not X: a turn about X aims it correctly and holds it
## upside down.
##
## Only ranged grabs are re-aimed. A plug picked up within reach keeps the
## as-grabbed offset, so it comes up the way it was lying rather than twisting out
## of your fingers.
class_name PlugAim


## The plug's pose relative to the grabber. grab_driver drives the plug to
## `by.global_transform * transform⁻¹` every tick; a half-turn is its own inverse,
## so this reads the same in either direction.
const RANGED_FRAME := Transform3D(
	Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)), Vector3.ZERO)


## Connect a plug's `picked_up` to this. Safe on every grabber: `Grabber.pickup`
## is null unless the grab came from an XRToolsFunctionPickup, which leaves snap
## zones and the desktop reticle untouched.
static func aim(plug: XRToolsPickable) -> void:
	if plug == null or plug._grab_driver == null:
		return
	var grab: Grab = plug._grab_driver.primary
	if grab == null or grab.pickup == null or not grab.pickup.picked_up_ranged:
		return
	grab.transform = RANGED_FRAME
