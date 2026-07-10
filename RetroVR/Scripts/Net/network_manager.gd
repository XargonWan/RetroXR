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
const OBJECT_SYNC := preload("res://Scripts/Net/object_sync.gd")
const NETPLAY := preload("res://Scripts/Net/netplay_session.gd")
const FILE_TRANSFER := preload("res://Scripts/Net/file_transfer.gd")

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
var _object_sync: NetObjectSync = null
var _netplay: NetplaySession = null
var _file_transfer: NetFileTransfer = null
var _pose_accum := 0.0
var _latest_poses: Dictionary = {}     # peer_id -> PackedFloat32Array(21)
var _avatars_container: Node3D = null
var _avatars: Dictionary = {}          # peer_id -> RemoteAvatar
var _broadcaster: Node = null


func _ready() -> void:
	# Fixed-path RPC child — must exist on every peer before any session RPC.
	_object_sync = OBJECT_SYNC.new()
	_object_sync.name = "ObjectSync"
	add_child(_object_sync)
	# Fixed-path netplay session (M4) — one active game at a time.
	_netplay = NETPLAY.new()
	_netplay.name = "Netplay"
	add_child(_netplay)
	# Fixed-path file delivery (M3) — books/videos by content hash.
	_file_transfer = FILE_TRANSFER.new()
	_file_transfer.name = "FileTransfer"
	add_child(_file_transfer)
	# React to host-driven scene switches (rebuild avatars in the new scene).
	if has_node("/root/SceneManager"):
		SceneManager.scene_changed.connect(_on_scene_changed)
	call_deferred("_parse_cmdline")


func _parse_cmdline() -> void:
	# On-device QA hook: a user://spike.cfg boots straight into the netplay
	# determinism spike (used to vet cores over adb on Quest, where there are
	# no command-line args). The spike deletes the cfg so the next launch is
	# normal even if the run crashes mid-way. NB: ResourceLoader.exists, not
	# FileAccess — .tscn paths are remapped inside exported pcks.
	if FileAccess.file_exists("user://spike.cfg") \
			and ResourceLoader.exists("res://Tools/netplay_spike.tscn"):
		print("[NetworkManager] spike.cfg found — launching netplay spike")
		get_tree().change_scene_to_file("res://Tools/netplay_spike.tscn")
		return
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
	return _active and multiplayer != null and multiplayer.is_server()


func is_client() -> bool:
	return _active and multiplayer != null and not multiplayer.is_server()


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
	if _netplay != null:
		_netplay.stop("session ended")
	_file_transfer.end_session()
	_object_sync.end_session()
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


# ── Object-sync facade (hooks in world objects call these) ────────────────────

## Forward a state-transition event to the shared world (no-op offline).
func report_event(kind: int, args: Dictionary) -> void:
	if _active and _object_sync != null:
		_object_sync.report_event(kind, args)


## True while remote state is being applied locally (hooks must not re-report).
func is_event_applying() -> bool:
	return _object_sync != null and _object_sync.is_applying()


## Called by the spawn flow when a new object was placed while in a session.
func on_local_spawn(obj: Node3D) -> void:
	if _active and _object_sync != null:
		_object_sync.local_spawn(obj)


## Host VCR transport changed — broadcast the new state for drift sync (M5).
func report_vcr_state(vcr: Node) -> void:
	if _active and _object_sync != null:
		_object_sync.send_vcr_state(vcr)


# ── Netplay facade (M4) ───────────────────────────────────────────────────────

## True if the core is determinism-verified for lockstep netplay.
func netplay_capable(core_name: String) -> bool:
	return NetplayCores.is_capable(core_name)


## True while a netplay game is running.
func netplay_running() -> bool:
	return _netplay != null and _netplay.is_running()


## The system currently under netplay, or null.
func netplay_system() -> Object:
	return _netplay._system if _netplay != null else null


## Host: begin netplay for `system`. `owners` maps port -> peer_id (defaults to
## a sensible assignment across connected peers). rollback: -1 auto (core
## capability), 0 force lockstep, 1 force rollback. Returns false if not host,
## core not verified, or already running.
func netplay_start_host(system: Object, core: String, rom_md5: String,
		owners: Dictionary = {}, delay := 3, rollback := -1) -> bool:
	if _netplay == null or not is_host():
		return false
	if owners.is_empty():
		owners = default_owners(system)
	return _netplay.start_host(system, core, rom_md5, owners, delay, rollback)


