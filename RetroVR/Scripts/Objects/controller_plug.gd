## ControllerPlug — the grabbable plug at the end of a retro controller's cable.
## Must be in the "controller_plug" group so RetroSystem controller ports accept it.
class_name ControllerPlug
extends XRToolsPickable


## The controller (RetroController or RayGun) that owns this plug.
var _controller: Node3D = null

## Device type exposed so system.gd can read it without knowing the controller type.
var device_type: int = 1  # RETRO_DEVICE_JOYPAD


func _ready() -> void:
	super._ready()
	add_to_group("controller_plug")


## Called by the owning controller when the cable is spawned.
func set_controller(controller: Node3D) -> void:
	_controller = controller
	if "device_type" in controller:
		device_type = controller.device_type


## Called by system.gd when this plug snaps into a port.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	if is_instance_valid(_controller) and _controller.has_method("on_plugged_in"):
		_controller.on_plugged_in(system, port_index)


## Called by system.gd when this plug is removed from a port.
func on_unplugged() -> void:
	if is_instance_valid(_controller) and _controller.has_method("on_unplugged"):
		_controller.on_unplugged()
