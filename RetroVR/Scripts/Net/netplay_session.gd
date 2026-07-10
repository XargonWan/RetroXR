## NetplaySession — deterministic delay-based lockstep netplay (multiplayer M4b).
##
## Fixed-path child of NetworkManager ("Netplay") so RPC node paths match on
## every peer. Every peer runs the SAME core+ROM locally; the only thing that
## crosses the wire is one input frame per participating port. The C++ side
## (Wrapper netplay gate) runs frame N only once PostNetplayInputs(N) arrives,
## so identical input timelines ⇒ identical video+audio on every peer.
##
## Model (star topology, host = assembler):
##  - Each peer samples its OWNED ports' input and tags it `frame` = emu+delay,
##    sending the last few frames redundantly (unreliable) to cover packet loss.
##  - The host merges everyone's owned-port input, and once a frame is complete
##    (all participating ports present) assembles it and broadcasts it to all.
##  - Every peer drains complete frames, in order, into its local core.
##  - A stall (missing frame at the gate) triggers a reliable re-request.
##  - Late join: host stalls the pipeline, ships a savestate, joiner loads it and
##    resumes. Desync: peers' periodic RAM CRCs are compared; a mismatch triggers
##    a savestate resync, 3 strikes → spectator.
##
## Testability: the session talks only to a duck-typed `system` (get_libretro_node,
## net_start_core, net_stop_core) and `libretro` (GetFrameCount, PostNetplayInputs,
## SetNetplayMode, RequestSaveState/LoadState + savestate/crc signals), so a
## headless probe drives it with mocks — no HW render or real core needed.
class_name NetplaySession
extends Node

const CH_CONTROL := 0   # reliable
const CH_NPINPUT := 2   # unreliable
const SEND_WINDOW := 5          # frames of redundancy per packet
const STALL_MS := 100           # gate stall before a reliable re-request
const REREQ_THROTTLE_MS := 50
const CRC_STRIKES := 3
const PRUNE_BEHIND := 120       # keep this many frames behind the gate
const MAX_AHEAD := 10           # rollback: speculation cap past the confirmed frame
const TRANSFER_LEAD := 8        # frames ahead a port-ownership handoff is scheduled
const DISK_LEAD := 8            # frames ahead a disc eject/swap is scheduled

signal desync_detected(peer_id: int, frame: int)
signal session_stopped(reason: String)

var _nm: Node = null

# Injectable seams for probes (else resolved from ObjectSync / RetroSystem).
var system_override: Object = null

# Session parameters (identical on every peer after cold start).
var _system: Object = null
var _lib: Object = null
var _sys_net_id := -1
var _core := ""
var _rom_md5 := ""
var _options: Dictionary = {}
var _delay := 3
var _rollback := false          # GGPO-style: local input live, remote predicted
var _all_ports: PackedInt32Array = PackedInt32Array()   # sorted participating ports
var _local_ports: Dictionary = {}       # port -> true (owned by this peer)
var _owners: Dictionary = {}            # port -> peer_id
var _port_mask := 0
# Scheduled ownership handoffs (controller passed to another player). Keyed by
# port -> {frame, old, new, applied}. `frame` is the deterministic apply frame;
# every peer flips _owners[port] to `new` exactly at it, so no frame ever gets a
# port's input from two peers. Cleared once assembly passes `frame`.
var _pending: Dictionary = {}

var _running := false
var _join_paused := false                # host: pipeline frozen for a late join

# Scheduling / assembly.
var _sched_frame := 0                    # next frame to schedule local input for
var _next_post := 0                      # next frame to feed the local core
var _complete_upto := -1                 # host: highest contiguous assembled frame
var _pending_local_route: Dictionary = {}  # port -> [btn,alx,aly,arx,ary] (this visual frame)
var _local_inputs: Dictionary = {}       # frame -> {port -> Array(5)} (for redundant resend)
var _recv: Dictionary = {}               # host: frame -> {port -> Array(5)}
var _frames: Dictionary = {}             # frame -> PackedInt32Array(20), ready to post

var _last_progress_ms := 0
var _last_rereq_ms := 0

# Cold-start readiness (host).
var _ready_peers: Dictionary = {}

# Desync tracking.
var _crc_table: Dictionary = {}          # frame -> {peer_id -> crc}
var _strikes: Dictionary = {}            # peer_id -> int
var _spectators: Dictionary = {}         # peer_id -> true

# Late-join bookkeeping (host).
var _joining: Dictionary = {}            # peer_id -> true (savestate in flight)


