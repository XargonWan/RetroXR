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
	# The GLB's front faces +X and it's authored far from its own origin. Rotate
	# its front to +Z (the cabinet front, where the controller ports and the
	# memory-card slot sit), then recentre it in X/Z on the origin (its body base
	# is already at y=0). Recentring is computed from the rotated mesh AABB so it
	# stays correct regardless of the rotation or a future re-export.
	inst.rotation_degrees.y = -90.0
	add_child(inst)
	var xz := _model_xz_center(inst)
	inst.position = Vector3(-xz.x, 0.0, -xz.y)


## Combined X/Z centre of all of `inst`'s meshes, expressed in this model node's
## local space (call after add_child, before setting inst.position).
func _model_xz_center(inst: Node3D) -> Vector2:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			if first:
				acc = ab
				first = false
			else:
				acc = acc.merge(ab)
		for ch in n.get_children():
			stack.append(ch)
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


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
