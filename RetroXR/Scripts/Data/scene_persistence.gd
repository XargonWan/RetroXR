## ScenePersistence — saves and restores dynamically-spawned objects for the
## arcade scene.  Objects must be in the "spawned" group to be tracked.
##
## Save directory: user://scenes/arcade/
## Manifest:       user://scenes/arcade/manifest.json
## Slot files:     user://scenes/arcade/{id}.json
class_name ScenePersistence
extends RefCounted


const ARCADE_DIR    := "user://scenes/arcade"
const MANIFEST_FILE := "user://scenes/arcade/manifest.json"
const VERSION       := 2
## How long the async restore may hold the main thread before yielding a frame.
const FRAME_BUDGET_USEC := 4000

## Bumped by every async restore as it starts. Because those yield frames, a
## second one can begin — a room change auto-loading a slot on top of a slot the
## player picked from the menu — and the two then build into the same room while
## clear_scene() frees what the other just spawned, leaving live systems holding
## freed cable plugs. The older run checks this after each yield and stands down.
static var _restore_generation := 0

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
const COMPOSITE_CABLE_SCENE  := preload("res://Scenes/Objects/composite_cable.tscn")
const MONO_CABLE_SCENE       := preload("res://Scenes/Objects/mono_composite_cable.tscn")
const TRASH_CAN_SCENE        := preload("res://Scenes/Objects/trash_can.tscn")
const RETRO_MOUSE_SCENE      := preload("res://Scenes/Objects/retro_mouse.tscn")
const SNES_MOUSE_SCENE       := preload("res://Scenes/Objects/snes_mouse.tscn")
const RETRO_KEYBOARD_SCENE   := preload("res://Scenes/Objects/retro_keyboard.tscn")

## Types whose entry carries nothing but a pose — instantiate and place, no
## properties to apply. Types that need more are match arms in
## _deserialize_object().
const PLAIN_SCENES := {
	"tv_remote": TV_REMOTE_SCENE,
	"trash_can": TRASH_CAN_SCENE,
	"ray_gun": RAY_GUN_SCENE,
	"retro_keyboard": RETRO_KEYBOARD_SCENE,
	"vcr_player": VCR_SCENE,
	"dvd_player": DVD_SCENE,
	"cd_player": CD_PLAYER_SCENE,
	"cassette_player": CASSETTE_PLAYER_SCENE,
}


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


## Clear the scene then restore from the slot file, spread over frames — see
## instantiate_objects_async(). Loading "clean" just clears the scene.
##
## A coroutine: callers must await it, or they get a Signal back and the room
## fills in behind them.
func load_slot_async(root: Node, slot_id: String) -> bool:
	if slot_id == "clean":
		clear_scene(root)
		return true
	var path := _slot_file(slot_id)
	if not FileAccess.file_exists(path):
		push_warning("ScenePersistence: slot file not found '%s'" % path)
		return false
	clear_scene(root)
	var objects: Variant = _read_objects(path)
	if objects == null:
		return false
	var spawned: Dictionary = await instantiate_objects_async(root, objects)
	print("[ScenePersistence] loaded %d objects from '%s'" % [spawned.size(), path])
	return true


## Remove a slot from the manifest and delete its file.
func delete_slot(slot_id: String) -> bool:
	if slot_id == "clean":
		return false
	var m := _load_manifest()
	var new_slots: Array = []
	for s: Variant in m.get("slots", []):
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


func _empty_manifest() -> Dictionary:
	return {"version": VERSION, "slots": []}


func _load_manifest() -> Dictionary:
	if FileAccess.file_exists(MANIFEST_FILE):
		var f := FileAccess.open(MANIFEST_FILE, FileAccess.READ)
		if f:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				return parsed as Dictionary
	return _empty_manifest()


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
	# The whole map has to exist before anything serializes: a reference can point
	# either way through the set.
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