func _ready() -> void:
	_nm = get_parent()


func is_running() -> bool:
	return _running


func is_active() -> bool:
	return _running or _join_paused or not _ready_peers.is_empty()


# ── Cold start (host) ─────────────────────────────────────────────────────────

## Host entry point. `owners` maps participating port -> peer_id. Verifies the
## core is netplay-capable, then drives the cold-start handshake on all peers.
## rollback: 1 = force on, 0 = force lockstep, -1 = auto (core capability).
func start_host(system: Object, core: String, rom_md5: String, owners: Dictionary,
		delay: int, rollback := -1) -> bool:
	if not _nm.is_host():
		return false
	if not NetplayCores.is_capable(core):
		push_warning("[Netplay] core '%s' is not determinism-verified; refusing to start" % core)
		return false
	_system = system
	_sys_net_id = _resolve_net_id(system)
	_core = core
	_rom_md5 = rom_md5
	_options = NetplayCores.forced_options(core)
	_delay = clampi(delay, 1, 8)
	_rollback = NetplayCores.rollback_capable(core) if rollback < 0 else rollback == 1
	_set_owners(owners)
	_ready_peers.clear()

	var opt_wire := _options
	# SRAM: every peer must boot with IDENTICAL battery-save content or the
	# cores desync at frame 0. Ship the host's .srm bytes; the host itself
	# boots from the same bytes but keeps its real file for persistence.
	var sram := PackedByteArray()
	if system.has_method("net_sram_file_bytes"):
		sram = system.net_sram_file_bytes()
	# Everyone (incl. host) cold-starts through the same path. The host loads
	# from its own file — byte-identical to `sram` since it was read just now.
	_np_start.rpc(_sys_net_id, _core, _rom_md5, opt_wire, _owners, _delay, 0, _rollback, sram)
	_cold_start_local(0)
	_mark_ready(1)
	return true


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_start(sys_net_id: int, core: String, rom_md5: String, options: Dictionary,
		owners: Dictionary, delay: int, start_frame: int, rollback := false,
		sram := PackedByteArray()) -> void:
	_sys_net_id = sys_net_id
	_core = core
	_rom_md5 = rom_md5
	_options = options
	_delay = delay
	_rollback = rollback
	_set_owners(owners)
	_system = _resolve_system(sys_net_id)
	if _system == null:
		push_warning("[Netplay] client cannot resolve system net_id %d" % sys_net_id)
		_np_ready_fail.rpc_id(1, "cannot resolve game system")
		return
	# ROM policy: verify-by-hash only (never transferred). A peer without a
	# byte-identical local copy can't join the lockstep game.
	if _system.has_method("net_resolve_rom") and not _system.net_resolve_rom(rom_md5):
		_np_ready_fail.rpc_id(1, "missing ROM (md5 %s…)" % rom_md5.left(8))
		return
	# Boot with the host's SRAM, and never persist someone else's game locally.
	if _system.has_method("net_set_sram"):
		_system.net_set_sram("", sram)
	_cold_start_local(start_frame)
	_np_ready.rpc_id(1)


## Bring the local core up under the netplay gate at `start_frame`.
func _cold_start_local(start_frame: int) -> void:
	_reset_runtime(start_frame)
	# Rollback flags must be set before StartContent spins the emu thread up.
	# get_libretro_node() exists on every system implementation (incl. mocks).
	var pre_lib: Object = _system.get_libretro_node() if _system.has_method("get_libretro_node") else null
	if pre_lib != null and pre_lib.has_method("SetNetplayRollback"):
		var local_mask := 0
		for port: int in _local_ports:
			local_mask |= (1 << port)
		pre_lib.SetNetplayRollback(_rollback, local_mask, MAX_AHEAD)
	# net_start_core sets the gate (SetNetplayMode) BEFORE StartContent so the
	# core holds at the start frame until inputs post.
	_lib = _system.net_start_core(_port_mask, start_frame, _options)
	if _lib != null and _lib.has_signal("netplay_crc"):
		if not _lib.netplay_crc.is_connected(_on_local_crc):
			_lib.netplay_crc.connect(_on_local_crc)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_ready() -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _joining.has(sender):
		_resume_after_join(sender)   # late joiner has loaded the savestate
	else:
		_mark_ready(sender)          # cold-start readiness


