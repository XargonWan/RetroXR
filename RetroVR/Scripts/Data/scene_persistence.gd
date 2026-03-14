## ScenePersistence — saves and restores dynamically-spawned objects for the
## arcade scene.  Objects must be in the "spawned" group to be tracked.
##
## Save file: user://scenes/arcade.json
class_name ScenePersistence
extends RefCounted


const SAVE_DIR  := "user://scenes"
const SAVE_FILE := "user://scenes/arcade.json"
const VERSION   := 1

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE     := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE   := preload("res://Scenes/Objects/cartridge.tscn")
const BOOK_SCENE   := preload("res://Scenes/Objects/pdf_book.tscn")


func has_save() -> bool:
	return FileAccess.file_exists(SAVE_FILE)


## Serialize all "spawned"-group objects under root to JSON.
func save_scene(root: Node) -> void:
	var objects: Array[Dictionary] = []
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		var data := _serialize_node(node)
		if not data.is_empty():
			objects.append(data)

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var f := FileAccess.open(SAVE_FILE, FileAccess.WRITE)
	if not f:
		push_error("ScenePersistence: cannot write '%s' (err %d)" % [SAVE_FILE, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify({"version": VERSION, "objects": objects}, "\t"))
	print("[ScenePersistence] saved %d objects" % objects.size())


## Remove all spawned objects, then recreate from the save file.
func load_scene(root: Node) -> void:
	if not has_save():
		return

	clear_scene(root)

	var f := FileAccess.open(SAVE_FILE, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("ScenePersistence: invalid save file")
		return

	var data := parsed as Dictionary
	var objects: Variant = data.get("objects", [])
	if not objects is Array:
		return

	var count := 0
	for entry: Variant in objects as Array:
		if not entry is Dictionary:
			continue
		var obj := _deserialize_object(entry as Dictionary)
		if obj:
			root.add_child(obj)
			obj.add_to_group("spawned")
			count += 1

	print("[ScenePersistence] loaded %d objects" % count)


## Free all dynamically-spawned objects.
func clear_scene(root: Node) -> void:
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		# Power off systems before freeing so the emulation thread shuts down
		if node is RetroSystem and node.get("is_powered_on"):
			node.call("toggle_power")
		node.queue_free()


# ── Serialization ──────────────────────────────────────────────────────────────

func _serialize_node(node: Node) -> Dictionary:
	if not node is Node3D:
		return {}
	var n3d := node as Node3D
	var pos := n3d.global_position
	var rot := n3d.global_rotation_degrees

	if node is RetroSystem:
		return {
			"type": "system",
			"systemid": node.get("systemid"),
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroTV:
		return {
			"type": "tv",
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroCartridge:
		return {
			"type": "cartridge",
			"rom_path": node.get("rom_path"),
			"game_label": node.get("game_label"),
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is PDFBook:
		return {
			"type": "book",
			"pdf_path": node.get("pdf_path"),
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	return {}


func _deserialize_object(data: Dictionary) -> Node3D:
	var obj_type: String = data.get("type", "")
	var obj: Node3D = null

	match obj_type:
		"system":
			obj = SYSTEM_SCENE.instantiate() as Node3D
			obj.set("systemid", data.get("systemid", ""))
		"tv":
			obj = TV_SCENE.instantiate() as Node3D
		"cartridge":
			obj = CART_SCENE.instantiate() as Node3D
			obj.set("rom_path", data.get("rom_path", ""))
			obj.set("game_label", data.get("game_label", ""))
		"book":
			obj = BOOK_SCENE.instantiate() as Node3D
			obj.set("pdf_path", data.get("pdf_path", ""))
		_:
			push_warning("ScenePersistence: unknown object type '%s'" % obj_type)
			return null

	if not obj:
		return null

	var pos: Array = data.get("position", [0.0, 0.0, 0.0])
	var rot: Array = data.get("rotation", [0.0, 0.0, 0.0])
	obj.position = Vector3(pos[0], pos[1], pos[2])
	obj.rotation_degrees = Vector3(rot[0], rot[1], rot[2])
	return obj
