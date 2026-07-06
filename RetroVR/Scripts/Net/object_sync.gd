## NetObjectSync — host-authoritative shared-world sync (multiplayer M2).
##
## Fixed-path child of NetworkManager ("ObjectSync") so RPC node paths match on
## every peer. The wire format for objects is ScenePersistence's serializer
## (dict entries + two-pass restore), keyed by host-allocated net_ids stored in
## each object's "net_id" meta.
##
## Model:
## - Host owns the world. Clients get a full snapshot on join, then incremental
##   spawn/despawn/event messages and 15 Hz transform batches.
## - Client replicas are frozen (kinematic). Grabbing one grants the client
##   authority (host arbitration); the owner streams the held pose at 20 Hz and
##   returns authority (with velocities) on release.
## - Discrete state changes (cartridge/tape insert, cable plug, ports, power,
##   TV controls, VCR transport) are replicated as events applied through the
##   existing restore_*/remote_* APIs; the originator suppresses re-apply.
##
## All group("spawned") queries are scoped to world_root descendants so two
## peers can share one process in probes.
class_name NetObjectSync
extends Node

const XFORM_INTERVAL := 1.0 / 15.0
const HELD_INTERVAL := 1.0 / 20.0
const SNAP_DISTANCE := 1.0    # replica teleport threshold (metres)

# Replicated event kinds.
enum {
	EV_CART_INSERT,      # {sys, cart}
	EV_CART_REMOVE,      # {sys}
	EV_TAPE_INSERT,      # {vcr, tape}
	EV_TAPE_REMOVE,      # {vcr}
	EV_TV_PLUG,          # {owner, tv}   owner = system or VCR
	EV_TV_UNPLUG,        # {tv}
	EV_PORT_PLUG,        # {sys, ctrl, port}
	EV_PORT_UNPLUG,      # {sys, port}
	EV_SYS_POWER,        # {sys}         client intent -> host toggles
	EV_SYS_POWER_STATE,  # {sys, on}     host -> clients (placeholder screens)
	EV_TV_POWER,         # {tv}
	EV_TV_VOL_UP,        # {tv}
	EV_TV_VOL_DOWN,      # {tv}
	EV_TV_CRT,           # {tv, on}
	EV_VCR_CMD,          # {vcr, cmd}    client intent -> host transport
}

var _nm: Node = null
var _persistence: ScenePersistence = ScenePersistence.new()
var _next_net_id := 1
var _registry: Dictionary = {}       # net_id -> Node3D
var _held_by_me: Dictionary = {}     # net_id -> true (this peer owns the grab)
var _remote_held: Dictionary = {}    # net_id -> peer_id (host bookkeeping)
var _xform_targets: Dictionary = {}  # net_id -> [Vector3, Quaternion] (client lerp)
var _applying := false               # applying remote state — suppress echo
var _xform_accum := 0.0
var _held_accum := 0.0


func _ready() -> void:
	_nm = get_parent()


func is_applying() -> bool:
	return _applying


func id_of(node: Node) -> int:
	return node.get_meta("net_id", -1) if is_instance_valid(node) else -1


## Reverse lookup: the registered node for a net_id, or null.
func node_for_id(net_id: int) -> Node:
	var node: Node = _registry.get(net_id)
	return node if is_instance_valid(node) else null


# ── Session lifecycle (called by NetworkManager) ──────────────────────────────

## Called whenever the world is (re)ready: session start and after scene changes.
func on_world_ready() -> void:
	_applying = false
	if _nm.is_host():
		_register_existing()
	elif _nm.is_client():
		_request_snapshot.rpc_id(1)


func reset_for_scene_change() -> void:
	# Scene teardown frees everything — suppress despawn/echo storms.
	_applying = true
	_registry.clear()
	_held_by_me.clear()
	_remote_held.clear()
	_xform_targets.clear()