## A peer can't take part (missing ROM, unresolvable system, failed load).
@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_ready_fail(reason: String) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[Netplay] peer %d cannot join: %s" % [sender, reason])
	if _joining.has(sender):
		# Late joiner failed — resume the game without them (they keep the
		# placeholder screen). Non-fatal for the running session.
		_resume_after_join(sender)
		_spectators[sender] = true
		return
	# Cold start: if the failed peer owns a port the game can't happen; abort
	# for everyone. A non-owner failure just proceeds without them.
	for port: int in _owners:
		if int(_owners[port]) == sender:
			var msg := "netplay aborted: player %s — %s" % [
				str(_nm.peers.get(sender, {}).get("name", sender)), reason]
			if _nm.has_signal("status_changed"):
				_nm.status_changed.emit(msg)
			stop(msg)
			return
	_spectators[sender] = true
	_ready_peers[sender] = true   # counts as "answered" so the start isn't held up
	_mark_ready(1)                # re-evaluate: everyone else may be ready now


func _mark_ready(peer_id: int) -> void:
	_ready_peers[peer_id] = true
	# All current peers ready → go.
	for id: int in _nm.peers:
		if not _ready_peers.has(id):
			return
	_np_go.rpc()
	_begin_running()


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_go() -> void:
	_begin_running()


func _begin_running() -> void:
	if _running:
		return
	_running = true
	_last_progress_ms = _now()
	print("[Netplay] running — core=%s delay=%d ports=%s owners=%s" %
		[_core, _delay, str(_all_ports), str(_owners)])


# ── Stop ──────────────────────────────────────────────────────────────────────

func stop(reason := "stopped") -> void:
	if _nm.is_host():
		if _running or not _ready_peers.is_empty():
			_np_stop.rpc(reason)
		_stop_local(reason)
	else:
		# Clients can't broadcast — route the intent through the host so the
		# other peers don't stall at the gate, and stop locally right away
		# (also covers leaving the session, where the connection is closing).
		if _running and multiplayer != null and multiplayer.multiplayer_peer != null:
			_np_stop_req.rpc_id(1, reason)
		_stop_local(reason)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_stop_req(reason: String) -> void:
	if not _nm.is_host() or not _running:
		return
	_np_stop.rpc(reason)
	_stop_local(reason)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_stop(reason: String) -> void:
	_stop_local(reason)


func _stop_local(reason: String) -> void:
	if not is_active() and _system == null:
		return
	_running = false
	_join_paused = false
	if _lib != null and _lib.has_signal("netplay_crc") and _lib.netplay_crc.is_connected(_on_local_crc):
		_lib.netplay_crc.disconnect(_on_local_crc)
	if _lib != null and _lib.has_method("SetNetplayRollback"):
		_lib.SetNetplayRollback(false, 0, MAX_AHEAD)
	if _system != null and _system.has_method("net_stop_core"):
		_system.net_stop_core()
	_lib = null
	_system = null
	_ready_peers.clear()
	_frames.clear()
	_recv.clear()
	_local_inputs.clear()
	_crc_table.clear()
	_pending.clear()
	session_stopped.emit(reason)
	print("[Netplay] stopped — %s" % reason)


func _reset_runtime(start_frame: int) -> void:
	_sched_frame = start_frame
	_next_post = start_frame
	_complete_upto = start_frame - 1
	_frames.clear()
	_recv.clear()
	_local_inputs.clear()
	_pending_local_route.clear()
	_crc_table.clear()
	_strikes.clear()
	_spectators.clear()
	_joining.clear()
	_pending.clear()
	_running = false
	_join_paused = false


# ── Input seam ────────────────────────────────────────────────────────────────

## Called from retro_controller for a port plugged into `system`. Returns true if
## netplay consumed the input (caller must NOT drive the core directly). Offline
## or a non-participating system → false (unchanged local behaviour).
func route(system: Object, port: int, m: Dictionary) -> bool:
	if not _running or system == null or system != _system:
		return false
	if not _is_participating(port):
		return false
	if _local_ports.has(port):
		if _rollback:
			# Rollback: let the controller hit SetJoypadState directly — the
			# wrapper redirects locally-owned masked ports into the live-input
			# slot the emu thread samples (zero added latency).
			return false
		_pending_local_route[port] = [
			int(m.get("btn", 0)), int(m.get("alx", 0)), int(m.get("aly", 0)),
			int(m.get("arx", 0)), int(m.get("ary", 0))]
	# Participating port (local or remote-owned) is driven by the gate — swallow.
	return true


func _capture_local() -> Dictionary:
	var out := {}
	for port: int in _local_ports:
		out[port] = _pending_local_route.get(port, [0, 0, 0, 0, 0])
	return out


