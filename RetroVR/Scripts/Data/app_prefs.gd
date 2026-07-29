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
	}, "\t"))
	file.close()


## A missing key or a JSON null must keep the default, not collapse to false.
func _prefs_bool(data: Dictionary, key: String, fallback: bool) -> bool:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_BOOL:
		return value
	return fallback
