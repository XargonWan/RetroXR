## NetworkManager — LAN multiplayer session core (autoload).
##
## Star topology over ENet: the host is the server (peer 1) and relays
## everything. Clients register with a handshake, follow the host's scene, and
## exchange avatar poses at 20 Hz. Object sync (M2), file transfer (M3) and
## netplay (M4) hang off this node as fixed-path children so RPC node paths
## match on every peer.
##
## Testability: all networking goes through `self.multiplayer` (never the tree
## global) and the world root is injectable, so probes can instantiate two
## copies of this script under sibling branches with per-branch
## SceneMultiplayer APIs (get_tree().set_multiplayer(api, branch_path)).
extends Node

const DEFAULT_PORT := 42777
const MAX_PLAYERS := 8
const PROTOCOL_VERSION := 1
const POSE_INTERVAL := 1.0 / 20.0

# ENet channels
const CH_CONTROL := 0   # reliable: handshake, spawns, events, netplay control
const CH_POSE := 1      # unreliable_ordered: avatar poses, object transforms
const CH_NPINPUT := 2   # unreliable: netplay per-frame inputs (self-redundant)
const CH_FILE := 3      # reliable: file/state chunks

const AVATAR_SCENE := preload("res://Scenes/Net/remote_avatar.tscn")
const POSE_BROADCASTER := preload("res://Scripts/Net/pose_broadcaster.gd")

## Avatar palette — color_idx assigned by the host at registration.
const PLAYER_COLORS: Array[Color] = [
	Color(0.90, 0.25, 0.25), Color(0.25, 0.55, 0.95), Color(0.30, 0.85, 0.35),
	Color(0.95, 0.80, 0.20), Color(0.80, 0.35, 0.90), Color(0.25, 0.85, 0.85),
	Color(0.95, 0.55, 0.20), Color(0.90, 0.90, 0.95),
]

signal session_started(is_host: bool)
signal session_ended(reason: String)
signal peer_registered(id: int, info: Dictionary)
signal peer_left(id: int)
signal status_changed(text: String)

## Peer roster: peer_id -> {name: String, is_vr: bool, color_idx: int}
var peers: Dictionary = {}

## Local display name (set from the NET menu / --net-name).
var player_name: String = "Player"

## Injectable world root (defaults to get_tree().current_scene). Probes set this.
var world_root: Node = null

## Injectable pose source returning PackedFloat32Array(21):
## head pos+quat, left pos+quat, right pos+quat. Defaults to a PoseBroadcaster
## attached to the player rig; probes inject a lambda.
var pose_source: Callable = Callable()

var _active := false
var _accepted := false           # handshake complete (host: immediately)
var _signals_wired := false
var _pose_accum := 0.0
var _latest_poses: Dictionary = {}     # peer_id -> PackedFloat32Array(21)
var _avatars_container: Node3D = null
var _avatars: Dictionary = {}          # peer_id -> RemoteAvatar
var _broadcaster: Node = null


func _ready() -> void:
	# React to host-driven scene switches (rebuild avatars in the new scene).
	if has_node("/root/SceneManager"):
		SceneManager.scene_changed.connect(_on_scene_changed)
	call_deferred("_parse_cmdline")


func _parse_cmdline() -> void:
	var args := OS.get_cmdline_user_args()
	var do_host := false
	var join_ip := ""
	for arg: String in args:
		if arg == "--net-host":
			do_host = true
		elif arg.begins_with("--net-join="):
			join_ip = arg.trim_prefix("--net-join=")
		elif arg.begins_with("--net-name="):
			player_name = arg.trim_prefix("--net-name=")
	if do_host:
		host_game()
	elif not join_ip.is_empty():
		join_game(join_ip)


# ── Public API ────────────────────────────────────────────────────────────────

func is_active() -> bool:
	return _active


func is_host() -> bool:
	return _active and multiplayer.is_server()


func is_client() -> bool:
	return _active and not multiplayer.is_server()


func host_game(port := DEFAULT_PORT) -> Error:
	if _active:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		status_changed.emit("Failed to host (port %d): %s" % [port, error_string(err)])
		return err
	_wire_signals()
	multiplayer.multiplayer_peer = peer
	_active = true
	_accepted = true
	peers = {1: _local_info(0)}
	_setup_world()
	status_changed.emit("Hosting on port %d — %s" % [port, ", ".join(local_ips())])
	session_started.emit(true)
	return OK