## Assign participating ports to peers: port index i -> the i-th peer (host
## first). Only ports with a controller plugged in participate.
func default_owners(system: Object) -> Dictionary:
	var ids: Array = peers.keys()
	ids.sort()
	var owners := {}
	var plugged: Array = []
	if system != null and "_port_controllers" in system:
		var pc: Array = system.get("_port_controllers")
		for i in range(pc.size()):
			if pc[i] != null:
				plugged.append(i)
	if plugged.is_empty():
		plugged = [0]   # at least port 0 participates
	for i in range(plugged.size()):
		owners[plugged[i]] = ids[i % ids.size()]
	return owners


## Stop the active netplay game.
func netplay_stop(reason := "stopped") -> void:
	if _netplay != null:
		_netplay.stop(reason)


## Input seam: called from retro_controller. Returns true if netplay consumed
## the input (caller must not drive the core directly).
func netplay_route(system: Object, port: int, m: Dictionary) -> bool:
	return _netplay != null and _netplay.route(system, port, m)


## Host: a netplay-registered controller changed hands to `peer_id`. If it
## occupies a participating netplay port owned by someone else, hand that port
## (and thus who drives it) to the new holder. No-op off-session / non-host.
func netplay_handoff(controller: Object, peer_id: int) -> void:
	if _netplay != null:
		_netplay.handoff_controller(controller, peer_id)


## Host: frame-schedule a disc eject/swap for the running netplay game so
## every peer's core applies it on the same frame. op 0 = eject, op 1 =
## replace image `index` with the disc whose md5 matches (resolved locally
## on each peer — disc files are never transferred).
func netplay_schedule_disk(system: Object, op: int, md5: String, index: int) -> void:
	if _netplay != null:
		_netplay.schedule_disk_op(system, op, md5, index)


## Aux input feeds for the running netplay game (port-0 owner only): tilt
## sensor in milli-g and touch pointer. Both ride the deterministic frame
## schedule so every peer's core sees identical values on identical frames.
func netplay_set_aux_sensor(system: Object, x_mg: int, y_mg: int, z_mg: int) -> void:
	if _netplay != null:
		_netplay.set_aux_sensor(system, x_mg, y_mg, z_mg)


func netplay_set_aux_pointer(system: Object, px: int, py: int, pressed: bool) -> void:
	if _netplay != null:
		_netplay.set_aux_pointer(system, px, py, pressed)


## Queue a keyboard transition into the running netplay game's deterministic
## schedule. Returns true when netplay consumed it (caller must NOT feed the
## core directly).
func netplay_queue_key(system: Object, keycode: int, down: bool, character: int) -> bool:
	return _netplay != null and _netplay.queue_key_event(system, keycode, down, character)


## Round-trip time in ms to peer `id` as known locally, or -1 when unknown.
## The host knows every client's RTT; a client only knows its RTT to the host.
func ping_ms(id: int) -> int:
	if not _active or multiplayer == null:
		return -1
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return -1
	var self_id := multiplayer.get_unique_id()
	if id == self_id:
		return 0
	var target := id if is_host() else 1
	if not is_host() and id != 1:
		return -1   # client can't see client<->client RTT
	var p: ENetPacketPeer = peer.get_peer(target)
	if p == null:
		return -1
	return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))


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
		# A departed peer that owned a netplay port would stall the assembler
		# forever — end the game for everyone.
		if _netplay != null and _netplay.is_active():
			_netplay.on_peer_left(id)


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
	# A peer joining mid-game gets caught up via the netplay savestate flow.
	if _netplay != null and _netplay.is_running():
		_netplay.on_peer_joined(sender)


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
		SceneManager.net_scene_override = true
		SceneManager.change_scene(scene_id)
		SceneManager.net_scene_override = false


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
	_object_sync.on_world_ready()


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
	_object_sync.reset_for_scene_change()
	world_root = null
	call_deferred("_setup_world")
