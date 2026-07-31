## DesktopHandPivot — minimal XRToolsFunctionPickup shim for desktop pickup.
##
## XRToolsPickable.pick_up(by) and .drop() access these members on the grabber:
##   picked_up_ranged  — read to decide snap vs lerp grab driver
##   drop_object()     — called when the pickable reports it has been dropped
##
## This script satisfies that interface for the plain Node3D pivot used by
## desktop_pickup.gd, without any VR controller machinery.
extends Node3D

## Always false: desktop grabs are always immediate (snap), never ranged-lerp.
var picked_up_ranged: bool = false

## Weak reference back to the DesktopPickup that owns this pivot.
## Set by desktop_pickup.gd immediately after creating the pivot.
var _owner_pickup: WeakRef = null


## Called by XRToolsPickable.drop() to notify the grabber it was released.
## Forward to DesktopPickup so it clears _held_object even if drop came from
## outside (e.g. a snap zone or another script calling pickable.drop()).
func drop_object() -> void:
	if _owner_pickup == null:
		return
	var pickup = _owner_pickup.get_ref()
	if pickup and pickup.has_method("_on_pivot_drop_object"):
		pickup._on_pivot_drop_object()