# ── Port handoff (pass-me: hand a controller to another player) ────────────────
# The controller's cable plug holds the port, so passing the controller *body*
# to another player keeps it plugged. When the body's grab authority resolves to
# a new peer (host arbitration), the port that controller occupies is handed to
# that peer here. Host-only and frame-scheduled: the swap lands on the same frame
# on every peer so the deterministic core state never forks. Lockstep only — a
# rollback core would need the emu-thread input mask re-issued mid-speculation.

## Host: the holder of `controller` (a RetroController) changed to `new_owner` —
## a peer id when someone is holding it, or 0 when it was dropped (unowned; the
## host then feeds that port neutral input until someone grabs it again). If the
## controller occupies a participating netplay port, schedule the change.
func handoff_controller(controller: Object, new_owner: int) -> void:
	if not _nm.is_host() or not _running or _rollback:
		return
	if controller == null or not is_instance_valid(controller):
		return
	if controller.get("_connected_system") != _system:
		return
	var port := int(controller.get("_port_index"))
	if port < 0 or not _is_participating(port):
		return
	# Compare against the latest intended owner so a rapid grab/drop coalesces
	# (a second schedule just overwrites the not-yet-landed one).
	if new_owner < 0 or new_owner == _intended_owner(port):
		return
	# 0 = unowned (host supplies neutral). A real owner must be a present, active
	# peer.
	if new_owner > 0 and (not _nm.peers.has(new_owner) or _spectators.has(new_owner)):
		return
	_schedule_transfer(port, new_owner)


## Latest owner intent for a port: the not-yet-landed handoff target if one is
## pending, else the current owner.
func _intended_owner(port: int) -> int:
	if _pending.has(port):
		return int(_pending[port]["new"])
	return int(_owners.get(port, -1))


## Host: pick a deterministic apply frame ahead of every peer's scheduler and
## broadcast the handoff. Every peer (incl. host) records it and flips at `frame`.
func _schedule_transfer(port: int, new_owner: int) -> void:
	var old_owner := int(_owners.get(port, -1))
	# Every peer schedules at most up to emu+delay, and no peer's emu can exceed
	# _complete_upto+1 (the core gates on posted frames), so _complete_upto+delay+
	# LEAD is strictly past every peer's current _sched_frame — a safe boundary.
	var frame := _complete_upto + _delay + TRANSFER_LEAD
	_pending[port] = {"frame": frame, "old": old_owner, "new": new_owner, "applied": false}
	print("[Netplay] port %d handoff: peer %d -> %d @frame %d" %
		[port, old_owner, new_owner, frame])
	_np_transfer.rpc(port, old_owner, new_owner, frame)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_transfer(port: int, old_owner: int, new_owner: int, frame: int) -> void:
	_pending[port] = {"frame": frame, "old": old_owner, "new": new_owner, "applied": false}


## Owner of `port` for a specific frame, honouring a pending (not-yet-cleared)
## handoff. Used by the host's accept + stall paths, which straddle the boundary.
func _owner_for_frame(port: int, f: int) -> int:
	var p: Dictionary = _pending.get(port, {})
	if not p.is_empty():
		return int(p["old"]) if f < int(p["frame"]) else int(p["new"])
	return int(_owners.get(port, -1))


## Apply any handoff whose boundary this scheduled frame has reached, flipping
## _owners + _local_ports so sampling switches exactly at the agreed frame.
func _apply_pending_transfers(f: int) -> void:
	for port: int in _pending:
		var p: Dictionary = _pending[port]
		if not bool(p["applied"]) and f >= int(p["frame"]):
			_owners[port] = int(p["new"])
			p["applied"] = true
			_recompute_local_ports()


# ── Disc swap (multi-disc games during netplay) ────────────────────────────────
# A disc eject/replace changes deterministic core state, so every peer applies
# it on the SAME frame: the host picks a frame safely ahead of the pipeline and
# broadcasts; each peer resolves the disc by md5 locally (never transferred)
# and hands it to the C++ gate (ScheduleDiscOp), which applies it strictly
# before running that frame. Lockstep only, same as port handoffs.

## Host: schedule a disc op for this session's system. op 0 = eject,
## op 1 = replace the image at `index` with the disc whose md5 matches.
func schedule_disk_op(system: Object, op: int, md5: String, index: int) -> void:
	if not _nm.is_host() or not _running or _rollback or system != _system:
		return
	var frame := _complete_upto + _delay + DISK_LEAD
	print("[Netplay] disc op %d (md5 %s…) @frame %d" % [op, md5.left(8), frame])
	_np_disk.rpc(op, md5, index, frame)
	_apply_disk_op(op, md5, index, frame)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_disk(op: int, md5: String, index: int, frame: int) -> void:
	_apply_disk_op(op, md5, index, frame)


