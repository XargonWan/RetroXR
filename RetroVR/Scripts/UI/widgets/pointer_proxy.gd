## PointerProxy — a body that lets the VR laser press one specific Area3D.
##
## The laser's RayCast runs with collide_with_areas = false, so every Area3D is
## invisible to it. That is deliberate: VRButton, VRSlider, VRHinge, keyboard key
## fields and book pages are all areas, and they are meant to be touched, not
## pointed at from across the room.
##
## A few controls do want the laser — panel chrome like the menu's flat/curved
## toggles, which sit out of reach at the edge of a floating panel. Rather than
## flip the flag for everything, they get one of these: a StaticBody3D on the
## pointable layer, wrapped around the target, that forwards pointer_event on.
## Opt-in, one control at a time.
##
##   PointerProxy.wrap(button, Vector3(0.044, 0.044, 0.012))
class_name PointerProxy
extends StaticBody3D

var _target: Node = null


## Add a proxy over `target`, sized `size`, and return it. Parented to the
## target so it inherits its transform — nothing has to keep them in step.
static func wrap(target: Node3D, size: Vector3) -> PointerProxy:
	var proxy := PointerProxy.new()
	proxy.name = "PointerProxy"
	proxy._target = target
	proxy.collision_layer = VRButton.POINTABLE_LAYER
	proxy.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	proxy.add_child(shape)
	target.add_child(proxy)
	return proxy


func pointer_event(event: XRToolsPointerEvent) -> void:
	if is_instance_valid(_target) and _target.has_method("pointer_event"):
		_target.pointer_event(event)