func end_session() -> void:
	# Leave the world usable offline: unfreeze replicas that aren't snapped.
	for id: int in _registry:
		var node: Node = _registry[id]
		if is_instance_valid(node) and node is RigidBody3D and not _is_zone_snapped(node) \
				and not _is_hand_held(node):
			(node as RigidBody3D).freeze = false
	reset_for_scene_change()
	_applying = false


## Called by _place_spawned while in a session.
func local_spawn(obj: Node3D) -> void:
	if _applying:
		return
	if _nm.is_host():
		if _register_host(obj):
			_broadcast_spawn(obj)
	elif _nm.is_client():
		# Serialize the intent, discard the local copy, let the host mint it.
		# Placeholder id 0 so instantiate_objects doesn't skip the entry; the
		# host assigns the real net_id on registration.
		var entry := _persistence._serialize_node(obj, 0, {})
		obj.queue_free()
		if not entry.is_empty():
			_request_spawn.rpc_id(1, entry)


# ── Registration ──────────────────────────────────────────────────────────────

func _register_existing() -> void:
	var root: Node = _nm._resolve_world_root()
	if root == null:
		return
	for node: Node in get_tree().get_nodes_in_group("spawned"):
		if root.is_ancestor_of(node):
			_register_host(node)


## Host-side: assign a net_id if the object is a syncable type. Returns true
## if registered (cables and other side-effect nodes serialize empty -> skip).
func _register_host(node: Node) -> bool:
	if node.has_meta("net_id"):
		return true
	if _persistence._serialize_node(node, 0, {}).is_empty():
		return false
	var id := _next_net_id
	_next_net_id += 1
	_bind(node, id)
	return true


func _register_client(node: Node, id: int) -> void:
	_bind(node, id)
	_freeze_replica(node)


func _bind(node: Node, id: int) -> void:
	node.set_meta("net_id", id)
	_registry[id] = node
	if node.has_signal("grabbed"):
		node.connect("grabbed", _on_grabbed)
	if node.has_signal("dropped"):
		node.connect("dropped", _on_dropped)
	node.tree_exiting.connect(_on_node_exiting.bind(id))


func _freeze_replica(node: Node) -> void:
	if node is RigidBody3D:
		var body := node as RigidBody3D
		body.freeze = true


func _serialize_registry_entry(node: Node) -> Dictionary:
	var node_to_id := {}
	for id: int in _registry:
		node_to_id[_registry[id]] = id
	var entry := _persistence._serialize_node(node, id_of(node), node_to_id)
	if not entry.is_empty():
		_augment_file_fields(node, entry)
	return entry


func _broadcast_spawn(node: Node) -> void:
	var entry := _serialize_registry_entry(node)
	if not entry.is_empty():
		_spawn_object.rpc(entry)


# ── Snapshot ──────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_snapshot() -> void:
	if not _nm.is_host():
		return
	_register_existing()
	var entries: Array = []
	var node_to_id := {}
	for id: int in _registry:
		node_to_id[_registry[id]] = id
	for id: int in _registry:
		var entry := _persistence._serialize_node(_registry[id], id, node_to_id)
		if not entry.is_empty():
			_augment_file_fields(_registry[id], entry)
			entries.append(entry)
	_world_snapshot.rpc_id(multiplayer.get_remote_sender_id(), entries)


@rpc("authority", "call_remote", "reliable", 0)
func _world_snapshot(entries: Array) -> void:
	var root: Node = _nm._resolve_world_root()
	if root == null:
		return
	_applying = true
	_clear_world(root)
	var spawned := _persistence.instantiate_objects(root, entries)
	for id: Variant in spawned:
		_register_client(spawned[id], int(id))
	for entry: Variant in entries:
		var node: Node = spawned.get(int((entry as Dictionary).get("id", -1)))
		if node != null:
			_resolve_file_fields(node, entry)
	_applying = false
	print("[NetObjectSync] snapshot applied: %d objects" % spawned.size())


