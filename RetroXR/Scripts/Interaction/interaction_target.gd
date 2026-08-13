class_name InteractionTarget
extends RefCounted


const KIND_NONE := &"none"
const KIND_POINTER := &"pointer"
const KIND_BUTTON := &"button"
const KIND_PICKABLE := &"pickable"
const KIND_SNAP_PICKABLE := &"snap_pickable"


var kind: StringName = KIND_NONE
var hit_node: Node3D = null
var action_node: Node3D = null
var highlight_node: Node3D = null
var pointer_event_target: Node3D = null
var position: Vector3 = Vector3.ZERO
var distance: float = INF
var can_activate: bool = false
var can_grab: bool = false


static func none() -> InteractionTarget:
	return InteractionTarget.new()


func is_valid() -> bool:
	return kind != KIND_NONE and (
		is_instance_valid(action_node) or
		is_instance_valid(highlight_node) or
		is_instance_valid(pointer_event_target))
