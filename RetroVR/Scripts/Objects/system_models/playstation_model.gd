## RetroSystemModelPlaystation — PlayStation 1 console model.
class_name RetroSystemModelPlaystation
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/King PSX.glb"


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("RetroSystemModelPlaystation: could not load model at %s" % _MODEL_PATH)
		return
	var inst := scene.instantiate() as Node3D
	# The GLB authored the console far from its own origin (its combined mesh AABB
	# centres at ~(+1.294, -2.959) in X/Z); recentre it on the cabinet origin so
	# it lines up with the controller ports / memory-card slot, with the console
	# body base sitting at y=0.
	inst.position = Vector3(-1.294, 0.0, 2.959)
	add_child(inst)


## Rest the console body on the ground. The default console collision box bottoms
## out at y=-0.05, but this model's body base is at y=0 — without this it would
## float 5 cm once recentred.
func configure_collision(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return
	col.shape = col.shape.duplicate()
	(col.shape as BoxShape3D).size = Vector3(0.2, 0.055, 0.28)
	col.position = Vector3(0, 0.0275, 0)


func get_controller_port_count() -> int:
	return 2


## PSX saves live on removable memory cards (PCSX-ReARMed exposes memcard 1
## as RETRO_MEMORY_SAVE_RAM).
func uses_memory_cards() -> bool:
	return true


## Put the card slot on the front-left of the console, next to controller port 1.
func configure_memory_card_slot(slot: Node3D) -> void:
	slot.position = Vector3(-0.09, 0.02, 0.14)