## Scoped clear: only spawned objects under our world root (probe-safe).
func _clear_world(root: Node) -> void:
	var mine: Array = []
	for node: Node in get_tree().get_nodes_in_group("spawned"):
		if root.is_ancestor_of(node):
			mine.append(node)
	for node: Node in mine:
		for plug_name: String in ["CablePlug", "ControllerPlug"]:
			var plug := node.get_node_or_null(plug_name)
			if plug and plug.has_method("drop"):
				plug.call("drop")
	for node: Node in mine:
		if node is RetroSystem and (node as RetroSystem).is_powered_on:
			(node as RetroSystem).toggle_power()
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()


# ── Spawn / despawn ───────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_spawn(entry: Dictionary) -> void:
	if not _nm.is_host():
		return
	var root: Node = _nm._resolve_world_root()
	if root == null:
		return
	_applying = true
	var spawned := _persistence.instantiate_objects(root, [entry])
	_applying = false
	for id: Variant in spawned:
		var node: Node = spawned[id]
		if _register_host(node):
			_broadcast_spawn(node)
		else:
			node.queue_free()


@rpc("authority", "call_remote", "reliable", 0)
func _spawn_object(entry: Dictionary) -> void:
	var root: Node = _nm._resolve_world_root()
	if root == null:
		return
	_applying = true
	var spawned := _persistence.instantiate_objects(root, [entry])
	for id: Variant in spawned:
		_register_client(spawned[id], int(entry.get("id", -1)))
		_resolve_file_fields(spawned[id], entry)
	_applying = false


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_despawn(net_id: int) -> void:
	if not _nm.is_host():
		return
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		# tree_exiting hook broadcasts _despawn to the remaining clients.
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()


@rpc("authority", "call_remote", "reliable", 0)
func _despawn(net_id: int) -> void:
	var node: Node = _registry.get(net_id)
	_unregister(net_id)
	if is_instance_valid(node):
		_applying = true
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()
		_applying = false


func _on_node_exiting(net_id: int) -> void:
	if not _registry.has(net_id):
		return
	var was_applying := _applying
	_unregister(net_id)
	if was_applying or not _nm.is_active():
		return
	if _nm.is_host():
		_despawn.rpc(net_id)
	else:
		# A client freed a replica locally (e.g. trash can) — ask the host to
		# make it authoritative.
		_request_despawn.rpc_id(1, net_id)


func _unregister(net_id: int) -> void:
	_registry.erase(net_id)
	_held_by_me.erase(net_id)
	_remote_held.erase(net_id)
	_xform_targets.erase(net_id)


# ── Transform sync ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _nm.is_active():
		return
	if _nm.is_host():
		_xform_accum += delta
		if _xform_accum >= XFORM_INTERVAL:
			_xform_accum = 0.0
			_host_send_xforms()
	else:
		_client_lerp_targets(delta)
		_held_accum += delta
		if _held_accum >= HELD_INTERVAL:
			_held_accum = 0.0
			_client_send_held()


func _host_send_xforms() -> void:
	var buf := StreamPeerBuffer.new()
	var count := 0
	for id: int in _registry:
		var node: Node = _registry[id]
		if not is_instance_valid(node) or not node is RigidBody3D:
			continue
		if _is_zone_snapped(node):
			continue   # follows its carrier locally on every peer
		var body := node as RigidBody3D
		var include: bool = _remote_held.has(id) or _is_hand_held(node) or not body.sleeping
		if not include:
			continue
		buf.put_u32(id)
		var pos := body.global_position
		var quat := body.global_transform.basis.get_rotation_quaternion()
		buf.put_float(pos.x); buf.put_float(pos.y); buf.put_float(pos.z)
		buf.put_float(quat.x); buf.put_float(quat.y); buf.put_float(quat.z); buf.put_float(quat.w)
		count += 1
	if count > 0:
		_xform_batch.rpc(buf.data_array)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _xform_batch(bytes: PackedByteArray) -> void:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	while buf.get_position() + 32 <= buf.get_size():
		var id := buf.get_u32()
		var pos := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		var quat := Quaternion(buf.get_float(), buf.get_float(), buf.get_float(), buf.get_float())
		if _held_by_me.has(id):
			continue   # we're authoritative for this one right now
		if _registry.has(id):
			_xform_targets[id] = [pos, quat]


