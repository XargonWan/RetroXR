## AppPrefs — Autoload singleton holding the boolean switches on the menu's
## OPTIONS tab, persisted to user://app_prefs.json.
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


func _ready() -> void:
	_load_prefs()
	ControllerModel.draw_hands = controller_hands
	SystemFilter.enabled = system_filter


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
	}, "\t"))
	file.close()


## A missing key or a JSON null must keep the default, not collapse to false.
func _prefs_bool(data: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_BOOL:
		return value
	return fallback


## Same contract as _prefs_bool. JSON gives back numbers as floats, so callers
## reading a count out of this must int() it.
func _prefs_dict(data: Dictionary, key: String, fallback: Dictionary) -> Dictionary:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_DICTIONARY:
		return value
	return fallback
