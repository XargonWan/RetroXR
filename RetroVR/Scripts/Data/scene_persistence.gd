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
	var nodes: Array[Node] = []
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		nodes.append(node)

	# Build a node→index map so we can cross-reference connections.
	var node_to_id: Dictionary = {}
	for i in range(nodes.size()):
		node_to_id[nodes[i]] = i

	var objects: Array[Dictionary] = []
	for i in range(nodes.size()):
		var data := _serialize_node(nodes[i], i, node_to_id)
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

	# Pass 1: spawn all objects indexed by their saved id.
	var spawned: Array = []  # Array[Node3D?], index = saved object id
	var entries: Array = []  # Array[Dictionary], parallel to spawned
	var count := 0
	for entry: Variant in objects as Array:
		if not entry is Dictionary:
			spawned.append(null)
			entries.append({})
			continue
		var d := entry as Dictionary
		var obj := _deserialize_object(d)
		if obj:
			root.add_child(obj)
			obj.add_to_group("spawned")
			spawned.append(obj)
			entries.append(d)
			count += 1
		else:
			spawned.append(null)
			entries.append({})

	# Pass 2: restore connections (cable plug → TV, cartridge → system).
	# Cable restoration may be deferred internally if the cable scene hasn't
	# finished spawning yet (RetroSystem._add_cable_to_scene is call_deferred).
	for i in range(spawned.size()):
		var obj: Variant = spawned[i]
		var d: Dictionary = entries[i]
		if not obj:
			continue

		if obj is RetroSystem:
			var tv_id: int = d.get("connected_tv_id", -1)
			if tv_id >= 0 and tv_id < spawned.size() and spawned[tv_id] is RetroTV:
				(obj as RetroSystem).restore_cable_connection(spawned[tv_id] as RetroTV)

		elif obj is RetroCartridge:
			var sys_id: int = d.get("snapped_in_system_id", -1)
			if sys_id >= 0 and sys_id < spawned.size() and spawned[sys_id] is RetroSystem:
				(spawned[sys_id] as RetroSystem).restore_cartridge(obj)

	print("[ScenePersistence] loaded %d objects" % count)


## Free all dynamically-spawned objects.
func clear_scene(root: Node) -> void:
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		# Power off systems before freeing so the emulation thread shuts down
		if node is RetroSystem and node.get("is_powered_on"):
			node.call("toggle_power")
		node.queue_free()


# ── Serialization ──────────────────────────────────────────────────────────────

func _serialize_node(node: Node, id: int, node_to_id: Dictionary) -> Dictionary:
	if not node is Node3D:
		return {}
	var n3d := node as Node3D
	var pos := n3d.global_position
	var rot := n3d.global_rotation_degrees

	if node is RetroSystem:
		var tv: RetroTV = node.get("connected_tv")
		var tv_id: int = node_to_id.get(tv, -1) if tv != null else -1
		return {
			"id": id,
			"type": "system",
			"systemid": node.get("systemid"),
			"connected_tv_id": tv_id,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroTV:
		return {
			"id": id,
			"type": "tv",
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroCartridge:
		# Find which system (if any) has this cartridge snapped in its slot.
		var sys_id := -1
		for other: Variant in node_to_id.keys():
			if other is RetroSystem:
				if (other as RetroSystem).get_snapped_cartridge() == node:
					sys_id = node_to_id[other]
					break
		return {
			"id": id,
			"type": "cartridge",
			"rom_path": node.get("rom_path"),
			"game_label": node.get("game_label"),
			"snapped_in_system_id": sys_id,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is PDFBook:
		return {
			"id": id,
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