func _client_lerp_targets(delta: float) -> void:
	var w := clampf(delta * 12.0, 0.0, 1.0)
	for id: int in _xform_targets.keys():
		if _held_by_me.has(id):
			# We're the authority while holding — a stale host target must not
			# fight the local grab.
			_xform_targets.erase(id)
			continue
		var node: Node = _registry.get(id)
		if not is_instance_valid(node) or not node is Node3D:
			_xform_targets.erase(id)
			continue
		var n3d := node as Node3D
		var target: Array = _xform_targets[id]
		var tpos: Vector3 = target[0]
		var tquat: Quaternion = target[1]
		if n3d.global_position.distance_to(tpos) > SNAP_DISTANCE:
			n3d.global_position = tpos
			n3d.quaternion = tquat
			n3d.reset_physics_interpolation()
		else:
			n3d.global_position = n3d.global_position.lerp(tpos, w)
			n3d.quaternion = n3d.quaternion.slerp(tquat, w)


func _client_send_held() -> void:
	for id: int in _held_by_me:
		var node: Node = _registry.get(id)
		if not is_instance_valid(node) or not node is Node3D:
			continue
		var n3d := node as Node3D
		_held_pose.rpc_id(1, id, n3d.global_position,
			n3d.global_transform.basis.get_rotation_quaternion())


# ── Grab authority ────────────────────────────────────────────────────────────

func _on_grabbed(pickable: Node3D, by: Node3D) -> void:
	if _applying or not _nm.is_active() or by is XRToolsSnapZone:
		return
	var id := id_of(pickable)
	if id < 0:
		return
	if _nm.is_client() and not _held_by_me.has(id):
		_held_by_me[id] = true
		_xform_targets.erase(id)
		_request_grab.rpc_id(1, id)
	elif _nm.is_host():
		# Host grabbed it back — revoke any remote hold.
		_remote_held.erase(id)


func _on_dropped(pickable: Node3D) -> void:
	if _applying or not _nm.is_active():
		return
	var id := id_of(pickable)
	if id < 0 or not _held_by_me.has(id):
		return
	_held_by_me.erase(id)
	var lin := Vector3.ZERO
	var ang := Vector3.ZERO
	if pickable is RigidBody3D:
		lin = (pickable as RigidBody3D).linear_velocity
		ang = (pickable as RigidBody3D).angular_velocity
	_release.rpc_id(1, id, pickable.global_position,
		pickable.global_transform.basis.get_rotation_quaternion(), lin, ang)
	_freeze_replica(pickable)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_grab(net_id: int) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var node: Node = _registry.get(net_id)
	if not is_instance_valid(node):
		return
	if _remote_held.has(net_id) and int(_remote_held[net_id]) != sender:
		_grab_denied.rpc_id(sender, net_id)
		return
	if _is_hand_held(node):
		_grab_denied.rpc_id(sender, net_id)
		return
	_remote_held[net_id] = sender
	_freeze_replica(node)


@rpc("authority", "call_remote", "reliable", 0)
func _grab_denied(net_id: int) -> void:
	_held_by_me.erase(net_id)
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		_applying = true
		if node.has_method("drop"):
			node.call("drop")
		_freeze_replica(node)
		_applying = false


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _held_pose(net_id: int, pos: Vector3, quat: Quaternion) -> void:
	if not _nm.is_host():
		return
	if int(_remote_held.get(net_id, -1)) != multiplayer.get_remote_sender_id():
		return
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node) and node is Node3D:
		(node as Node3D).global_position = pos
		(node as Node3D).quaternion = quat


