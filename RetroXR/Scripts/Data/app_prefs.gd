## AppPrefs — Autoload singleton holding the switches on the menu's OPTIONS tab,
## plus the player's hidden-systems list, persisted to user://app_prefs.json.
##
## Switches that back a global static (ControllerModel.draw_hands,
## SystemFilter.enabled) are pushed into it here at boot. The rest need the rig
## or the scene tree, so SpawnMenuController applies those once the menu is
## connected and the camera has been found.
##
## Defaults below are the values a fresh install starts with; a key missing from
## the JSON keeps its default rather than reading as false.
extends Node

const PREFS_PATH := "user://app_prefs.json"

var auto_save_scene:  bool = true
var show_fps:         bool = false
var aim_crosshair:    bool = true
var controller_hands: bool = false
var system_filter:    bool = true
## Whether the spawn menu wraps onto a cylinder. Unlike the rest, this one is not
## an OPTIONS switch — it is the toggle on the menu's own lower-right corner.
var menu_curved:      bool = true
## Whether HeldHint pops its tooltip over a picked-up device.
var show_hints:       bool = true
## HeldHint row id -> times the player has used that verb. A row stops appearing
## past HeldHint.LEARNED_AFTER. A dictionary rather than a key per row so a new
## hint needs no change here.
var hint_uses:        Dictionary = {}
## Whether sound is spatialised by Meta XR Audio rather than Godot's own panning.
## Desktop only, and only offered there: on the Quest the SDK is the entire point,
## and its binaural rendering is right for a headset. On a desk it is not always —
## over speakers the HRTF is working against the room, and a surround rig gets no
## centre channel out of it, because the SDK renders two channels by design.
var spatial_audio_sdk: bool = true
## How the player gets around. Both verbs are on the LEFT stick and exactly one
## is live at a time — pushing the stick forward cannot mean "walk" and "aim a
## teleport" at once. False (smooth walking) is the default because it is the
## one that needs no explaining; teleport is the comfort option.
var locomotion_teleport: bool = false
## Systemids the player has hidden from the Systems and Cartridges grids. One
## list for both: hiding a machine means "I don't care about this", not "not in
## this tab". Distinct from SystemFilter, which is our own opinion about which
## systemids are not consoles — this is the player's, and it survives a core
## being installed or removed.
var hidden_systems: PackedStringArray = []
## Show the hidden ones anyway, dimmed, so they can be unhidden. Not persisted
## as "off forever": a player who turns it on to unhide something and walks away
## should find the grid the way they left it.
var show_hidden_systems: bool = false
## Draw the Systems and Cartridges grids as squares of bare art — no name, no
## core count, no source badge. One pref for both, like the hidden list: it is a
## statement about how you want to read a grid, not about one tab.
var compact_tiles: bool = false


## True when this systemid should be kept out of the grids.
func is_system_hidden(systemid: String) -> bool:
	return systemid in hidden_systems


## Hide or unhide a systemid and persist. No-op if already in that state.
func set_system_hidden(systemid: String, hidden: bool) -> void:
	if systemid.is_empty() or is_system_hidden(systemid) == hidden:
		return
	if hidden:
		hidden_systems.append(systemid)
	else:
		hidden_systems.remove_at(hidden_systems.find(systemid))
	save_prefs()


func _ready() -> void:
	_load_prefs()
	ControllerModel.draw_hands = controller_hands
	SystemFilter.enabled = system_filter
	_apply_spatial_audio()


## Push the audio backend choice before anything builds an emitter. Ignored on
## Android, where the option is not offered and the pref could only be stale.
func _apply_spatial_audio() -> void:
	if OS.get_name() == "Android":
		return
	var listener := get_node_or_null("/root/SpatialAudioListener")
	if listener != null:
		listener.set_sdk_enabled(spatial_audio_sdk)
	elif Engine.has_singleton("MetaXRAudio"):
		Engine.get_singleton("MetaXRAudio").call("set_enabled", spatial_audio_sdk)


# ── Persistence ───────────────────────────────────────────────────────────────

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	auto_save_scene  = _prefs_bool(data, "auto_save_scene",  auto_save_scene)
	show_fps         = _prefs_bool(data, "show_fps",         show_fps)
	aim_crosshair    = _prefs_bool(data, "aim_crosshair",    aim_crosshair)
	controller_hands = _prefs_bool(data, "controller_hands", controller_hands)
	system_filter    = _prefs_bool(data, "system_filter",    system_filter)
	menu_curved      = _prefs_bool(data, "menu_curved",      menu_curved)
	show_hints       = _prefs_bool(data, "show_hints",       show_hints)
	hint_uses        = _prefs_dict(data, "hint_uses",        hint_uses)
	spatial_audio_sdk = _prefs_bool(data, "spatial_audio_sdk", spatial_audio_sdk)
	locomotion_teleport = _prefs_bool(data, "locomotion_teleport", locomotion_teleport)
	hidden_systems      = _prefs_strings(data, "hidden_systems")
	show_hidden_systems = _prefs_bool(data, "show_hidden_systems", show_hidden_systems)
	compact_tiles       = _prefs_bool(data, "compact_tiles",       compact_tiles)


func save_prefs() -> void:
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("AppPrefs: cannot write %s" % PREFS_PATH)
		return
	file.store_string(JSON.stringify({
		"auto_save_scene":  auto_save_scene,
		"show_fps":         show_fps,
		"aim_crosshair":    aim_crosshair,
		"controller_hands": controller_hands,
		"system_filter":    system_filter,
		"menu_curved":      menu_curved,
		"show_hints":       show_hints,
		"hint_uses":        hint_uses,
		"spatial_audio_sdk": spatial_audio_sdk,
		"locomotion_teleport": locomotion_teleport,
		"hidden_systems":    hidden_systems,
		"show_hidden_systems": show_hidden_systems,
		"compact_tiles":     compact_tiles,
	}, "\t"))
	file.close()


## A missing key or a JSON null must keep the default, not collapse to false.
func _prefs_bool(data: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_BOOL:
		return value
	return fallback


## JSON has no packed-array type, so a saved PackedStringArray reads back as a
## plain Array of whatever was in it. Rebuild it element by element and drop
## anything that is not a string rather than trusting the file.
func _prefs_strings(data: Dictionary, key: String) -> PackedStringArray:
	var out := PackedStringArray()
	var value: Variant = data.get(key)
	if typeof(value) != TYPE_ARRAY:
		return out
	for v: Variant in value as Array:
		if typeof(v) == TYPE_STRING and not (v as String).is_empty():
			out.append(v)
	return out


## Same contract as _prefs_bool. JSON gives back numbers as floats, so callers
## reading a count out of this must int() it.
func _prefs_dict(data: Dictionary, key: String, fallback: Dictionary) -> Dictionary:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_DICTIONARY:
		return value
	return fallback