func _apply_disk_op(op: int, md5: String, index: int, frame: int) -> void:
	if _lib == null or not _lib.has_method("ScheduleDiscOp"):
		return
	var path := ""
	if op == 1:
		path = _resolve_disk_path(md5)
		if path.is_empty():
			# No local copy of the new disc — this peer will desync at the
			# swap frame; the CRC checker's savestate resync (or spectator
			# demotion) takes it from there.
			push_warning("[Netplay] disc swap: no local file for md5 %s…" % md5.left(8))
			return
	_lib.ScheduleDiscOp(frame, op, index, path)


## Find this peer's byte-identical copy of the new disc (verify-only, never
## transferred — same policy as ROMs at cold start).
func _resolve_disk_path(md5: String) -> String:
	if md5.is_empty():
		return ""
	if _system != null and _system.has_method("net_resolve_rom") \
			and _system.net_resolve_rom(md5):
		return str(_system.get("rom_path"))
	return ""


# ── Per-frame drive ───────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _running or _lib == null:
		return
	if _rollback:
		_pump_local_records()
	else:
		_schedule_local()
	if _nm.is_host():
		if not _join_paused:
			_host_assemble()
	_drain_to_core()
	_check_stall()
	_prune()


## Rollback: the emu thread already ran frames with live local input — drain
## its per-frame records (frame, port, 5 values) and ship them for assembly.
func _pump_local_records() -> void:
	if not _lib.has_method("TakeNetplayLocalRecords"):
		return
	var recs: PackedInt32Array = _lib.TakeNetplayLocalRecords()
	var i := 0
	while i + 7 <= recs.size():
		var f := int(recs[i])
		var port := int(recs[i + 1])
		var vals := [int(recs[i + 2]), int(recs[i + 3]), int(recs[i + 4]),
			int(recs[i + 5]), int(recs[i + 6])]
		if not _local_inputs.has(f):
			_local_inputs[f] = {}
		_local_inputs[f][port] = vals
		if _nm.is_host():
			_recv_put(f, port, vals)
		_sched_frame = maxi(_sched_frame, f + 1)
		i += 7
	if not _nm.is_host() and recs.size() > 0:
		_send_local_window()


## Schedule local owned-port input up to emu+delay, and (re)send the window.
func _schedule_local() -> void:
	var emu := int(_lib.GetFrameCount())
	var horizon := emu + _delay
	while _sched_frame <= horizon:
		_apply_pending_transfers(_sched_frame)
		var inp := _capture_local()
		_local_inputs[_sched_frame] = inp
		if _nm.is_host():
			for port: int in inp:
				_recv_put(_sched_frame, port, inp[port])
		_sched_frame += 1
	if not _nm.is_host():
		_send_local_window()


func _send_local_window() -> void:
	if _local_ports.is_empty():
		return
	var first := maxi(_next_post, _sched_frame - SEND_WINDOW)
	var buf := StreamPeerBuffer.new()
	var frames: Array = []
	for f in range(first, _sched_frame):
		if _local_inputs.has(f):
			frames.append(f)
	if frames.is_empty():
		return
	buf.put_u8(frames.size())
	for f: int in frames:
		var inp: Dictionary = _local_inputs[f]
		buf.put_u32(f)
		buf.put_u8(inp.size())
		for port: int in inp:
			_put_port(buf, port, inp[port])
	_np_input.rpc_id(1, buf.data_array)


@rpc("any_peer", "call_remote", "unreliable", CH_NPINPUT)
func _np_input(bytes: PackedByteArray) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _spectators.has(sender):
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_available_bytes() < 1:
		return
	var nframes := buf.get_u8()
	for _i in range(nframes):
		if buf.get_available_bytes() < 5:
			return
		var f := int(buf.get_u32())
		var nports := buf.get_u8()
		for _p in range(nports):
			if buf.get_available_bytes() < 11:
				return
			var port := buf.get_u8()
			var vals := _get_port(buf)
			# Only accept from the peer that owns the port on THAT frame (honours a
			# pending handoff), and only for frames not yet assembled.
			if _owner_for_frame(port, f) == sender and f > _complete_upto:
				_recv_put(f, port, vals)


