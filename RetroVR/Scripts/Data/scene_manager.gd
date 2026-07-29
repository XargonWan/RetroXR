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
	"bedroom":     "res://Scenes/BedroomScene.tscn",
	"passthrough": "res://Scenes/PassthroughScene.tscn",
	"test":        "res://Scenes/TestScene.tscn",
}
## Shown on the loading screen while each scene builds.
const SCENE_TITLES := {
	"arcade":      "ARCADE ROOM",
	"den":         "COZY DEN",
	"bedroom":     "90s BEDROOM",
	"passthrough": "PASSTHROUGH",
	"test":        "TEST HALLWAY",
}
const PREFS_FILE := "user://scenes/prefs.json"
const LOADING_RIG_SCENE := preload("res://Scenes/UI/loading_rig.tscn")

var current_scene_id: String = "arcade"
var auto_save_on_switch: bool = true
var active_slot_id: String = "clean"

## Set by NetworkManager around host-driven scene switches so the client
## guard in change_scene() doesn't block them.
var net_scene_override: bool = false

var _transitioning: bool = false


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
	# Deferred: the call arrives from a button inside the scene about to be freed,
	# so the caller's stack has to unwind first.
	_run_transition.call_deferred(SCENE_PATHS[scene_id], SCENE_TITLES.get(scene_id, ""))
	scene_changed.emit(scene_id)


## Swap scenes with a loading screen, freeing the outgoing scene BEFORE the
## incoming one is built.
##
## SceneTree.change_scene_to_file() instantiates the new scene while the old one
## is still live, so for one frame both worlds' nodes and every resource they
## reference are resident at once. Going from the arcade into a heavy room that
## way peaks at the sum of both, which is what the Quest cannot afford. Tearing
## down first costs a black gap, which is what the loading rig is for.
func _run_transition(path: String, title: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	var tree := get_tree()

	# Up first, so the headset keeps a tracked camera and something to look at.
	var rig: LoadingRig = LOADING_RIG_SCENE.instantiate()
	tree.root.add_child(rig)
	rig.set_title("LOADING  %s" % title if not title.is_empty() else "LOADING")
	await tree.process_frame

	var outgoing := tree.current_scene
	if outgoing != null:
		tree.current_scene = null
		tree.root.remove_child(outgoing)
		outgoing.queue_free()
	# Two frames: one for queue_free to run, one for the freed resources to drop
	# out of the cache before the next scene starts pulling its own in.
	await tree.process_frame
	await tree.process_frame

	ResourceLoader.load_threaded_request(path)
	var progress: Array = []
	while true:
		var status := ResourceLoader.load_threaded_get_status(path, progress)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			break
		if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			push_error("SceneManager: failed to load '%s' (status %d)" % [path, status])
			rig.queue_free()
			_transitioning = false
			return
		if not progress.is_empty():
			rig.set_progress(float(progress[0]))
		await tree.process_frame
	rig.set_progress(1.0)

	var packed: PackedScene = ResourceLoader.load_threaded_get(path)
	var incoming: Node = packed.instantiate()
	# The rig has to be out of the tree BEFORE the incoming scene enters, not just
	# switched off. A Camera3D claims the viewport on entry only while the viewport
	# has no camera registered at all, so a rig camera still sitting there — even
	# with current = false — leaves the new scene's XRCamera3D unclaimed and the
	# view grey. Leaving the tree also releases the XROrigin3D, of which only one
	# may be current, and the rig's WorldEnvironment.
	tree.root.remove_child(rig)
	rig.queue_free()
	tree.root.add_child(incoming)
	tree.current_scene = incoming
	_transitioning = false