func join_game(ip: String, port := DEFAULT_PORT) -> Error:
	if _active:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		status_changed.emit("Failed to connect: %s" % error_string(err))
		return err
	_wire_signals()
	multiplayer.multiplayer_peer = peer
	_active = true
	_accepted = false
	peers = {}
	status_changed.emit("Connecting to %s…" % ip)
	return OK


func leave_session(reason := "left session") -> void:
	if not _active:
		return
	_active = false
	_accepted = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peers.clear()
	_latest_poses.clear()
	_teardown_world()
	status_changed.emit("Not connected")
	session_ended.emit(reason)


## Local LAN IPv4 addresses (for the host UI).
func local_ips() -> Array[String]:
	var out: Array[String] = []
	for ip: String in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") \
				or (ip.begins_with("172.") and int(ip.split(".")[1]) >= 16 and int(ip.split(".")[1]) <= 31):
			out.append(ip)
	return out


# ── Connection lifecycle ──────────────────────────────────────────────────────

func _wire_signals() -> void:
	if _signals_wired:
		return
	_signals_wired = true
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func(): leave_session("connection failed"))
	multiplayer.server_disconnected.connect(func(): leave_session("host disconnected"))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _on_connected_to_server() -> void:
	_register.rpc_id(1, {"name": player_name, "is_vr": get_viewport().use_xr}, PROTOCOL_VERSION)


func _on_peer_disconnected(id: int) -> void:
	if not _active:
		return
	if is_host() and peers.has(id):
		peers.erase(id)
		_latest_poses.erase(id)
		_remove_avatar(id)
		_peer_left_msg.rpc(id)
		peer_left.emit(id)
		status_changed.emit("%d player(s) connected" % peers.size())


func _local_info(color_idx: int) -> Dictionary:
	return {"name": player_name, "is_vr": get_viewport().use_xr, "color_idx": color_idx}


func _next_color_idx() -> int:
	var used := {}
	for id: int in peers:
		used[int(peers[id].get("color_idx", 0))] = true
	for i in PLAYER_COLORS.size():
		if not used.has(i):
			return i
	return peers.size() % PLAYER_COLORS.size()


# ── Handshake RPCs ────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _register(info: Dictionary, version: int) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		_reject.rpc_id(sender, "version mismatch (host %d, you %d)" % [PROTOCOL_VERSION, version])
		return
	if peers.size() >= MAX_PLAYERS:
		_reject.rpc_id(sender, "server full")
		return
	var entry := {
		"name": str(info.get("name", "Player")).left(24),
		"is_vr": bool(info.get("is_vr", false)),
		"color_idx": _next_color_idx(),
	}
	peers[sender] = entry
	var scene_id: String = SceneManager.current_scene_id if has_node("/root/SceneManager") else ""
	_accept.rpc_id(sender, peers.duplicate(true), scene_id)
	for id: int in peers:
		if id != 1 and id != sender:
			_peer_joined_msg.rpc_id(id, sender, entry)
	_add_avatar(sender, entry)
	peer_registered.emit(sender, entry)
	status_changed.emit("%d player(s) connected" % peers.size())


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _accept(roster: Dictionary, scene_id: String) -> void:
	peers = roster
	_accepted = true
	if has_node("/root/SceneManager") and not scene_id.is_empty() \
			and scene_id != SceneManager.current_scene_id:
		# Follow the host's scene; avatars are rebuilt on scene_changed.
		SceneManager.change_scene(scene_id)
	else:
		_setup_world()
	status_changed.emit("Connected — %d player(s)" % peers.size())
	session_started.emit(false)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _reject(reason: String) -> void:
	leave_session("rejected: %s" % reason)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _peer_joined_msg(id: int, info: Dictionary) -> void:
	peers[id] = info
	_add_avatar(id, info)
	peer_registered.emit(id, info)
	status_changed.emit("Connected — %d player(s)" % peers.size())


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _peer_left_msg(id: int) -> void:
	peers.erase(id)
	_remove_avatar(id)
	peer_left.emit(id)
	status_changed.emit("Connected — %d player(s)" % peers.size())


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _scene_change(scene_id: String) -> void:
	if has_node("/root/SceneManager"):
		SceneManager.change_scene(scene_id)


