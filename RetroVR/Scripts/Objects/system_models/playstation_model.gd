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


## PSX saves live on removable memory cards (PCSX-ReARMed exposes memcard 1
## as RETRO_MEMORY_SAVE_RAM).
func uses_memory_cards() -> bool:
	return true


## Put the card slot on the front-left of the console, next to controller port 1.
func configure_memory_card_slot(slot: Node3D) -> void:
	slot.position = Vector3(-0.09, 0.02, 0.14)
