## SceneManager — Autoload that tracks the active scene and handles transitions.
##
## Coordinates with ScenePersistence to auto-save arcade state when switching
## scenes (if auto_save_on_switch is enabled).
extends Node


signal scene_changed(scene_id: String)
signal active_slot_changed(slot_id: String)

const SCENE_PATHS := {
	"arcade":      "res://Scenes/MainScene.tscn",
	"den":         "res://Scenes/DenScene.tscn",
	"passthrough": "res://Scenes/PassthroughScene.tscn",
}
const PREFS_FILE := "user://scenes/prefs.json"

var current_scene_id: String = "arcade"
var auto_save_on_switch: bool = true
var active_slot_id: String = "clean"

## Set by NetworkManager around host-driven scene switches so the client
## guard in change_scene() doesn't block them.
var net_scene_override: bool = false


func _ready() -> void:
	load_prefs()


func load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_FILE):
		return
	var f := FileAccess.open(PREFS_FILE, FileAccess.READ)
	if not f:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		active_slot_id = (parsed as Dictionary).get("last_slot_id", "clean")


func save_prefs() -> void:
	DirAccess.make_dir_recursive_absolute("user://scenes")
	var f := FileAccess.open(PREFS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"last_slot_id": active_slot_id}))


func set_active_slot(slot_id: String) -> void:
	active_slot_id = slot_id
	save_prefs()
	active_slot_changed.emit(slot_id)


func is_passthrough_supported() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null:
		return false
	return XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in xr.get_supported_environment_blend_modes()


func change_scene(scene_id: String) -> void:
	if scene_id == current_scene_id:
		return
	if not SCENE_PATHS.has(scene_id):
		push_error("SceneManager: unknown scene_id '%s'" % scene_id)
		return
	if scene_id == "passthrough" and not is_passthrough_supported():
		push_warning("SceneManager: passthrough not supported on this device")
		return

	# In a session only the host decides scenes; clients follow via the network.
	var net_client: bool = has_node("/root/NetworkManager") and NetworkManager.is_client()
	if net_client and not net_scene_override:
		push_warning("SceneManager: only the host can change scenes during a session")
		return

	# Auto-save arcade state before leaving (skip if clean slot — it's readonly;
	# skip on clients — the shared world is the host's, not ours to save).
	if current_scene_id == "arcade" and auto_save_on_switch and active_slot_id != "clean" \
			and not net_client:
		var persistence := ScenePersistence.new()
		persistence.save_slot(get_tree().current_scene, active_slot_id)

	current_scene_id = scene_id
	get_tree().change_scene_to_file(SCENE_PATHS[scene_id])
	scene_changed.emit(scene_id)