@rpc("any_peer", "call_remote", "reliable", 0)
func _release(net_id: int, pos: Vector3, quat: Quaternion, lin: Vector3, ang: Vector3) -> void:
	if not _nm.is_host():
		return
	if int(_remote_held.get(net_id, -1)) != multiplayer.get_remote_sender_id():
		return
	_remote_held.erase(net_id)
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node) and node is RigidBody3D:
		var body := node as RigidBody3D
		body.global_position = pos
		body.quaternion = quat
		body.freeze = false
		body.linear_velocity = lin
		body.angular_velocity = ang
		body.sleeping = false


# ── Replicated events ─────────────────────────────────────────────────────────

## Called (via the NetworkManager facade) from state-transition hooks.
func report_event(kind: int, args: Dictionary) -> void:
	if _applying or not _nm.is_active():
		return
	var wire := _encode_args(args)
	if _nm.is_host():
		_event_apply.rpc(kind, wire)
	else:
		_event_req.rpc_id(1, kind, wire)


@rpc("any_peer", "call_remote", "reliable", 0)
func _event_req(kind: int, wire: Dictionary) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	_apply_event(kind, wire)
	# Relay to everyone except the originator (who already has the state).
	for id: int in _nm.peers:
		if id != 1 and id != sender:
			_event_apply.rpc_id(id, kind, wire)


@rpc("authority", "call_remote", "reliable", 0)
func _event_apply(kind: int, wire: Dictionary) -> void:
	_apply_event(kind, wire)


func _apply_event(kind: int, wire: Dictionary) -> void:
	var a := _decode_args(wire)
	_applying = true
	match kind:
		EV_CART_INSERT:
			if _valid(a, ["sys", "cart"]):
				a["sys"].restore_cartridge(a["cart"])
		EV_CART_REMOVE:
			if _valid(a, ["sys"]):
				a["sys"].get_node("CartridgeSlot").drop_object()
		EV_TAPE_INSERT:
			if _valid(a, ["vcr", "tape"]):
				a["vcr"].restore_tape(a["tape"])
		EV_TAPE_REMOVE:
			if _valid(a, ["vcr"]):
				a["vcr"].get_node("TapeSlot").drop_object()
		EV_TV_PLUG:
			if _valid(a, ["owner", "tv"]):
				a["owner"].restore_cable_connection(a["tv"])
		EV_TV_UNPLUG:
			if _valid(a, ["tv"]):
				a["tv"].get_node("CompositePort").drop_object()
		EV_PORT_PLUG:
			if _valid(a, ["sys", "ctrl"]):
				a["ctrl"].restore_port_connection(a["sys"], int(a.get("port", 0)))
		EV_PORT_UNPLUG:
			if _valid(a, ["sys"]):
				a["sys"].get_node("ControllerPort%d" % (int(a.get("port", 0)) + 1)).drop_object()
		EV_SYS_POWER:
			# Client intent — the host toggles for real. Run un-suppressed so
			# the host's own hook broadcasts EV_SYS_POWER_STATE afterwards.
			if _nm.is_host() and _valid(a, ["sys"]):
				_applying = false
				a["sys"].toggle_power()
		EV_SYS_POWER_STATE:
			if _valid(a, ["sys"]) and a["sys"].has_method("net_set_remote_power"):
				a["sys"].net_set_remote_power(bool(a.get("on", false)))
		EV_TV_POWER:
			if _valid(a, ["tv"]):
				a["tv"].remote_power_toggle()
		EV_TV_VOL_UP:
			if _valid(a, ["tv"]):
				a["tv"].remote_volume_up()
		EV_TV_VOL_DOWN:
			if _valid(a, ["tv"]):
				a["tv"].remote_volume_down()
		EV_TV_CRT:
			if _valid(a, ["tv"]):
				a["tv"].set_crt_enabled(bool(a.get("on", true)))
		EV_VCR_CMD:
			# Transport runs on the host only pre-netplay (playback is local
			# to the host; clients see the placeholder screen).
			if _nm.is_host() and _valid(a, ["vcr"]):
				var vcr: Node = a["vcr"]
				match str(a.get("cmd", "")):
					"play": vcr.remote_play()
					"pause": vcr.remote_pause()
					"stop": vcr.remote_stop()
					"ff": vcr.remote_ff()
					"rew": vcr.remote_rewind()
	_applying = false


