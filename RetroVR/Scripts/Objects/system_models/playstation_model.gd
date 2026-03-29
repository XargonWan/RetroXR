## RetroSystemModelPlaystation — PlayStation 1 console model.
class_name RetroSystemModelPlaystation
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/King PSX.glb"


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene:
		add_child(scene.instantiate())
	else:
		push_warning("RetroSystemModelPlaystation: could not load model at %s" % _MODEL_PATH)


func get_controller_port_count() -> int:
	return 2