func _host_assemble() -> void:
	var changed := false
	while true:
		var f := _complete_upto + 1
		if not _frame_ready(f):
			break
		_frames[f] = _flat_from_ports(_recv.get(f, {}))
		_complete_upto = f
		changed = true
	if changed:
		_broadcast_frames()


## A frame is ready to assemble once every participating port has input — or is
## unowned (dropped controller), which the host fills with neutral (absent from
## _recv -> zeros in _flat_from_ports) rather than stalling on a missing sender.
func _frame_ready(f: int) -> bool:
	var pm: Dictionary = _recv.get(f, {})
	for port in _all_ports:
		if not pm.has(port) and _owner_for_frame(port, f) != 0:
			return false
	return true


func _broadcast_frames() -> void:
	var first := maxi(_next_post, _complete_upto - SEND_WINDOW + 1)
	var buf := StreamPeerBuffer.new()
	var frames: Array = []
	for f in range(first, _complete_upto + 1):
		if _frames.has(f):
			frames.append(f)
	if frames.is_empty():
		return
	buf.put_u8(frames.size())
	for f: int in frames:
		buf.put_u32(f)
		var flat: PackedInt32Array = _frames[f]
		for port in _all_ports:
			var base := port * 5
			buf.put_u16(int(flat[base]) & 0xFFFF)
			buf.put_16(flat[base + 1]); buf.put_16(flat[base + 2])
			buf.put_16(flat[base + 3]); buf.put_16(flat[base + 4])
	_np_frame.rpc(buf.data_array)


@rpc("authority", "call_remote", "unreliable", CH_NPINPUT)
func _np_frame(bytes: PackedByteArray) -> void:
	_ingest_frame_packet(bytes)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_frame_reliable(bytes: PackedByteArray) -> void:
	_ingest_frame_packet(bytes)


func _ingest_frame_packet(bytes: PackedByteArray) -> void:
	if _nm.is_host():
		return
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	if buf.get_available_bytes() < 1:
		return
	var nframes := buf.get_u8()
	for _i in range(nframes):
		var need := 4 + _all_ports.size() * 10
		if buf.get_available_bytes() < need:
			return
		var f := int(buf.get_u32())
		var flat := PackedInt32Array()
		flat.resize(20)
		for port in _all_ports:
			var base := port * 5
			flat[base] = buf.get_u16()
			flat[base + 1] = buf.get_16(); flat[base + 2] = buf.get_16()
			flat[base + 3] = buf.get_16(); flat[base + 4] = buf.get_16()
		if f >= _next_post and not _frames.has(f):
			_frames[f] = flat


func _drain_to_core() -> void:
	var progressed := false
	while _frames.has(_next_post):
		_lib.PostNetplayInputs(_next_post, _frames[_next_post])
		_next_post += 1
		progressed = true
	if progressed:
		_last_progress_ms = _now()


## Reliable re-request when the gate has been starved past STALL_MS.
func _check_stall() -> void:
	if _frames.has(_next_post):
		return
	var now := _now()
	if now - _last_progress_ms < STALL_MS:
		return
	if now - _last_rereq_ms < REREQ_THROTTLE_MS:
		return
	_last_rereq_ms = now
	if _nm.is_host():
		# Missing a client's input for the next-to-assemble frame.
		var f := _complete_upto + 1
		var pm: Dictionary = _recv.get(f, {})
		for port in _all_ports:
			if not pm.has(port):
				var owner := _owner_for_frame(port, f)
				if owner != 1 and owner > 0 and not _spectators.has(owner):
					_np_input_req.rpc_id(owner, f)
	else:
		_np_frame_req.rpc_id(1, _next_post)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_frame_req(frame: int) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var first := frame
	var buf := StreamPeerBuffer.new()
	var frames: Array = []
	for f in range(first, mini(first + SEND_WINDOW, _complete_upto + 1)):
		if _frames.has(f):
			frames.append(f)
	if frames.is_empty():
		return
	buf.put_u8(frames.size())
	for f: int in frames:
		buf.put_u32(f)
		var flat: PackedInt32Array = _frames[f]
		for port in _all_ports:
			var base := port * 5
			buf.put_u16(int(flat[base]) & 0xFFFF)
			buf.put_16(flat[base + 1]); buf.put_16(flat[base + 2])
			buf.put_16(flat[base + 3]); buf.put_16(flat[base + 4])
	_np_frame_reliable.rpc_id(sender, buf.data_array)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_input_req(frame: int) -> void:
	# Host asked us to re-send our owned-port input for `frame` reliably.
	if _local_ports.is_empty() or not _local_inputs.has(frame):
		return
	var buf := StreamPeerBuffer.new()
	buf.put_u8(1)
	var inp: Dictionary = _local_inputs[frame]
	buf.put_u32(frame)
	buf.put_u8(inp.size())
	for port: int in inp:
		_put_port(buf, port, inp[port])
	_np_input.rpc_id(1, buf.data_array)