# ── Pose sync ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _active or not _accepted:
		return
	_pose_accum += delta
	if _pose_accum < POSE_INTERVAL:
		return
	_pose_accum = 0.0

	var pose := _sample_local_pose()
	if is_host():
		if not pose.is_empty():
			_latest_poses[1] = pose
		if not _latest_poses.is_empty():
			_pose_broadcast.rpc(_latest_poses)
			_apply_poses(_latest_poses)
	else:
		if not pose.is_empty():
			_pose_report.rpc_id(1, pose)


func _sample_local_pose() -> PackedFloat32Array:
	if pose_source.is_valid():
		return pose_source.call()
	if is_instance_valid(_broadcaster):
		return _broadcaster.sample()
	return PackedFloat32Array()


@rpc("any_peer", "call_remote", "unreliable_ordered", CH_POSE)
func _pose_report(pose: PackedFloat32Array) -> void:
	if not is_host() or pose.size() != 21:
		return
	var sender := multiplayer.get_remote_sender_id()
	if peers.has(sender):
		_latest_poses[sender] = pose


@rpc("authority", "call_remote", "unreliable_ordered", CH_POSE)
func _pose_broadcast(poses: Dictionary) -> void:
	_apply_poses(poses)


func _apply_poses(poses: Dictionary) -> void:
	var self_id := multiplayer.get_unique_id()
	for id: Variant in poses:
		var pid := int(id)
		if pid == self_id:
			continue
		var avatar: Node = _avatars.get(pid)
		if is_instance_valid(avatar):
			avatar.push_pose(poses[id])


# ── World / avatars ───────────────────────────────────────────────────────────

func _resolve_world_root() -> Node:
	if world_root != null and is_instance_valid(world_root):
		return world_root
	return get_tree().current_scene


func _setup_world() -> void:
	_teardown_world()
	var root := _resolve_world_root()
	if root == null:
		return
	_avatars_container = Node3D.new()
	_avatars_container.name = "NetAvatars"
	root.add_child(_avatars_container)
	var self_id := multiplayer.get_unique_id()
	for id: int in peers:
		if id != self_id:
			_add_avatar(id, peers[id])
	_attach_broadcaster()


func _teardown_world() -> void:
	for id: int in _avatars.keys():
		_remove_avatar(id)
	_avatars.clear()
	if is_instance_valid(_avatars_container):
		_avatars_container.queue_free()
	_avatars_container = null
	if is_instance_valid(_broadcaster):
		_broadcaster.queue_free()
	_broadcaster = null


func _add_avatar(id: int, info: Dictionary) -> void:
	if not is_instance_valid(_avatars_container) or _avatars.has(id):
		return
	var avatar := AVATAR_SCENE.instantiate()
	avatar.name = "Avatar_%d" % id
	_avatars_container.add_child(avatar)
	avatar.setup(str(info.get("name", "?")),
		PLAYER_COLORS[int(info.get("color_idx", 0)) % PLAYER_COLORS.size()],
		bool(info.get("is_vr", false)))
	_avatars[id] = avatar


func _remove_avatar(id: int) -> void:
	var avatar: Node = _avatars.get(id)
	if is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(id)


## Attach a pose broadcaster next to the player rig's camera (skipped when no
## rig exists, e.g. in probes, which inject pose_source instead).
func _attach_broadcaster() -> void:
	if pose_source.is_valid():
		return
	var cams := get_tree().root.find_children("*", "XRCamera3D", true, false)
	if cams.is_empty():
		return
	var cam := cams[0] as XRCamera3D
	_broadcaster = POSE_BROADCASTER.new()
	_broadcaster.name = "NetPoseBroadcaster"
	cam.get_parent().add_child(_broadcaster)


func _on_scene_changed(scene_id: String) -> void:
	if not _active or not _accepted:
		return
	# Host propagates the switch; everyone rebuilds avatars in the new scene.
	if is_host():
		_scene_change.rpc(scene_id)
	world_root = null
	call_deferred("_setup_world")
