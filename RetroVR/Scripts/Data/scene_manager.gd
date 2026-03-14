## SceneManager — Autoload that tracks the active scene and handles transitions.
##
## Coordinates with ScenePersistence to auto-save arcade state when switching
## scenes (if auto_save_on_switch is enabled).
extends Node


signal scene_changed(scene_id: String)

const SCENE_PATHS := {
	"arcade":      "res://Scenes/MainScene.tscn",
	"passthrough": "res://Scenes/PassthroughScene.tscn",
}

var current_scene_id: String = "arcade"
var auto_save_on_switch: bool = true


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

	# Auto-save arcade state before leaving
	if current_scene_id == "arcade" and auto_save_on_switch:
		var persistence := ScenePersistence.new()
		persistence.save_scene(get_tree().current_scene)

	current_scene_id = scene_id
	get_tree().change_scene_to_file(SCENE_PATHS[scene_id])
	scene_changed.emit(scene_id)