## The object entries of a slot file, or null if it cannot be read.
func _read_objects(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		push_error("ScenePersistence: invalid slot file '%s'" % path)
		return null
	var d := parsed as Dictionary
	# Refused rather than migrated. Every cross-reference changed shape in v2, so
	# a v1 file still restores its objects — into a room where nothing is plugged
	# into anything, which reads as a bug rather than as an old save.
	var file_version := int(d.get("version", 1))
	if file_version != VERSION:
		push_warning("ScenePersistence: slot '%s' is version %d, this build reads %d"
			% [path, file_version, VERSION])
		return null
	var objects: Variant = d.get("objects", [])
	return objects if objects is Array else null


# ── Cross-references ───────────────────────────────────────────────────────────
#
# One object pointing at another is the only thing in a slot file that isn't a
# plain value, and it comes in two flavours: a peer inside this save, and a
# fixture standing in the room that the save doesn't own. Both encode to a single
# JSON value — an int id for the peer, a scene path for the fixture, null for
# nothing — so every site that records or resolves a reference uses this pair
# rather than its own _id/_path key couple.

## Encode a reference to target. Returns int, String or null.
func _ref(node_to_id: Dictionary, target: Node) -> Variant:
	if target == null:
		return null
	if node_to_id.has(target):
		return node_to_id[target]
	# Not in the map. A scene-placed fixture has no id and never will, so name it
	# by path. A "spawned" node missing from the map means a partial serialize
	# (ObjectSync ships one object at a time) — its path is a dynamic name that
	# means nothing to the peer receiving it, so drop the reference instead.
	if target.is_in_group("spawned"):
		return null
	return str(target.get_path())


## Resolve what _ref() wrote. Null when the reference was empty or has gone.
func _resolve_ref(root: Node, spawned: Dictionary, ref: Variant) -> Node:
	if ref == null:
		return null
	if ref is String:
		var node := root.get_node_or_null(ref as String)
		if node == null:
			push_warning("[ScenePersistence] no node at '%s'" % ref)
		return node
	# JSON has no integer type, so an id parses back as a float.
	return spawned.get(int(ref)) as Node


## Instantiate serialized object entries under root and restore their
## cross-connections (two passes). Returns {id: Node3D} for the spawned set.
## Shared by slot loading and multiplayer world snapshots (ObjectSync).
func instantiate_objects(root: Node, objects: Array) -> Dictionary:
	var spawned: Dictionary = {}
	var entries: Dictionary = {}
	for entry: Variant in objects:
		_spawn_entry(root, entry, spawned, entries)
	_restore_connections(root, spawned, entries)
	return spawned


## Same, but hands a frame back once it has held the main thread for
## FRAME_BUDGET_USEC. A slot restored as part of a room change is built at the
## exact moment the headset has nothing new to draw: a save with a dozen systems
## in it blocks for a second, and a blocked main thread in VR is a frozen image,
## not a slow one. Callers that need every object within the frame — netplay
## snapshots — use instantiate_objects(), which stays a plain function because a
## body containing await would hand them a Signal instead of the spawned set.
func instantiate_objects_async(root: Node, objects: Array) -> Dictionary:
	var spawned: Dictionary = {}
	var entries: Dictionary = {}
	var tree := root.get_tree()
	_restore_generation += 1
	var generation := _restore_generation
	var deadline := Time.get_ticks_usec() + FRAME_BUDGET_USEC
	for entry: Variant in objects:
		# A saved bespoke console names a GLB that may still be warming at boot.
		# Spawning it now would load() that GLB synchronously inside _ready —
		# measured 6.9 s of frozen frame for the NES on a Quest 3. Await it into
		# the cache instead; once warm this never suspends.
		await _acquire_entry_assets(entry)
		if not _still_ours(root, generation):
			return spawned
		_spawn_entry(root, entry, spawned, entries)
		if Time.get_ticks_usec() < deadline:
			continue
		await tree.process_frame
		if not _still_ours(root, generation):
			return spawned
		deadline = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	await _restore_connections_async(root, spawned, entries, generation)
	return spawned


## No-op for everything but a system entry whose model carries external assets.
func _acquire_entry_assets(entry: Variant) -> void:
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	if str(d.get("type", "")) != "system":
		return
	var row := SystemModelRegistry.resolve(str(d.get("model_id", "")), str(d.get("systemid", "")))
	for path: String in row.get("requires", []):
		await ModelWarmer.acquire(path)


func _spawn_entry(root: Node, entry: Variant, spawned: Dictionary, entries: Dictionary) -> void:
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	var id: int = d.get("id", -1)
	if id < 0:
		return
	var obj := _deserialize_object(d)
	if obj == null:
		return
	root.add_child(obj)
	obj.add_to_group("spawned")
	spawned[id] = obj
	entries[id] = d


## Pass 2: wire the spawned objects to each other. Has to run after every object
## exists, because a connection can point either way through the set.
func _restore_connections(root: Node, spawned: Dictionary, entries: Dictionary) -> void:
	for id: int in spawned:
		_restore_entry(root, id, spawned, entries)
	_report_restored(spawned)


## Same, yielding a frame whenever it has held the main thread too long.
func _restore_connections_async(root: Node, spawned: Dictionary, entries: Dictionary,
		generation: int) -> void:
	var tree := root.get_tree()
	var deadline := Time.get_ticks_usec() + FRAME_BUDGET_USEC
	for id: int in spawned:
		_restore_entry(root, id, spawned, entries)
		if Time.get_ticks_usec() < deadline:
			continue
		await tree.process_frame
		if not _still_ours(root, generation):
			return
		deadline = Time.get_ticks_usec() + FRAME_BUDGET_USEC
	_report_restored(spawned)


## False once the room we are building into has gone, or once a newer restore
## has taken over — either way this run must not touch the scene again.
##
## root is Variant on purpose. Being handed a freed room is the whole reason this
## exists, and binding a freed object to a Node-typed parameter throws before the
## body can run — the same way assigning one to a typed local does.
func _still_ours(root: Variant, generation: int) -> bool:
	if generation != _restore_generation:
		return false
	return is_instance_valid(root) and (root as Node).is_inside_tree()


func _report_restored(spawned: Dictionary) -> void:
	if spawned.size() > 0:
		print("[ScenePersistence] instantiated %d objects" % spawned.size())


func _restore_entry(root: Node, id: int, spawned: Dictionary, entries: Dictionary) -> void:
	# The async pass yields frames, so an object spawned earlier in this very run
	# may already have been freed by the time we come to wire it up.
	if not is_instance_valid(spawned[id]):
		return
	var obj: Node = spawned[id]
	var d: Dictionary = entries[id]

	if obj is RetroSystem:
		var sys := obj as RetroSystem
		var tv := _resolve_ref(root, spawned, d.get("tv")) as RetroTV
		if tv:
			sys.restore_cable_connection(tv)
		# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM). A save
		# made against a model with more channels than this one has is truncated —
		# restore_cable_connection would silently fold the overflow onto ch 0.
		var extra: Array = d.get("extra_tvs", [])
		for i in range(mini(extra.size(), sys.get_channel_count() - 1)):
			var ch_tv := _resolve_ref(root, spawned, extra[i]) as RetroTV
			if ch_tv:
				sys.restore_cable_connection(ch_tv, i + 1)
		var cart := _resolve_ref(root, spawned, d.get("cartridge")) as RetroCartridge
		if cart:
			sys.restore_cartridge(cart)
		var memcard := _resolve_ref(root, spawned, d.get("memcard")) as MemoryCard
		if memcard:
			sys.restore_memory_card(memcard)
		# After the media, and deferred: seating a cartridge swings the bay open (the
		# NES flap) and tweens it there, either of which would otherwise win over the
		# pose the system restored when its model loaded.
		var lid_angle := float(d.get("lid_angle", -1.0))
		if lid_angle >= 0.0:
			sys.set_lid_angle_deg.call_deferred(lid_angle)
	elif obj is VCRPlayer:
		var tape := _resolve_ref(root, spawned, d.get("tape")) as VCRTape
		if tape:
			(obj as VCRPlayer).restore_tape(tape)
	elif obj is DVDPlayer:
		var disc := _resolve_ref(root, spawned, d.get("disc")) as DVDDisc
		if disc:
			(obj as DVDPlayer).restore_disc(disc)
	elif obj is RetroAudioPlayer:
		var media := _resolve_ref(root, spawned, d.get("media"))
		if media is AudioDisc or media is AudioCassette:
			(obj as RetroAudioPlayer).restore_media(media as Node3D)
	elif obj is CompositeCable:
		# Pass 2, so every deck and set the plugs point at already exists. A plug
		# whose socket cannot be found is simply left where it was saved — a loose
		# end on the floor beats one seated in the wrong device.
		var seats: Array = []
		for rec: Dictionary in d.get("plugs", []):
			seats.append({
				"end": int(rec.get("end", 0)),
				"cord": int(rec.get("cord", 0)),
				"position": rec.get("position", []),
				"rotation": rec.get("rotation", []),
				"device": _resolve_ref(root, spawned, rec.get("device")) as Node3D,
				"port": str(rec.get("port", "")),
			})
		(obj as CompositeCable).restore_seating(seats)
	elif obj is RetroController or obj is RayGun or obj is RetroMouse or obj is RetroKeyboard:
		var port_idx := int(d.get("port_index", -1))
		if port_idx < 0:
			return
		var sys := _resolve_ref(root, spawned, d.get("system")) as RetroSystem
		if sys == null:
			push_warning("[ScenePersistence] controller id=%d: system not found" % id)
			return
		obj.call("restore_port_connection", sys, port_idx)


# ── Serialization ──────────────────────────────────────────────────────────────

## id, type and pose — the four fields every entry carries. Each branch of
## _serialize_node() merges its own fields onto this.
func _base(id: int, type_name: String, n3d: Node3D) -> Dictionary:
	var pos := n3d.global_position
	var rot := n3d.global_rotation_degrees
	return {
		"id": id,
		"type": type_name,
		"position": [pos.x, pos.y, pos.z],
		"rotation": [rot.x, rot.y, rot.z],
	}


## An ordered chain, not a lookup table: `is` matches every ancestor, so a
## subtype has to be tested before the type it extends. The two places that
## matters are marked below.
func _serialize_node(node: Node, id: int, node_to_id: Dictionary) -> Dictionary:
	if not node is Node3D:
		return {}
	var n3d := node as Node3D

	if node is RetroSystem:
		var sys := node as RetroSystem
		var result := _base(id, "system", n3d).merged({
			"systemid": sys.systemid,
			"model_id": sys.model_id,
			"tv": _ref(node_to_id, sys.connected_tv),
			"cartridge": _ref(node_to_id, sys.get_snapped_cartridge()),
			"memcard": _ref(node_to_id, sys.get_snapped_memcard()),
			"video_out": sys.video_out_enabled,
			"ignore_gravity": sys.ignore_gravity,
		})
		# Clamshell lid angle (DS/3DS); omitted for systems without a lid.
		var lid_angle := sys.get_lid_angle_deg()
		if lid_angle >= 0.0:
			result["lid_angle"] = lid_angle
		# Extra video-out channels (dual-screen handhelds: ch 1 = BOTTOM).
		var extra: Array = []
		for ch in range(1, sys.get_channel_count()):
			extra.append(_ref(node_to_id, sys.get_channel_tv(ch)))
		if not extra.is_empty():
			result["extra_tvs"] = extra
		return result
	elif node is RetroTV:
		var tv := node as RetroTV
		return _base(id, "tv", n3d).merged({
			"crt_enabled": tv.crt_enabled,
			"crt_params": tv.get_crt_params(),
			"scale_factor": tv.scale_factor,
			"stereo_mode": tv.stereo_mode,
		})
	elif node is TVRemote:
		return _base(id, "tv_remote", n3d)
	elif node is TrashCan:
		return _base(id, "trash_can", n3d)
	elif node is RetroDisc:
		# MUST precede the RetroCartridge branch — RetroDisc extends it.
		return _base(id, "disc", n3d).merged(_media_fields(node as RetroCartridge))
	elif node is RetroCartridge:
		return _base(id, "cartridge", n3d).merged(_media_fields(node as RetroCartridge))
	elif node is MemoryCard:
		var card := node as MemoryCard
		return _base(id, "memory_card", n3d).merged({
			"card_id": card.card_id,
			"card_label": card.card_label,
		})
	elif node is PDFBook:
		var book := node as PDFBook
		var page := book.net_get_page()
		return _base(id, "book", n3d).merged({
			"pdf_path": book.pdf_path,
			"half_pages": book.half_page_mode,
			"size_scale": book.size_scale,
			"page_state": int(page.get("state", 0)),
			"page_leaf": int(page.get("leaf", 0)),
		})
	elif node is VCRPlayer:
		# The deck's own TV link is not saved: the lead is a separate object now, so
		# the connection lives in a spawned cable's plugs. Same for the DVD player.
		return _base(id, "vcr_player", n3d).merged({
			"tape": _ref(node_to_id, (node as VCRPlayer).get_snapped_tape()),
		})
	elif node is VCRTape:
		var tape := node as VCRTape
		return _base(id, "vcr_tape", n3d).merged({
			"video_path": tape.video_path,
			"video_label": tape.video_label,
		})
	elif node is DVDPlayer:
		return _base(id, "dvd_player", n3d).merged({
			"disc": _ref(node_to_id, (node as DVDPlayer).get_snapped_disc()),
		})
	elif node is DVDDisc:
		var dvd := node as DVDDisc
		return _base(id, "dvd_disc", n3d).merged({
			"dvd_path": dvd.dvd_path,
			"dvd_label": dvd.dvd_label,
		})
	elif node is RetroAudioPlayer:
		var ap := node as RetroAudioPlayer
		return _base(id, "cd_player" if node is CDPlayer else "cassette_player", n3d).merged({
			"media": _ref(node_to_id, ap.get_snapped_media()),
		})
	elif node is AudioDisc:
		var adisc := node as AudioDisc
		return _base(id, "audio_disc", n3d).merged({
			"album_path": adisc.album_path,
			"album_label": adisc.album_label,
		})
	elif node is AudioCassette:
		var acass := node as AudioCassette
		return _base(id, "audio_cassette", n3d).merged({
			"album_path": acass.album_path,
			"album_label": acass.album_label,
		})
	elif node is RetroController or node is RayGun or node is RetroMouse or node is RetroKeyboard:
		return _serialize_peripheral(node, id, n3d, node_to_id)
	elif node is CompositeCable:
		return _serialize_cable(node as CompositeCable, id, n3d, node_to_id)
	return {}


func _media_fields(cart: RetroCartridge) -> Dictionary:
	return {
		"rom_path": cart.rom_path,
		"game_label": cart.game_label,
		"save_id": cart.save_id,
		"cart_systemid": cart.systemid,
	}


func _serialize_peripheral(node: Node, id: int, n3d: Node3D, node_to_id: Dictionary) -> Dictionary:
	var obj_type := "retro_controller"
	if node is RayGun:
		obj_type = "ray_gun"
	elif node is SnesMouse:
		# Before the RetroMouse arm, which it also satisfies — reaching that
		# first would save the SNES mouse as the primitive one and hand the
		# player a grey box back.
		obj_type = "snes_mouse"
	elif node is RetroMouse:
		obj_type = "retro_mouse"
	elif node is RetroKeyboard:
		obj_type = "retro_keyboard"
	var connected_sys: Node = node.get("_connected_system")
	var entry := _base(id, obj_type, n3d).merged({
		"device_type": node.get("device_type") as int,
		"system": _ref(node_to_id, connected_sys),
		"port_index": node.get("_port_index") if connected_sys != null else -1,
	})
	if node is RetroMouse:
		entry["sensitivity"] = (node as RetroMouse).sensitivity
	if node is RetroController:
		# Every real pad — NES, Virtual Boy, CX40 — is a RetroController with a
		# scene of its own, so the type above maps the whole family back onto the
		# generic grey pad. The scene is what tells them apart.
		entry["scene"] = node.scene_file_path
	return entry


## Six independent ends, so the lead is saved as six plugs rather than as one
## object with a position: each carries its own pose and, if it is in a socket,
## the device and the socket's node name. The name is what makes this readable
## and stable — "AudioLIn" survives any renumbering of ports, which an index
## would not.
func _serialize_cable(cable: CompositeCable, id: int, n3d: Node3D,
		node_to_id: Dictionary) -> Dictionary:
	var plugs: Array = []
	for seat: Dictionary in cable.seating():
		var plug := seat["plug"] as Node3D
		var ppos := plug.global_position
		var prot := plug.global_rotation_degrees
		plugs.append({
			"end": seat["end"],
			"cord": seat["cord"],
			"position": [ppos.x, ppos.y, ppos.z],
			"rotation": [prot.x, prot.y, prot.z],
			"port": seat["port"],
			"device": _ref(node_to_id, seat["device"] as Node),
		})
	return _base(id, "composite_cable", n3d).merged({
		# 2 = the mono lead, 3 = the full one. Both are CompositeCable; only
		# the scene differs, so the count is what picks it back up.
		"cords": cable.cord_count(),
		"plugs": plugs,
	})


## The pad scene the entry names, or the generic pad when the save predates the
## field, names a scene this build no longer ships, or names something that is
## not a controller at all. ResourceLoader.exists, not FileAccess: paths are
## remapped into the pck in an exported build.
func _instantiate_controller(data: Dictionary) -> Node3D:
	var path: String = str(data.get("scene", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		var packed := ResourceLoader.load(path) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			if inst is RetroController:
				return inst
			if inst != null:
				push_warning("ScenePersistence: '%s' is not a controller" % path)
				inst.queue_free()
	return RETRO_CONTROLLER_SCENE.instantiate() as Node3D


func _deserialize_object(data: Dictionary) -> Node3D:
	var obj_type: String = data.get("type", "")
	var obj: Node3D = null

	if PLAIN_SCENES.has(obj_type):
		obj = (PLAIN_SCENES[obj_type] as PackedScene).instantiate() as Node3D
	else:
		match obj_type:
			"system":
				var sys := SYSTEM_SCENE.instantiate() as RetroSystem
				sys.systemid = data.get("systemid", "")
				sys.model_id = str(data.get("model_id", ""))
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
			"cartridge":
				var cart := CART_SCENE.instantiate() as RetroCartridge
				_apply_media_fields(cart, data)
				obj = cart
			"disc":
				var disc_systemid: String = data.get("cart_systemid", "")
				var disc_scene := UMD_DISC_SCENE if disc_systemid == "playstation_portable" else DISC_SCENE
				var disc := disc_scene.instantiate() as RetroDisc
				_apply_media_fields(disc, data)
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
				obj = _instantiate_controller(data)
			"retro_mouse":
				var mouse := RETRO_MOUSE_SCENE.instantiate() as RetroMouse
				mouse.sensitivity = data.get("sensitivity", 2400.0)
				obj = mouse
			"snes_mouse":
				var snes := SNES_MOUSE_SCENE.instantiate() as SnesMouse
				snes.sensitivity = data.get("sensitivity", 2400.0)
				obj = snes
			"vcr_tape":
				var tape := TAPE_SCENE.instantiate() as VCRTape
				tape.video_path = data.get("video_path", "")
				tape.video_label = data.get("video_label", "")
				obj = tape
			"dvd_disc":
				var disc := DVD_DISC_SCENE.instantiate() as DVDDisc
				disc.dvd_path = data.get("dvd_path", "")
				disc.dvd_label = data.get("dvd_label", "")
				obj = disc
			"composite_cable":
				obj = (MONO_CABLE_SCENE if int(data.get("cords", 3)) == 2
					else COMPOSITE_CABLE_SCENE).instantiate() as Node3D
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


func _apply_media_fields(cart: RetroCartridge, data: Dictionary) -> void:
	cart.rom_path = data.get("rom_path", "")
	cart.game_label = data.get("game_label", "")
	cart.save_id = data.get("save_id", "")
	cart.systemid = data.get("cart_systemid", "")
