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
	var nodes := root.get_tree().get_nodes_in_group("spawned")

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

	# Pass 1: spawn all objects, keyed by their saved id.
	var spawned: Dictionary = {}  # id -> Node3D
	var entries: Dictionary = {}  # id -> Dictionary
	var count := 0
	for entry: Variant in objects as Array:
		if not entry is Dictionary:
			continue
		var d := entry as Dictionary
		var id: int = d.get("id", -1)
		if id < 0:
			continue
		var obj := _deserialize_object(d)
		if obj:
			root.add_child(obj)
			obj.add_to_group("spawned")
			spawned[id] = obj
			entries[id] = d
			count += 1

	# Pass 2: restore connections (cable plug → TV, cartridge → system).
	# Cable restoration may be deferred internally if the cable scene hasn't
	# finished spawning yet (RetroSystem._add_cable_to_scene is call_deferred).
	for id: int in spawned:
		if not spawned[id] is RetroSystem:
			continue
		var sys := spawned[id] as RetroSystem
		var d: Dictionary = entries[id]
		var tv_id: int = d.get("connected_tv_id", -1)
		if spawned.has(tv_id) and spawned[tv_id] is RetroTV:
			sys.restore_cable_connection(spawned[tv_id] as RetroTV)
		var cart_id: int = d.get("snapped_cartridge_id", -1)
		if spawned.has(cart_id) and spawned[cart_id] is RetroCartridge:
			sys.restore_cartridge(spawned[cart_id])

	print("[ScenePersistence] loaded %d objects" % count)


## Free all dynamically-spawned objects.
func clear_scene(root: Node) -> void:
	for node: Node in root.get_tree().get_nodes_in_group("spawned"):
		# Power off systems before freeing so the emulation thread shuts down
		if node is RetroSystem and (node as RetroSystem).is_powered_on:
			(node as RetroSystem).toggle_power()
		node.queue_free()


# ── Serialization ──────────────────────────────────────────────────────────────

func _serialize_node(node: Node, id: int, node_to_id: Dictionary) -> Dictionary:
	if not node is Node3D:
		return {}
	var n3d := node as Node3D
	var pos := n3d.global_position
	var rot := n3d.global_rotation_degrees

	if node is RetroSystem:
		var sys := node as RetroSystem
		var tv_id: int = node_to_id.get(sys.connected_tv, -1) if sys.connected_tv != null else -1
		var cart := sys.get_snapped_cartridge()
		var cart_id: int = node_to_id.get(cart, -1) if cart != null else -1
		return {
			"id": id,
			"type": "system",
			"systemid": sys.systemid,
			"connected_tv_id": tv_id,
			"snapped_cartridge_id": cart_id,
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
		var cart := node as RetroCartridge
		return {
			"id": id,
			"type": "cartridge",
			"rom_path": cart.rom_path,
			"game_label": cart.game_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is PDFBook:
		return {
			"id": id,
			"type": "book",
			"pdf_path": (node as PDFBook).pdf_path,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	return {}


func _deserialize_object(data: Dictionary) -> Node3D:
	var obj_type: String = data.get("type", "")
	var obj: Node3D = null

	match obj_type:
		"system":
			var sys := SYSTEM_SCENE.instantiate() as RetroSystem
			sys.systemid = data.get("systemid", "")
			obj = sys
		"tv":
			obj = TV_SCENE.instantiate() as Node3D
		"cartridge":
			var cart := CART_SCENE.instantiate() as RetroCartridge
			cart.rom_path = data.get("rom_path", "")
			cart.game_label = data.get("game_label", "")
			obj = cart
		"book":
			var book := BOOK_SCENE.instantiate() as PDFBook
			book.pdf_path = data.get("pdf_path", "")
			obj = book
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
