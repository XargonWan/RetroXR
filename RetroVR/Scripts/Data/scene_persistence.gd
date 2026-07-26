## ScenePersistence — saves and restores dynamically-spawned objects for the
## arcade scene.  Objects must be in the "spawned" group to be tracked.
##
## Save directory: user://scenes/arcade/
## Manifest:       user://scenes/arcade/manifest.json
## Slot files:     user://scenes/arcade/{id}.json
class_name ScenePersistence
extends RefCounted


const SAVE_DIR      := "user://scenes"
const ARCADE_DIR    := "user://scenes/arcade"
const MANIFEST_FILE := "user://scenes/arcade/manifest.json"
const VERSION       := 1

const SYSTEM_SCENE           := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE               := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE             := preload("res://Scenes/Objects/cartridge.tscn")
const DISC_SCENE             := preload("res://Scenes/Objects/disc.tscn")
const UMD_DISC_SCENE         := preload("res://Scenes/Objects/umd_disc.tscn")
const MEMCARD_SCENE          := preload("res://Scenes/Objects/memory_card.tscn")
const BOOK_SCENE             := preload("res://Scenes/Objects/pdf_book.tscn")
const RETRO_CONTROLLER_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const RAY_GUN_SCENE          := preload("res://Scenes/Objects/ray_gun.tscn")
const VCR_SCENE              := preload("res://Scenes/Objects/vcr_player.tscn")
const TAPE_SCENE             := preload("res://Scenes/Objects/vcr_tape.tscn")
const DVD_SCENE              := preload("res://Scenes/Objects/dvd_player.tscn")
const DVD_DISC_SCENE         := preload("res://Scenes/Objects/dvd_disc.tscn")
const CD_PLAYER_SCENE        := preload("res://Scenes/Objects/cd_player.tscn")
const CASSETTE_PLAYER_SCENE  := preload("res://Scenes/Objects/cassette_player.tscn")
const AUDIO_DISC_SCENE       := preload("res://Scenes/Objects/audio_disc.tscn")
const AUDIO_CASSETTE_SCENE   := preload("res://Scenes/Objects/audio_cassette.tscn")
const TV_REMOTE_SCENE        := preload("res://Scenes/Objects/tv_remote.tscn")
const TRASH_CAN_SCENE        := preload("res://Scenes/Objects/trash_can.tscn")
const RETRO_MOUSE_SCENE      := preload("res://Scenes/Objects/retro_mouse.tscn")
const RETRO_KEYBOARD_SCENE   := preload("res://Scenes/Objects/retro_keyboard.tscn")


# ── Multi-slot public API ──────────────────────────────────────────────────────

## Returns ordered slot list. "clean" is always first and is never stored in the
## manifest — it is prepended here.
func get_slots() -> Array[Dictionary]:
	var m := _load_manifest()
	var result: Array[Dictionary] = [{"id": "clean", "name": "Clean Room", "readonly": true}]
	for s: Variant in m.get("slots", []):
		result.append(s as Dictionary)
	return result


