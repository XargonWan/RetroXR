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
## Every room instances res://Scenes/player_rig.tscn under this name.
const PLAYER_RIG_NAME := "PlayerRig"

var current_scene_id: String = "arcade"
var auto_save_on_switch: bool = true
var active_slot_id: String = "clean"

## Set by NetworkManager around host-driven scene switches so the client
## guard in change_scene() doesn't block them.
var net_scene_override: bool = false

var _transitioning: bool = false


func _ready() -> void:
	_warm_models.call_deferred()
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
##
## The player's rig is carried across rather than rebuilt. Building one costs
## ~380 ms of blocked main thread on a desktop — most of it the spawn menu's
## viewport UI — and several times that on a Quest, and it is spent inside the
## single add_child() that brings the new room in, with no frame drawn until it
## returns. In VR a blocked main thread is a frozen headset: the compositor
## re-projects the last frame it was handed, which is the loading screen. So the
## rig steps out of the old room, waits on the root, and is spliced into the new
## one before it enters the tree. The viewport also never loses its camera that
## way, so nothing has to hand XR tracking over mid-swap.
func _run_transition(path: String, title: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	var tree := get_tree()

	# All of this runs in one deferred call: the room leaves and the loading
	# screen arrives without a frame drawn in between.
	var outgoing := tree.current_scene
	var player := _take_player_rig(outgoing)
	if outgoing != null:
		tree.current_scene = null
		tree.root.remove_child(outgoing)
		outgoing.queue_free()

	var rig: LoadingRig = LOADING_RIG_SCENE.instantiate()
	rig.prepare_for_player(player)
	tree.root.add_child(rig)
	rig.set_title("LOADING  %s" % title if not title.is_empty() else "LOADING")

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
			# Nothing to go back to — the old room is already gone. Leave the
			# player parked on the root: they keep head tracking and the menu
			# (a child of the rig) still works, so another room can be picked.
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
	if player != null:
		_seat_player_rig(incoming, player)
	# The rig has to be out of the tree BEFORE the incoming scene enters, not just
	# switched off. Its WorldEnvironment would otherwise be the one the new room
	# has to displace, and in the no-player fallback its camera holds the viewport:
	# a Camera3D claims the viewport on entry only while none is registered at all,
	# so a rig camera still sitting there — even with current = false — leaves the
	# new scene's XRCamera3D unclaimed and the view grey.
	tree.root.remove_child(rig)
	rig.queue_free()
	tree.root.add_child(incoming)
	tree.current_scene = incoming
	if player != null:
		_settle_player_rig(player)
	_transitioning = false


## Detach the player's rig from the outgoing room and park it on the root so it
## survives the teardown. Null if the room has no rig — a probe scene, or one
## that never had one — in which case the loading rig brings its own camera.
func _take_player_rig(outgoing: Node) -> Node3D:
	if outgoing == null:
		return null
	var player := outgoing.get_node_or_null(PLAYER_RIG_NAME) as Node3D
	if player == null:
		return null
	# Whatever is in the player's hands belongs to the room about to be freed.
	for node: Node in player.find_children("*", "XRToolsFunctionPickup", true, false):
		var pickup := node as XRToolsFunctionPickup
		if pickup.picked_up_object != null:
			pickup.drop_object()
	outgoing.remove_child(player)
	get_tree().root.add_child(player)
	_set_player_body_enabled(player, false)
	return player


## Splice the carried rig into the incoming room in place of the one the room
## authored, before any of it enters the tree — so the room's own rig never runs
## a single _ready().
func _seat_player_rig(incoming: Node, player: Node3D) -> void:
	var index := -1
	var authored := incoming.get_node_or_null(PLAYER_RIG_NAME) as Node3D
	if authored != null:
		index = authored.get_index()
		player.transform = authored.transform
		# Locomotion walks the origin, not the rig root, so the origin has to go
		# back to the value the room's own rig was authored with. Otherwise the
		# player arrives at the new spawn point plus wherever they wandered in
		# the last room.
		var authored_origin := _find_origin(authored)
		var origin := _find_origin(player)
		if authored_origin != null and origin != null:
			origin.transform = authored_origin.transform
		incoming.remove_child(authored)
		authored.free()
	player.get_parent().remove_child(player)
	incoming.add_child(player)
	if index >= 0:
		incoming.move_child(player, index)


## Re-apply the rig settings that depend on which room we are in. Runs once the
## incoming scene is the current one, because the arcade's slot auto-load builds
## into it and the player body needs a floor to stand on.
func _settle_player_rig(player: Node3D) -> void:
	_set_player_body_enabled(player, true)
	var menu := player.get_node_or_null("SpawnMenuController")
	if menu != null and menu.has_method("refresh_for_scene"):
		menu.refresh_for_scene()


## The floor is freed with the room, and the rig now outlives it. Left running,
## the player body spends the whole crossing in free fall — you watch the loading
## screen rise past you — and then arrives in the new room carrying a second of
## downward velocity, which puts you straight through its floor. So the body is
## switched off for the crossing and switched back on once there is ground again.
func _set_player_body_enabled(player: Node3D, value: bool) -> void:
	var found := player.find_children("*", "XRToolsPlayerBody", true, false)
	if found.is_empty():
		return
	var body := found[0] as XRToolsPlayerBody
	if value:
		body.velocity = Vector3.ZERO
		body.ground_velocity = Vector3.ZERO
	body.enabled = value


func _find_origin(player: Node3D) -> Node3D:
	var found := player.find_children("*", "XROrigin3D", true, false)
	return found[0] as Node3D if not found.is_empty() else null


## Pay every stand-in model's first-spawn cost once, at startup, instead of the
## first time a player reaches for one. Measured on a Quest 3: 0.88 s for all
## thirteen, against 3.9 s for a single cold spawn of the 3DS stand-in alone.
## See ModelWarmer for why only the stand-ins.
##
## Deferred past the first frames so the room is up and drawing first: the warm
## blocks the main thread in ~85 ms slices, which is invisible while the view is
## still black or the loading rig is up, and would be a stutter mid-play.
func _warm_models() -> void:
	for i in 4:
		await get_tree().process_frame
	await ModelWarmer.warm_stand_ins(self)