# ── Late join (host stalls, ships a savestate) ────────────────────────────────

## Called by NetworkManager when a peer registers mid-session.
func on_peer_joined(peer_id: int) -> void:
	if not _nm.is_host() or not _running:
		return
	_joining[peer_id] = true
	_ready_peers.erase(peer_id)
	_join_paused = true      # freeze the pipeline — everyone stalls at the gate
	if _lib != null and _lib.has_method("RequestSaveState"):
		if not _lib.savestate_ready.is_connected(_on_savestate_for_join):
			_lib.savestate_ready.connect(_on_savestate_for_join)
		_lib.RequestSaveState()


func _on_savestate_for_join(data: PackedByteArray, frame: int) -> void:
	if _lib != null and _lib.savestate_ready.is_connected(_on_savestate_for_join):
		_lib.savestate_ready.disconnect(_on_savestate_for_join)
	if data.is_empty():
		push_warning("[Netplay] late-join savestate failed; core lacks serialization")
		_join_paused = false
		return
	for peer_id: int in _joining.keys():
		_np_savestate.rpc_id(peer_id, _sys_net_id, _core, _rom_md5, _options,
			_owners, _delay, data, frame, _rollback)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_savestate(sys_net_id: int, core: String, rom_md5: String, options: Dictionary,
		owners: Dictionary, delay: int, data: PackedByteArray, frame: int,
		rollback := false) -> void:
	_sys_net_id = sys_net_id
	_core = core
	_rom_md5 = rom_md5
	_options = options
	_delay = delay
	_rollback = rollback
	_set_owners(owners)
	_system = _resolve_system(sys_net_id)
	if _system == null:
		_np_ready_fail.rpc_id(1, "cannot resolve game system")
		return
	if _system.has_method("net_resolve_rom") and not _system.net_resolve_rom(rom_md5):
		_np_ready_fail.rpc_id(1, "missing ROM (md5 %s…)" % rom_md5.left(8))
		return
	# Late joiner: SRAM arrives inside the serialized state; don't persist.
	if _system.has_method("net_set_sram"):
		_system.net_set_sram("", PackedByteArray())
	_cold_start_local(frame)
	if _lib != null and _lib.has_method("RequestLoadState"):
		if not _lib.savestate_loaded.is_connected(_on_join_loaded):
			_lib.savestate_loaded.connect(_on_join_loaded)
		_lib.RequestLoadState(data, frame)


func _on_join_loaded(ok: bool) -> void:
	if _lib != null and _lib.savestate_loaded.is_connected(_on_join_loaded):
		_lib.savestate_loaded.disconnect(_on_join_loaded)
	if not ok:
		push_warning("[Netplay] late-join load failed")
		_np_ready_fail.rpc_id(1, "savestate load failed")
		return
	_begin_running()
	_np_ready.rpc_id(1)


# Host: a late joiner reported ready → resume the pipeline.
func _resume_after_join(peer_id: int) -> void:
	_joining.erase(peer_id)
	if _joining.is_empty():
		_join_paused = false
		_last_progress_ms = _now()


## Host: a peer disconnected. A departed port owner stalls the assembler
## forever, so end the game; a spectator/non-owner just gets cleaned up.
func on_peer_left(peer_id: int) -> void:
	if not _nm.is_host():
		return
	_ready_peers.erase(peer_id)
	_joining.erase(peer_id)
	_strikes.erase(peer_id)
	_spectators.erase(peer_id)
	if _joining.is_empty():
		_join_paused = false
	for port: int in _owners:
		if int(_owners[port]) == peer_id:
			stop("player left")
			return
	# A pending handoff to/from the departed peer would stall the gate at its
	# boundary (nobody supplies that port for the affected frames) — end the game.
	for port: int in _pending:
		var p: Dictionary = _pending[port]
		if int(p["old"]) == peer_id or int(p["new"]) == peer_id:
			stop("player left")
			return
	# Cold-start may have been waiting on this peer's _np_ready.
	if not _running and not _ready_peers.is_empty():
		_mark_ready(1)


# ── Desync detection ──────────────────────────────────────────────────────────

