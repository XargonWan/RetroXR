## CartridgeOptionsPanel — floating 3D panel for a cartridge's battery saves.
##
## Parented to a RetroCartridge but top_level so it inherits no transform;
## floats above the cartridge facing the camera. Mirrors BookOptionsPanel.
## Selecting a save re-binds the cartridge's save_id ("recovery"); a new
## blank id means a fresh save. .srm files are never deleted here.
class_name CartridgeOptionsPanel
extends Node3D

const FLOAT_HEIGHT := 0.25

var _cart: RetroCartridge = null
var _camera: Node3D = null
var _ui_connected := false
## Saves the server holds for this cartridge's ROM, fetched when the panel opens.
var _server_saves: Array = []
## save_ids whose last sync forked a conflict, so the row can say so until the
## user acts on it.
var _conflicted: Dictionary = {}

@onready var _viewport_node: XRToolsViewport2DIn3D = $CartOptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _cart and is_instance_valid(_cart):
		global_position = _cart.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


func show_for(cart: RetroCartridge, camera: Node3D) -> void:
	_cart = cart
	_camera = camera
	if _cart:
		global_position = _cart.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()
	_refresh_server_list()


func hide_panel() -> void:
	visible = false


func _get_ui() -> CartridgeOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as CartridgeOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.save_selected.connect(_on_save_selected)
	ui.sync_toggled.connect(_on_sync_toggled)
	ui.server_save_requested.connect(_on_server_save_requested)
	ui.new_synced_save_requested.connect(_on_new_synced_save)
	ui.close_requested.connect(hide_panel)
	SaveSync.sync_finished.connect(_on_sync_finished)
	SaveSync.conflict_forked.connect(_on_conflict_forked)
	_ui_connected = true


func _populate() -> void:
	if not _cart:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	var core := SramPaths.core_for_systemid(_cart.systemid)
	var saves: Array = SramPaths.list_saves(core, _cart.rom_path) if not core.is_empty() else []

	var states: Dictionary = {}
	for s: Variant in saves:
		var sid := str((s as Dictionary).get("save_id", ""))
		var path := SramPaths.cart_save_path(core, _cart.rom_path, sid)
		if _conflicted.has(sid):
			states[sid] = "conflict"
		elif SaveSync.current_key() == RommSaveSync.key_for(path):
			states[sid] = "busy"
		elif SaveSync.is_enabled(path):
			states[sid] = "on"
		else:
			states[sid] = "off"

	ui.populate(_cart.game_label, saves, _cart.save_id, not core.is_empty(),
		states, _server_only(saves), _romm_ready())


## Server slots with no local .srm. The list is fetched on open, so this only
## filters what is already known — it never blocks the panel.
func _server_only(local: Array) -> Array:
	var have: Dictionary = {}
	for s: Variant in local:
		have[str((s as Dictionary).get("save_id", ""))] = true
	var out: Array = []
	for e: Dictionary in _server_saves:
		var slot := str(e.get("slot", ""))
		# Memory-card slots belong to a card, not to this cartridge.
		if slot.is_empty() or slot.begins_with("card:") or have.has(slot):
			continue
		out.append(e)
	return out


func _romm_ready() -> bool:
	return SaveSync.is_available() and _rom_id() > 0


func _rom_id() -> int:
	if _cart == null:
		return 0
	return SaveSync.rom_id_for(_cart.systemid, _cart.rom_path)


func _on_save_selected(save_id: String) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	if save_id.is_empty():
		# New blank save: mint a fresh identity — the first flush creates it.
		_cart.save_id = "%08x%08x" % [randi(), randi()]
	else:
		_cart.save_id = save_id
	print("[CartridgeOptions] %s bound to save %s" % [_cart.game_label, _cart.save_id])
	_populate()


## Start a fresh save already set to sync. Sync is recorded against the path
## before any file exists, so the very first flush uploads instead of the user
## having to come back and toggle it afterwards.
func _on_new_synced_save() -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	var core := SramPaths.core_for_systemid(_cart.systemid)
	var rid := _rom_id()
	if core.is_empty() or rid <= 0:
		return
	var new_id := "%08x%08x" % [randi(), randi()]
	_cart.save_id = new_id
	SaveSync.set_enabled(SramPaths.cart_save_path(core, _cart.rom_path, new_id), true, rid)
	print("[CartridgeOptions] %s bound to new synced save %s" % [_cart.game_label, new_id])
	_populate()


## Turn syncing on or off for one save. Turning it on reconciles immediately
## rather than waiting for the next flush, so a save made on another device
## arrives as soon as you ask for it.
func _on_sync_toggled(save_id: String, on: bool) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	var core := SramPaths.core_for_systemid(_cart.systemid)
	if core.is_empty():
		return
	var path := SramPaths.cart_save_path(core, _cart.rom_path, save_id)
	var rid := _rom_id()
	SaveSync.set_enabled(path, on, rid)
	if on and rid > 0:
		_conflicted.erase(save_id)
		SaveSync.enqueue(path, rid, core, save_id, _cart.game_label)
	_populate()


## Pull a save that only exists on the server. It lands under its own slot id,
## which becomes a local save_id, and the cartridge binds to it — so the two
## sides agree on identity from the first sync onwards.
func _on_server_save_requested(slot: String) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	var core := SramPaths.core_for_systemid(_cart.systemid)
	var rid := _rom_id()
	if core.is_empty() or rid <= 0:
		return
	var path := SramPaths.cart_save_path(core, _cart.rom_path, slot)
	SaveSync.set_enabled(path, true, rid)
	SaveSync.enqueue(path, rid, core, slot, _cart.game_label)
	_cart.save_id = slot
	_populate()


func _on_sync_finished(_key: String, _action: String, _ok: bool, _detail: String) -> void:
	if visible:
		_refresh_server_list()
		_populate()


func _on_conflict_forked(_key: String, forked_save_id: String, _label: String) -> void:
	# Flag the fork, not the original: the fork is the copy the user has not
	# seen, and it is the one that needs explaining.
	_conflicted[forked_save_id] = true
	if visible:
		_populate()


## Ask the server what it has for this ROM. Runs on SaveSync's worker, so the
## panel draws immediately with whatever it already knew.
func _refresh_server_list() -> void:
	var rid := _rom_id()
	if rid <= 0 or not SaveSync.is_available():
		_server_saves = []
		return
	SaveSync.list_server_saves(rid, func(ok: bool, saves: Array) -> void:
		if not ok:
			return
		_server_saves = saves
		if visible:
			_populate()
	)
