## GameCubeMemoryCard — real-model GameCube memory card (an author's 251-block
## card), swapping the generic MemoryCard's procedural PS1-shaped box for the
## real GameCube card shape. Two other capacities (59, 1019 blocks) exist in
## the library but aren't wired up — this is the one representative size.
class_name GameCubeMemoryCard
extends MemoryCard

const _MODEL_PATH := "res://imported-assets/gamecube_memory_card.glb"


func _ready() -> void:
	super._ready()
	card_label = "GAMECUBE"
	if not ResourceLoader.exists(_MODEL_PATH):
		return   # store build (GLB export-excluded) — keep the procedural stand-in
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		return
	var glb := scene.instantiate() as Node3D
	glb.name = "CardModel"
	add_child(glb)
	var ab := _model_aabb(glb)
	glb.position = -(ab.position + ab.size * 0.5)
	for nm in ["CardMesh", "StripeMesh", "CardLabel"]:
		var n := get_node_or_null(nm) as Node3D
		if n != null:
			n.visible = false
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = ab.size


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB(); var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var ab: AABB = mi.transform * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for c in n.get_children():
			stack.append(c)
	return acc
