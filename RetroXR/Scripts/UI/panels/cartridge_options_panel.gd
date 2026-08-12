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
## Set when another panel hosts a COPY of the UI (the core options Cartridge tab).
## This panel then drives that copy as well as its own quad — it does not stop
## owning the quad, and the two are never on screen at the same moment.
var _external_ui: CartridgeOptions2D = null
## Saves the server holds for this cartridge's ROM, fetched when the panel opens.
var _server_saves: Array = []
## save_ids whose last sync forked a conflict, so the row can say so until the
## user acts on it.
var _conflicted: Dictionary = {}

@onready var _viewport_node: XRToolsViewport2DIn3D = $CartOptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


## Repopulate targets: this panel's own quad when it is up, and the embedded copy
## in the core options Cartridge tab whenever that exists. Without the second the
## embedded list never refreshes, because this node is never `visible`.
func _showing() -> bool:
	return visible or is_instance_valid(_external_ui)


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


## Drive a UI that lives somewhere else — the core options panel's Cartridge tab
## hosts an embedded CartridgeOptions2D, and all the save management, RomM sync
## and achievement lookup below should serve it rather than being written twice.
##
## The host owns the Control's lifetime; this node keeps only the reference and
## its own quad stays hidden.
func adopt_external_ui(ui: CartridgeOptions2D, cart: RetroCartridge) -> void:
	_external_ui = ui
	_cart = cart
	_ensure_ui_connected()
	_populate()
	_refresh_server_list()


## The Control inside this panel's own quad, or null before it is built.
func _own_ui() -> CartridgeOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as CartridgeOptions2D


## Every UI this panel is driving right now: its own quad's while that is up, and
## the embedded copy whenever a host has one.
##
## Both, not one of them. This used to answer with the embedded copy whenever it
## existed — so once a console's Cartridge tab had borrowed this panel, opening
## the cartridge's OWN panel populated the hidden copy instead: the quad floating
## in front of you was the freshly built, never-populated one, with an empty saves
## list (not even "New blank save") and a ✕ that had never been connected to
## anything. Feeding both also keeps the tab in step while the panel is up.
func _uis() -> Array[CartridgeOptions2D]:
	var out: Array[CartridgeOptions2D] = []
	if visible:
		var own := _own_ui()
		if own != null:
			out.append(own)
	if is_instance_valid(_external_ui) and not out.has(_external_ui):
		out.append(_external_ui)
	return out


## True while a UI this panel should be driving has not been built yet, so the
## caller knows to try again next frame rather than silently doing nothing.
func _ui_pending() -> bool:
	return visible and _own_ui() == null


func _ensure_ui_connected() -> void:
	if _ui_pending():
		call_deferred("_ensure_ui_connected")
	# Per UI rather than behind one flag: this panel drives two different Controls
	# over its life and whichever it meets second needs connecting too.
	for ui: CartridgeOptions2D in _uis():
		if not ui.save_selected.is_connected(_on_save_selected):
			ui.save_selected.connect(_on_save_selected)
			ui.sync_toggled.connect(_on_sync_toggled)
			ui.server_save_requested.connect(_on_server_save_requested)
			ui.new_synced_save_requested.connect(_on_new_synced_save)
		# The embedded copy has no ✕ of its own; its host closes it.
		if ui != _external_ui and not ui.close_requested.is_connected(hide_panel):
			ui.close_requested.connect(hide_panel)
	# One-shot: these are global signals, and the guard is what stops a second
	# adopt_external_ui() stacking another connection on every one.
	if not SaveSync.sync_finished.is_connected(_on_sync_finished):
		SaveSync.sync_finished.connect(_on_sync_finished)
		SaveSync.conflict_forked.connect(_on_conflict_forked)
		RA.game_loaded.connect(_on_ra_changed)
		RA.achievement_unlocked.connect(_on_ra_unlocked)


func _populate() -> void:
	if not _cart:
		return
	if _ui_pending():
		call_deferred("_populate")
		return
	var uis := _uis()
	if uis.is_empty():
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

	for ui: CartridgeOptions2D in uis:
		ui.populate(_cart.game_label, _cart.rom_path, saves, _cart.save_id,
			not core.is_empty(), states, _server_only(saves), _romm_ready())
		_populate_achievements(ui)


## The Achievements ribbon. rcheevos keeps one session for the whole app, so the
## list it holds belongs to whichever machine claimed it — this cartridge only
## gets to show it when it is the one in that machine. Every other case is an
## empty state with the reason, because "no achievements" and "not this cart" and
## "not signed in" are different problems and the player can only fix one of them.
func _populate_achievements(ui: CartridgeOptions2D) -> void:
	if not RA.is_available():
		ui.populate_achievements([], {}, "Achievements are unavailable in this build.")
		return
	if not RaConsoles.is_supported(_cart.systemid):
		var what := _cart.systemid if not _cart.systemid.is_empty() else "this system"
		ui.populate_achievements([], {},
			"RetroAchievements has no achievement sets for %s." % what)
		return
	if not RA.is_logged_in():
		ui.populate_achievements([], {},
			"Sign in to RetroAchievements in OPTIONS to track achievements.")
		return
	if not _is_live_cartridge():
		ui.populate_achievements([], {},
			"Insert this cartridge and power the console on to see its achievements.")
		return

	var entries := RA.achievements()
	if entries.is_empty():
		ui.populate_achievements([], {},
			"RetroAchievements has no achievement set for this game.")
		return
	ui.populate_achievements(entries, RA.game_info(), "")


## True when this cartridge is the one in the machine holding the RA session.
func _is_live_cartridge() -> bool:
	var owner_system := RA.session_owner()
	if owner_system == null or not owner_system.has_method("get_snapped_cartridge"):
		return false
	return owner_system.get_snapped_cartridge() == _cart


func _on_ra_changed(_ok: bool, _title: String, _n: int, _u: int, _err: String) -> void:
	if _showing():
		_populate()


func _on_ra_unlocked(_id: int, _t: String, _d: String, _p: int, _b: Texture2D) -> void:
	if _showing():
		_populate()


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
	if _showing():
		_refresh_server_list()
		_populate()


func _on_conflict_forked(_key: String, forked_save_id: String, _label: String) -> void:
	# Flag the fork, not the original: the fork is the copy the user has not
	# seen, and it is the one that needs explaining.
	_conflicted[forked_save_id] = true
	if _showing():
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
		if _showing():
			_populate()
	)