## Save current scene state to the named slot. Returns false on I/O error.
func save_slot(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	DirAccess.make_dir_recursive_absolute(ARCADE_DIR)
	return _write_scene_to_file(root, _slot_file(slot_id))


## Clear the scene then restore from the slot file.
## Loading "clean" just clears the scene.
func load_slot(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		clear_scene(root)
		return true
	var path := _slot_file(slot_id)
	if not FileAccess.file_exists(path):
		push_warning("ScenePersistence: slot file not found '%s'" % path)
		return false
	clear_scene(root)
	return _read_scene_from_file(root, path)


## Remove a slot from the manifest and delete its file.
func delete_slot(slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	var m := _load_manifest()
	var slots: Array = m.get("slots", [])
	var new_slots: Array = []
	for s: Variant in slots:
		if (s as Dictionary).get("id", "") != slot_id:
			new_slots.append(s)
	m["slots"] = new_slots
	_save_manifest(m)
	var path := _slot_file(slot_id)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return true


## Rename a slot in the manifest.
func rename_slot(slot_id: String, new_name: String) -> bool:
	if slot_id == "clean":
		return false
	var m := _load_manifest()
	var slots: Array = m.get("slots", [])
	for s: Variant in slots:
		var d := s as Dictionary
		if d.get("id", "") == slot_id:
			d["name"] = new_name
			m["slots"] = slots
			return _save_manifest(m)
	return false


## Save current scene to a brand-new slot and append it to the manifest.
## Returns the new slot id.
func create_new_slot(root: Node, name: String) -> String:
	DirAccess.make_dir_recursive_absolute(ARCADE_DIR)
	var slot_id := _generate_id()
	_write_scene_to_file(root, _slot_file(slot_id))
	var m := _load_manifest()
	var slots: Array = m.get("slots", [])
	slots.append({"id": slot_id, "name": name})
	m["slots"] = slots
	_save_manifest(m)
	return slot_id


# ── Legacy stubs (kept so any surviving callers still compile) ─────────────────

func has_save() -> bool:
	# New system: "has saves" means there is at least one user slot.
	var slots := get_slots()
	return slots.size() > 1   # > 1 because "clean" is always present


func save_scene(_root: Node) -> void:
	push_warning("ScenePersistence.save_scene() is deprecated — use save_slot() instead")


func load_scene(_root: Node) -> void:
	push_warning("ScenePersistence.load_scene() is deprecated — use load_slot() instead")


## Free all dynamically-spawned objects.
func clear_scene(root: Node) -> void:
	var spawned := root.get_tree().get_nodes_in_group("spawned")

	# Pre-pass: drop cable/controller plugs while their snap-zones are still alive.
	# Cable instances are in "spawned".  Their plug child may be snapped into a
	# snap-zone.  Calling drop() clears _grab_driver before queue_free.
	for node: Node in spawned:
		for plug_name: String in ["CablePlug", "ControllerPlug"]:
			var plug := node.get_node_or_null(plug_name)
			if plug and plug.has_method("drop"):
				plug.call("drop")

	# Main pass: power off and free everything.
	for node: Node in spawned:
		# Power off systems so the emulation thread shuts down cleanly.
		if node is RetroSystem and (node as RetroSystem).is_powered_on:
			(node as RetroSystem).toggle_power()
		# drop_and_free() clears _grab_driver before queue_free, preventing a
		# use-after-free in XRToolsPickable._exit_tree when a snap-zone that
		# was "holding" this pickable gets freed first.
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()


# ── Private helpers ────────────────────────────────────────────────────────────

func _slot_file(slot_id: String) -> String:
	return ARCADE_DIR + "/" + slot_id + ".json"


func _generate_id() -> String:
	return "%08x" % (randi() ^ Time.get_ticks_msec())


func _load_manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_FILE):
		return {"version": VERSION, "slots": []}
	var f := FileAccess.open(MANIFEST_FILE, FileAccess.READ)
	if not f:
		return {"version": VERSION, "slots": []}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed as Dictionary
	return {"version": VERSION, "slots": []}


func _save_manifest(m: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ARCADE_DIR)
	var f := FileAccess.open(MANIFEST_FILE, FileAccess.WRITE)
	if not f:
		push_error("ScenePersistence: cannot write manifest (err %d)" % FileAccess.get_open_error())
		return false
	f.store_string(JSON.stringify(m, "\t"))
	return true


func _write_scene_to_file(root: Node, path: String) -> bool:
	var nodes := root.get_tree().get_nodes_in_group("spawned")
	var node_to_id: Dictionary = {}
	for i in range(nodes.size()):
		node_to_id[nodes[i]] = i
	var objects: Array[Dictionary] = []
	for i in range(nodes.size()):
		var data := _serialize_node(nodes[i], i, node_to_id)
		if not data.is_empty():
			objects.append(data)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if not f:
		push_error("ScenePersistence: cannot write '%s' (err %d)" % [path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify({"version": VERSION, "objects": objects}, "\t"))
	print("[ScenePersistence] saved %d objects to '%s'" % [objects.size(), path])
	return true


func _read_scene_from_file(root: Node, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("ScenePersistence: invalid slot file '%s'" % path)
		return false

	var data := parsed as Dictionary
	var objects: Variant = data.get("objects", [])
	if not objects is Array:
		return false

	var spawned := instantiate_objects(root, objects as Array)
	print("[ScenePersistence] loaded %d objects from '%s'" % [spawned.size(), path])
	return true


## Instantiate serialized object entries under root and restore their
## cross-connections (two passes). Returns {id: Node3D} for the spawned set.
## Shared by slot loading and multiplayer world snapshots (ObjectSync).
func instantiate_objects(root: Node, objects: Array) -> Dictionary:
	# Pass 1: spawn all objects.
	var spawned: Dictionary = {}
	var entries: Dictionary = {}
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

	# Pass 2: restore connections.
	for id: int in spawned:
		var d: Dictionary = entries[id]
		if spawned[id] is RetroSystem:
			var sys := spawned[id] as RetroSystem
			var tv_id: int = d.get("connected_tv_id", -1)
			var tv_path: String = d.get("connected_tv_path", "")
			print("[ScenePersistence] system id=%d connected_tv_id=%d tv_path=%s" % [id, tv_id, tv_path])
			if spawned.has(tv_id) and spawned[tv_id] is RetroTV:
				print("[ScenePersistence] restoring cable connection system→spawned tv")
				sys.restore_cable_connection(spawned[tv_id] as RetroTV)
			elif not tv_path.is_empty():
				var tv_node := root.get_node_or_null(tv_path) as RetroTV
				if tv_node:
					print("[ScenePersistence] restoring cable connection system→scene tv '%s'" % tv_path)
					sys.restore_cable_connection(tv_node)
				else:
					push_warning("[ScenePersistence] could not find scene TV at '%s'" % tv_path)
			# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM).
			for ch in range(1, sys.get_channel_count()):
				var ch_tv_id: int = d.get("connected_tv%d_id" % ch, -1)
				var ch_tv_path: String = d.get("connected_tv%d_path" % ch, "")
				if spawned.has(ch_tv_id) and spawned[ch_tv_id] is RetroTV:
					sys.restore_cable_connection(spawned[ch_tv_id] as RetroTV, ch)
				elif not ch_tv_path.is_empty():
					var ch_tv_node := root.get_node_or_null(ch_tv_path) as RetroTV
					if ch_tv_node:
						sys.restore_cable_connection(ch_tv_node, ch)
					else:
						push_warning("[ScenePersistence] could not find scene TV at '%s'" % ch_tv_path)
			var cart_id: int = d.get("snapped_cartridge_id", -1)
			if spawned.has(cart_id) and spawned[cart_id] is RetroCartridge:
				print("[ScenePersistence] restoring cartridge id=%d" % cart_id)
				sys.restore_cartridge(spawned[cart_id])
			var memcard_id: int = d.get("snapped_memcard_id", -1)
			if spawned.has(memcard_id) and spawned[memcard_id] is MemoryCard:
				print("[ScenePersistence] restoring memory card id=%d" % memcard_id)
				sys.restore_memory_card(spawned[memcard_id])
		elif spawned[id] is VCRPlayer:
			var vcr := spawned[id] as VCRPlayer
			var tv_id: int = d.get("connected_tv_id", -1)
			var tv_path: String = d.get("connected_tv_path", "")
			if spawned.has(tv_id) and spawned[tv_id] is RetroTV:
				vcr.restore_cable_connection(spawned[tv_id] as RetroTV)
			elif not tv_path.is_empty():
				var tv_node := root.get_node_or_null(tv_path) as RetroTV
				if tv_node:
					vcr.restore_cable_connection(tv_node)
				else:
					push_warning("[ScenePersistence] could not find scene TV at '%s'" % tv_path)
			var tape_id: int = d.get("snapped_tape_id", -1)
			if spawned.has(tape_id) and spawned[tape_id] is VCRTape:
				vcr.restore_tape(spawned[tape_id])
		elif spawned[id] is DVDPlayer:
			var dvd := spawned[id] as DVDPlayer
			var tv_id: int = d.get("connected_tv_id", -1)
			var tv_path: String = d.get("connected_tv_path", "")
			if spawned.has(tv_id) and spawned[tv_id] is RetroTV:
				dvd.restore_cable_connection(spawned[tv_id] as RetroTV)
			elif not tv_path.is_empty():
				var tv_node := root.get_node_or_null(tv_path) as RetroTV
				if tv_node:
					dvd.restore_cable_connection(tv_node)
				else:
					push_warning("[ScenePersistence] could not find scene TV at '%s'" % tv_path)
			var disc_id: int = d.get("snapped_disc_id", -1)
			if spawned.has(disc_id) and spawned[disc_id] is DVDDisc:
				dvd.restore_disc(spawned[disc_id])
		elif spawned[id] is RetroAudioPlayer:
			var ap := spawned[id] as RetroAudioPlayer
			var media_id: int = d.get("snapped_media_id", -1)
			if spawned.has(media_id) and (spawned[media_id] is AudioDisc or spawned[media_id] is AudioCassette):
				ap.restore_media(spawned[media_id])
		elif spawned[id] is RetroController or spawned[id] is RayGun or spawned[id] is RetroMouse or spawned[id] is RetroKeyboard:
			var ctrl: Node3D = spawned[id]
			var port_idx: int = d.get("port_index", -1)
			if port_idx < 0:
				continue
			var sys_id: int = d.get("connected_system_id", -1)
			var sys_path: String = d.get("connected_system_path", "")
			var sys: RetroSystem = null
			if spawned.has(sys_id) and spawned[sys_id] is RetroSystem:
				sys = spawned[sys_id] as RetroSystem
			elif not sys_path.is_empty():
				sys = root.get_node_or_null(sys_path) as RetroSystem
			if sys == null:
				push_warning("[ScenePersistence] controller id=%d: system not found" % id)
				continue
			print("[ScenePersistence] restoring controller id=%d → system port %d" % [id, port_idx])
			ctrl.call("restore_port_connection", sys, port_idx)

	if count > 0:
		print("[ScenePersistence] instantiated %d objects" % count)
	return spawned


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
		# If the TV is a scene-placed node (not in spawned group), save its path instead.
		var tv_path: String = ""
		if sys.connected_tv != null and tv_id == -1:
			tv_path = str(sys.connected_tv.get_path())
		var cart := sys.get_snapped_cartridge()
		var cart_id: int = node_to_id.get(cart, -1) if cart != null else -1
		var memcard := sys.get_snapped_memcard()
		var memcard_id: int = node_to_id.get(memcard, -1) if memcard != null else -1
		print("[ScenePersistence] serialize system id=%d systemid=%s tv_id=%d tv_path=%s cart_id=%d" % [id, sys.systemid, tv_id, tv_path, cart_id])
		var result := {
			"id": id,
			"type": "system",
			"systemid": sys.systemid,
			"model_variant": sys.model_variant,
			"connected_tv_id": tv_id,
			"snapped_cartridge_id": cart_id,
			"snapped_memcard_id": memcard_id,
			"video_out": sys.video_out_enabled,
			"ignore_gravity": sys.ignore_gravity,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
		if not tv_path.is_empty():
			result["connected_tv_path"] = tv_path
		# Clamshell lid angle (DS/3DS); omitted (-1) for systems without a lid.
		var lid_angle: float = sys.get_lid_angle_deg()
		if lid_angle >= 0.0:
			result["lid_angle"] = lid_angle
		# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM).
		for ch in range(1, sys.get_channel_count()):
			var ch_tv := sys.get_channel_tv(ch)
			if ch_tv == null:
				continue
			var ch_tv_id: int = node_to_id.get(ch_tv, -1)
			result["connected_tv%d_id" % ch] = ch_tv_id
			if ch_tv_id == -1:
				result["connected_tv%d_path" % ch] = str(ch_tv.get_path())
		return result
	elif node is RetroTV:
		return {
			"id": id,
			"type": "tv",
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
			"crt_enabled": (node as RetroTV).crt_enabled,
			"crt_params": (node as RetroTV).get_crt_params(),
			"scale_factor": (node as RetroTV).scale_factor,
			"stereo_mode": (node as RetroTV).stereo_mode,
		}
	elif node is TVRemote:
		return {
			"id": id,
			"type": "tv_remote",
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is TrashCan:
		return {
			"id": id,
			"type": "trash_can",
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroDisc:
		# MUST precede the RetroCartridge branch — RetroDisc extends it.
		var disc := node as RetroDisc
		return {
			"id": id,
			"type": "disc",
			"rom_path": disc.rom_path,
			"game_label": disc.game_label,
			"save_id": disc.save_id,
			"cart_systemid": disc.systemid,
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
			"save_id": cart.save_id,
			"cart_systemid": cart.systemid,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is MemoryCard:
		var card := node as MemoryCard
		return {
			"id": id,
			"type": "memory_card",
			"card_id": card.card_id,
			"card_label": card.card_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is PDFBook:
		var book := node as PDFBook
		var page := book.net_get_page()
		return {
			"id": id,
			"type": "book",
			"pdf_path": book.pdf_path,
			"half_pages": book.half_page_mode,
			"size_scale": book.size_scale,
			"page_state": int(page.get("state", 0)),
			"page_leaf": int(page.get("leaf", 0)),
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is VCRPlayer:
		var vcr := node as VCRPlayer
		var tv_id: int = node_to_id.get(vcr.connected_tv, -1) if vcr.connected_tv != null else -1
		var tv_path: String = ""
		if vcr.connected_tv != null and tv_id == -1:
			tv_path = str(vcr.connected_tv.get_path())
		var tape := vcr.get_snapped_tape()
		var tape_id: int = node_to_id.get(tape, -1) if tape != null else -1
		var result := {
			"id": id,
			"type": "vcr_player",
			"connected_tv_id": tv_id,
			"snapped_tape_id": tape_id,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
		if not tv_path.is_empty():
			result["connected_tv_path"] = tv_path
		return result
	elif node is VCRTape:
		return {
			"id": id,
			"type": "vcr_tape",
			"video_path": (node as VCRTape).video_path,
			"video_label": (node as VCRTape).video_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is DVDPlayer:
		var dvd := node as DVDPlayer
		var tv_id: int = node_to_id.get(dvd.connected_tv, -1) if dvd.connected_tv != null else -1
		var tv_path: String = ""
		if dvd.connected_tv != null and tv_id == -1:
			tv_path = str(dvd.connected_tv.get_path())
		var disc := dvd.get_snapped_disc()
		var disc_id: int = node_to_id.get(disc, -1) if disc != null else -1
		var result := {
			"id": id,
			"type": "dvd_player",
			"connected_tv_id": tv_id,
			"snapped_disc_id": disc_id,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
		if not tv_path.is_empty():
			result["connected_tv_path"] = tv_path
		return result
	elif node is DVDDisc:
		return {
			"id": id,
			"type": "dvd_disc",
			"dvd_path": (node as DVDDisc).dvd_path,
			"dvd_label": (node as DVDDisc).dvd_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroAudioPlayer:
		var ap := node as RetroAudioPlayer
		var media := ap.get_snapped_media()
		var media_id: int = node_to_id.get(media, -1) if media != null else -1
		return {
			"id": id,
			"type": "cd_player" if node is CDPlayer else "cassette_player",
			"snapped_media_id": media_id,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is AudioDisc:
		return {
			"id": id,
			"type": "audio_disc",
			"album_path": (node as AudioDisc).album_path,
			"album_label": (node as AudioDisc).album_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is AudioCassette:
		return {
			"id": id,
			"type": "audio_cassette",
			"album_path": (node as AudioCassette).album_path,
			"album_label": (node as AudioCassette).album_label,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
	elif node is RetroController or node is RayGun or node is RetroMouse or node is RetroKeyboard:
		var obj_type := "retro_controller"
		if node is RayGun:
			obj_type = "ray_gun"
		elif node is RetroMouse:
			obj_type = "retro_mouse"
		elif node is RetroKeyboard:
			obj_type = "retro_keyboard"
		var connected_sys = (node as Node).get("_connected_system")
		var port_idx: int = (node as Node).get("_port_index") if connected_sys != null else -1
		var sys_id: int = node_to_id.get(connected_sys, -1) if connected_sys != null else -1
		var sys_path: String = ""
		if connected_sys != null and sys_id == -1:
			sys_path = str((connected_sys as Node).get_path())
		var entry := {
			"id": id,
			"type": obj_type,
			"device_type": (node as Node).get("device_type") as int,
			"connected_system_id": sys_id,
			"connected_system_path": sys_path,
			"port_index": port_idx,
			"position": [pos.x, pos.y, pos.z],
			"rotation": [rot.x, rot.y, rot.z],
		}
		if node is RetroMouse:
			entry["sensitivity"] = (node as RetroMouse).sensitivity
		return entry
	return {}


func _deserialize_object(data: Dictionary) -> Node3D:
	var obj_type: String = data.get("type", "")
	var obj: Node3D = null

	match obj_type:
		"system":
			var sys := SYSTEM_SCENE.instantiate() as RetroSystem
			sys.systemid = data.get("systemid", "")
			sys.model_variant = data.get("model_variant", "")
			if data.has("video_out"):
				sys._video_out_from_save = 1 if bool(data["video_out"]) else 0
			sys._lid_angle_from_save = float(data.get("lid_angle", -1.0))
			sys.ignore_gravity = bool(data.get("ignore_gravity", false))
			obj = sys
		"tv":
			var tv := TV_SCENE.instantiate() as RetroTV
			tv.crt_enabled = data.get("crt_enabled", true)
			var crt_params: Dictionary = data.get("crt_params", {})
			if not crt_params.is_empty():
				tv.set_crt_params(crt_params)
			tv.scale_factor = data.get("scale_factor", 1.0)
			tv.stereo_mode = int(data.get("stereo_mode", 0))
			obj = tv
		"tv_remote":
			obj = TV_REMOTE_SCENE.instantiate() as Node3D
		"trash_can":
			obj = TRASH_CAN_SCENE.instantiate() as Node3D
		"cartridge":
			var cart := CART_SCENE.instantiate() as RetroCartridge
			cart.rom_path = data.get("rom_path", "")
			cart.game_label = data.get("game_label", "")
			cart.save_id = data.get("save_id", "")
			cart.systemid = data.get("cart_systemid", "")
			obj = cart
		"disc":
			var disc_systemid: String = data.get("cart_systemid", "")
			var disc_scene := UMD_DISC_SCENE if disc_systemid == "playstation_portable" else DISC_SCENE
			var disc := disc_scene.instantiate() as RetroDisc
			disc.rom_path = data.get("rom_path", "")
			disc.game_label = data.get("game_label", "")
			disc.save_id = data.get("save_id", "")
			disc.systemid = disc_systemid
			obj = disc
		"memory_card":
			var card := MEMCARD_SCENE.instantiate() as MemoryCard
			card.card_id = data.get("card_id", "")
			card.card_label = data.get("card_label", "MEMORY CARD")
			obj = card
		"book":
			var book := BOOK_SCENE.instantiate() as PDFBook
			book.half_page_mode = data.get("half_pages", false)
			book.size_scale = data.get("size_scale", 1.0)
			book.pdf_path = data.get("pdf_path", "")
			# Applied after the PDF loads (stashed while _page_count == 0).
			book.set_page(int(data.get("page_state", 0)), int(data.get("page_leaf", 0)))
			obj = book
		"retro_controller":
			obj = RETRO_CONTROLLER_SCENE.instantiate() as Node3D
		"ray_gun":
			obj = RAY_GUN_SCENE.instantiate() as Node3D
		"retro_mouse":
			var mouse := RETRO_MOUSE_SCENE.instantiate() as RetroMouse
			mouse.sensitivity = data.get("sensitivity", 2400.0)
			obj = mouse
		"retro_keyboard":
			obj = RETRO_KEYBOARD_SCENE.instantiate() as Node3D
		"vcr_player":
			obj = VCR_SCENE.instantiate() as Node3D
		"vcr_tape":
			var tape := TAPE_SCENE.instantiate() as VCRTape
			tape.video_path = data.get("video_path", "")
			tape.video_label = data.get("video_label", "")
			obj = tape
		"dvd_player":
			obj = DVD_SCENE.instantiate() as Node3D
		"dvd_disc":
			var disc := DVD_DISC_SCENE.instantiate() as DVDDisc
			disc.dvd_path = data.get("dvd_path", "")
			disc.dvd_label = data.get("dvd_label", "")
			obj = disc
		"cd_player":
			obj = CD_PLAYER_SCENE.instantiate() as Node3D
		"cassette_player":
			obj = CASSETTE_PLAYER_SCENE.instantiate() as Node3D
		"audio_disc":
			var adisc := AUDIO_DISC_SCENE.instantiate() as AudioDisc
			adisc.album_path = data.get("album_path", "")
			adisc.album_label = data.get("album_label", "")
			obj = adisc
		"audio_cassette":
			var acass := AUDIO_CASSETTE_SCENE.instantiate() as AudioCassette
			acass.album_path = data.get("album_path", "")
			acass.album_label = data.get("album_label", "")
			obj = acass
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