func _on_local_crc(frame: int, crc: int) -> void:
	var self_id := _self_id()
	_crc_record(frame, self_id, crc)
	if _nm.is_host():
		_check_crc(frame)
	else:
		_np_crc.rpc_id(1, frame, crc)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_crc(frame: int, crc: int) -> void:
	if not _nm.is_host():
		return
	_crc_record(frame, multiplayer.get_remote_sender_id(), crc)
	_check_crc(frame)


func _crc_record(frame: int, peer_id: int, crc: int) -> void:
	if not _crc_table.has(frame):
		_crc_table[frame] = {}
	_crc_table[frame][peer_id] = crc


func _check_crc(frame: int) -> void:
	var t: Dictionary = _crc_table.get(frame, {})
	if t.size() < 2:
		return
	var ref: int = t.get(1, t.values()[0])
	for peer_id: int in t:
		if int(t[peer_id]) != ref and peer_id != 1:
			_strikes[peer_id] = int(_strikes.get(peer_id, 0)) + 1
			print("[Netplay] DESYNC peer %d @frame %d (strike %d/%d)" %
				[peer_id, frame, _strikes[peer_id], CRC_STRIKES])
			desync_detected.emit(peer_id, frame)
			if int(_strikes[peer_id]) >= CRC_STRIKES:
				_spectators[peer_id] = true
				print("[Netplay] peer %d demoted to spectator" % peer_id)
			elif not _joining.has(peer_id):
				# Auto-resync via the late-join savestate path.
				on_peer_joined(peer_id)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _set_owners(owners: Dictionary) -> void:
	_owners = owners.duplicate()
	_pending.clear()
	var ports: Array = []
	for port: Variant in owners:
		ports.append(int(port))
	ports.sort()
	_all_ports = PackedInt32Array(ports)
	_port_mask = 0
	for p in _all_ports:
		_port_mask |= (1 << p)
	_recompute_local_ports()


## Rebuild _local_ports (ports this peer samples) from the current _owners.
func _recompute_local_ports() -> void:
	_local_ports.clear()
	var self_id := _self_id()
	for port: int in _owners:
		if int(_owners[port]) == self_id:
			_local_ports[int(port)] = true


func _is_participating(port: int) -> bool:
	return (_port_mask & (1 << port)) != 0


func _recv_put(frame: int, port: int, vals: Array) -> void:
	if not _recv.has(frame):
		_recv[frame] = {}
	_recv[frame][port] = vals


func _flat_from_ports(pm: Dictionary) -> PackedInt32Array:
	var flat := PackedInt32Array()
	flat.resize(20)
	for port: int in pm:
		var v: Array = pm[port]
		var base := port * 5
		for i in range(5):
			flat[base + i] = int(v[i])
	return flat


func _put_port(buf: StreamPeerBuffer, port: int, v: Array) -> void:
	buf.put_u8(port)
	buf.put_u16(int(v[0]) & 0xFFFF)
	buf.put_16(int(v[1])); buf.put_16(int(v[2]))
	buf.put_16(int(v[3])); buf.put_16(int(v[4]))


func _get_port(buf: StreamPeerBuffer) -> Array:
	return [buf.get_u16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16()]


func _prune() -> void:
	# Drop landed handoffs once the pipeline has posted past their boundary — from
	# then on _owners already reflects the new owner for every frame still in play.
	for port: int in _pending.keys():
		if _next_post > int(_pending[port]["frame"]):
			_pending.erase(port)
	var floor_frame := _next_post - PRUNE_BEHIND
	if floor_frame <= 0:
		return
	for f: int in _frames.keys():
		if f < floor_frame:
			_frames.erase(f)
	for f: int in _local_inputs.keys():
		if f < floor_frame:
			_local_inputs.erase(f)
	for f: int in _recv.keys():
		if f < floor_frame:
			_recv.erase(f)
	for f: int in _crc_table.keys():
		if f < floor_frame:
			_crc_table.erase(f)


func _self_id() -> int:
	if multiplayer != null and multiplayer.multiplayer_peer != null:
		return multiplayer.get_unique_id()
	return 1


func _now() -> int:
	return Time.get_ticks_msec()


func _resolve_net_id(system: Object) -> int:
	if _nm != null and _nm._object_sync != null and _nm._object_sync.has_method("id_of"):
		return _nm._object_sync.id_of(system)
	return -1


func _resolve_system(net_id: int) -> Object:
	if system_override != null:
		return system_override
	if _nm != null and _nm._object_sync != null and _nm._object_sync.has_method("node_for_id"):
		return _nm._object_sync.node_for_id(net_id)
	return null