func _valid(a: Dictionary, keys: Array) -> bool:
	for k: String in keys:
		if not is_instance_valid(a.get(k)):
			return false
	return true


## Encode node references as {"$id": net_id} (registered) or {"$path": path}
## (scene-placed, e.g. the room TV); primitives pass through.
func _encode_args(args: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in args:
		var v: Variant = args[k]
		if v is Node:
			var id := id_of(v)
			if id >= 0:
				out[k] = {"$id": id}
			else:
				out[k] = {"$path": str((v as Node).get_path())}
		else:
			out[k] = v
	return out


func _decode_args(wire: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in wire:
		var v: Variant = wire[k]
		if v is Dictionary and (v as Dictionary).has("$id"):
			out[k] = _registry.get(int(v["$id"]))
		elif v is Dictionary and (v as Dictionary).has("$path"):
			out[k] = get_node_or_null(NodePath(str(v["$path"])))
		else:
			out[k] = v
	return out


# ── File-backed objects (M3) ──────────────────────────────────────────────────
#
# Spawn entries for file-backed objects carry file_md5/file_size so clients can
# resolve content they don't have at the host's path. Policy per kind:
#  - book / video: transferable via NetFileTransfer (content-addressed).
#  - rom: HASH-VERIFY ONLY — never transferred (copyright: see file_transfer.gd).
#    The client searches its own rom library for a byte-identical file and remaps
#    the path; a missing ROM just means netplay won't start for that peer.

## md5 -> {net_id, prop} for transfers this client has in flight.
var _fetching: Dictionary = {}
var _ft_wired := false


## What file (if any) backs this object: {kind, prop}.
func _file_desc(node: Node) -> Dictionary:
	if node is PDFBook:
		return {"kind": "book", "prop": "pdf_path"}
	if node is RetroCartridge:
		return {"kind": "rom", "prop": "rom_path"}
	if node is VCRTape:
		return {"kind": "video", "prop": "video_path"}
	return {}


## Host: attach file_md5/file_size to a spawn entry. Uses the persistent hash
## cache; a cache miss hashes on a worker thread and follows up with _file_info
## so big files (videos) never hitch the frame.
func _augment_file_fields(node: Node, entry: Dictionary) -> void:
	if not _nm.is_host():
		return
	var d := _file_desc(node)
	if d.is_empty():
		return
	var path := str(node.get(d["prop"]))
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var md5 := str(node.get_meta("net_md5", ""))
	if md5.is_empty():
		md5 = NetFileTransfer.cached_hash_of(path)
	if not md5.is_empty():
		node.set_meta("net_md5", md5)
		entry["file_md5"] = md5
		entry["file_size"] = NetFileTransfer.size_of(path)
		if NetFileTransfer.TRANSFER_KINDS.has(str(d["kind"])):
			_nm._file_transfer.serve_register(md5, path)
		return
	# Not cached yet — hash in the background, then broadcast the follow-up.
	var net_id := id_of(node)
	if net_id < 0 or node.has_meta("net_hashing"):
		return
	node.set_meta("net_hashing", true)
	WorkerThreadPool.add_task(func() -> void:
		var h := NetFileTransfer.hash_of(path)
		call_deferred("_on_file_hashed", net_id, h, path))


func _on_file_hashed(net_id: int, md5: String, path: String) -> void:
	var node: Node = _registry.get(net_id)
	if not is_instance_valid(node) or md5.is_empty():
		return
	node.remove_meta("net_hashing")
	node.set_meta("net_md5", md5)
	var d := _file_desc(node)
	if NetFileTransfer.TRANSFER_KINDS.has(str(d.get("kind", ""))):
		_nm._file_transfer.serve_register(md5, path)
	if _nm.is_host() and _nm.is_active():
		_file_info.rpc(net_id, md5, NetFileTransfer.size_of(path))


@rpc("authority", "call_remote", "reliable", 0)
func _file_info(net_id: int, md5: String, size: int) -> void:
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		_resolve_file_fields(node, {"file_md5": md5, "file_size": size})


## Client: make the object's backing file usable locally, or arrange for it.
func _resolve_file_fields(node: Node, entry: Dictionary) -> void:
	if not _nm.is_client():
		return
	var d := _file_desc(node)
	if d.is_empty():
		return
	var prop := str(d["prop"])
	var kind := str(d["kind"])
	var path := str(node.get(prop))
	if not path.is_empty() and FileAccess.file_exists(path):
		return   # host's path happens to exist here (same machine / shared lib)
	var md5 := str(entry.get("file_md5", ""))
	var size := int(entry.get("file_size", 0))
	if md5.is_empty():
		# Host hasn't hashed it yet — _file_info will re-enter when it has.
		node.set(prop, "")
		return
	if kind == "rom":
		# Verify-only: find our own byte-identical copy, never transfer.
		var dirs: Array = [RomLibrary.default_roms_root()]
		var found := NetFileTransfer.resolve_by_md5(md5, kind, size, path, dirs)
		if not found.is_empty():
			node.set(prop, found)
			print("[NetObjectSync] rom matched by hash: %s" % found)
		else:
			node.set(prop, "")
			print("[NetObjectSync] rom %s… not in local library (verify-only, not transferred)" % md5.left(8))
		return
	var found := NetFileTransfer.resolve_by_md5(md5, kind, size, path)
	if not found.is_empty():
		node.set(prop, found)
		return
	# Fetch it. Track by md5 so transfer signals route back to this object.
	node.set(prop, "")
	_wire_transfer_signals()
	_fetching[md5] = {"net_id": id_of(node), "prop": prop}
	if node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "DOWNLOADING…")
	_nm._file_transfer.request_file(md5, kind, size, path.get_extension())


func _wire_transfer_signals() -> void:
	if _ft_wired:
		return
	_ft_wired = true
	var ft: NetFileTransfer = _nm._file_transfer
	ft.transfer_progress.connect(_on_transfer_progress)
	ft.transfer_done.connect(_on_transfer_done)
	ft.transfer_failed.connect(_on_transfer_failed)


func _fetch_node(md5: String) -> Node:
	var info: Dictionary = _fetching.get(md5, {})
	if info.is_empty():
		return null
	var node: Node = _registry.get(int(info["net_id"]))
	return node if is_instance_valid(node) else null


func _on_transfer_progress(md5: String, received: int, total: int) -> void:
	var node := _fetch_node(md5)
	if node != null and node.has_method("net_set_download_status") and total > 0:
		node.call("net_set_download_status", "DOWNLOADING %d%%" % int(received * 100.0 / total))


func _on_transfer_done(md5: String, path: String) -> void:
	var info: Dictionary = _fetching.get(md5, {})
	_fetching.erase(md5)
	var node: Node = _registry.get(int(info.get("net_id", -1)))
	if is_instance_valid(node):
		if node.has_method("net_set_download_status"):
			node.call("net_set_download_status", "")
		node.set(str(info["prop"]), path)


func _on_transfer_failed(md5: String, reason: String) -> void:
	var node := _fetch_node(md5)
	_fetching.erase(md5)
	if node != null and node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "UNAVAILABLE")
	print("[NetObjectSync] transfer %s… failed: %s" % [md5.left(8), reason])


# ── Helpers ───────────────────────────────────────────────────────────────────

func _is_zone_snapped(node: Node) -> bool:
	var driver: Variant = node.get("_grab_driver")
	if driver and driver.primary and driver.primary.by is XRToolsSnapZone:
		return true
	return false


func _is_hand_held(node: Node) -> bool:
	if not node.has_method("is_picked_up") or not node.call("is_picked_up"):
		return false
	return not _is_zone_snapped(node)
