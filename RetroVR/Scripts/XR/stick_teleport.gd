## StickTeleport — extends XRToolsFunctionTeleport to support thumbstick-forward aiming.
## Place this script on the FunctionTeleport node instead of the default one.
## Requires the parent addon's _teleport_aim_active() patch (function_teleport.gd).
extends XRToolsFunctionTeleport

## Thumbstick action to use for aiming (reads .y axis)
@export var stick_teleport_action: String = "primary"

## How far forward the stick must be pushed to start aiming
@export var stick_teleport_threshold: float = 0.6


## Override: active when stick is pushed forward past threshold
func _teleport_aim_active() -> bool:
	if not _controller or not _controller.get_is_active():
		return false
	# Button fallback still works if teleport_button_action is set
	if teleport_button_action != "" and _controller.is_button_pressed(teleport_button_action):
		return true
	# Stick forward activates aiming
	if stick_teleport_action != "" and _controller.get_vector2(stick_teleport_action).y > stick_teleport_threshold:
		return true
	return false
