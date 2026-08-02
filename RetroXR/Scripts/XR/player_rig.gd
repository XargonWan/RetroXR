## PlayerRig — the player: origin, camera, hands, spawn menu, locomotion.
##
## One rig serves every room. SceneManager carries it across a room change rather
## than letting each room build its own, because building one costs ~380 ms of
## blocked main thread and a blocked main thread in VR is a frozen headset — see
## SceneManager._run_transition().
##
## The cost of that is this class's reason to exist: anything on the rig that was
## true of the old room has to be undone on the way out and set up again on the
## way in, and there is no _ready() to do it because the node is never re-created.
## leave_world() and enter_world() are that seam. A new piece of room-dependent
## state belongs in them — not in SceneManager, which should not have to know what
## the rig is made of.
class_name PlayerRig
extends Node3D


@onready var origin: XROrigin3D = $Staging/XROrigin3D
@onready var camera: XRCamera3D = $Staging/XROrigin3D/XRCamera3D
@onready var body: XRToolsPlayerBody = $Staging/XROrigin3D/PlayerBody


## Cut every tie to the room about to be torn down.
##
## The body goes with it: the floor is part of the room, and a body left running
## over the gap spends the whole crossing in free fall — 51 metres of it, at the
## rate a Quest loads a room.
func leave_world() -> void:
	for node: Node in find_children("*", "XRToolsFunctionPickup", true, false):
		var pickup := node as XRToolsFunctionPickup
		if pickup.picked_up_object != null:
			pickup.drop_object()
	body.enabled = false


## Stand where the incoming room authored its own rig. Called before that room
## enters the tree, so everything in it sees the player already in place.
##
## origin_rest is the offset the room authored under the rig root. Locomotion
## walks the origin, not the root, so it has to go back or the player arrives at
## the new spawn point plus wherever they wandered in the last room.
func place_at(spawn: Transform3D, origin_rest: Transform3D) -> void:
	transform = spawn
	origin.transform = origin_rest


## Start living in the room again. Runs once it is the current scene and there is
## a floor to stand on.
func enter_world() -> void:
	body.reset_for_new_world()
	body.enabled = true
