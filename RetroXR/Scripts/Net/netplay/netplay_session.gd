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
## How long a peer may take to get its core up before the session gives up on
## it. StartContent spins the emulation thread and returns, so a core that is
## missing, refused or wedged fails ASYNCHRONOUSLY: this deadline is the only
## thing standing between that and a peer reporting itself ready with no core.
const CORE_READY_MS := 10000
const SEND_WINDOW := 5          # frames of redundancy per packet
const STALL_MS := 100           # gate stall before a reliable re-request
const REREQ_THROTTLE_MS := 50
const CRC_STRIKES := 3
const PRUNE_BEHIND := 120       # keep this many frames behind the gate
const MAX_AHEAD := 10           # rollback: speculation cap past the confirmed frame
const TRANSFER_LEAD := 8        # frames ahead a port-ownership handoff is scheduled
const DISK_LEAD := 8            # frames ahead a disc eject/swap is scheduled
const LINK_LEAD := 8            # frames ahead a link plug/pull is scheduled
## Ports per machine, and the stride of a global port index. A session over a
## cabled pair has two machines' pads in one frame, so a port is identified by
## machine * PORTS_PER_MACHINE + port rather than by port alone.
const PORTS_PER_MACHINE := 4

signal desync_detected(peer_id: int, frame: int)
signal session_stopped(reason: String)

var _nm: Node = null

# Injectable seams for probes (else resolved from ObjectSync / RetroSystem).
var system_override: Object = null
## net_id -> machine, for a probe driving a session over more than one machine.
## system_override cannot express a group: it answers every id with one object.
var systems_override: Dictionary = {}

# Session parameters (identical on every peer after cold start).
## Every machine in this session, and their Libretro nodes, in the same order.
## Index 0 is the machine netplay was started on; the rest are whatever is
## cabled to it.
##
## A link cable never crosses the network — LinkCoordinator is a process-wide
## singleton joining two cores in the SAME process — so a cabled pair is not two
## players' machines talking, it is ONE bus that every peer replicates. Leaving
## the far machine out of the session left a client's gated core on a bus whose
## other end never published, and the coordinator waits for a peer that is
## behind rather than guessing, with deliberately no timeout.
var _group: Array = []
var _libs: Array = []
## _group[0] and _libs[0], kept as their own names because most of this file
## deals with the machine the session is anchored to: the frame clock, the
## savestate, the disc schedule and the rollback records are all its.
var _system: Object = null
var _lib: Object = null
var _group_net_ids: PackedInt32Array = PackedInt32Array()
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

# Cold start is asynchronous. net_start_core hands back the node and returns;
# the core loads on its own thread and may still fail. Until it reports an
# identity there is nothing to be ready WITH, so the session waits here first:
# "host" (broadcast _np_start once we know what we are running), "cold" (a
# client answering a cold start) or "join" (a late joiner about to load a
# state). Empty when not waiting.
var _await_core := ""
var _await_deadline := 0
var _await_sram := PackedByteArray()     # host: bytes to ship with _np_start
var _await_states: Array = []            # joiner: one state per machine, once the cores are up
var _await_state_frame := 0
# Host: states being collected for a late joiner, one slot per machine, and the
# frame the anchor machine was at when it took its own.
var _join_states: Array = []
var _join_frame := -1
var _join_loaded := 0

# Core build identity (library_name/library_version/api_version/serialize_size).
# The host's is the reference every peer must match; a peer's own is what it
# reports. This is the ONLY identity that survives cross-platform play: a
# Windows player and a Quest player never hold the same core file, so a hash of
# the binary would refuse every legitimate session and catch nothing.
var _host_identity: Dictionary = {}
var _local_identity: Dictionary = {}

# Aux input (sensor tilt + touch pointer, port 0) — part of the deterministic
# frame payload: [flags, sx, sy, sz (milli-g), px, py, pressed]. flags bit0 =
# sensor valid, bit1 = pointer valid. Only the port-0 owner supplies it.
const AUX_INTS := 7
var _local_aux: Array = [0, 0, 0, 0, 0, 0, 0]
var _local_aux_by_frame: Dictionary = {}   # frame -> Array(7) (redundant resend)
var _recv_aux: Dictionary = {}             # host: frame -> Array(7)
# Ports whose scheduled values are per-frame DELTAS (mouse dx/dy): zeroed after
# the first scheduled frame consumes them, unlike held joypad state.
var _drain_ports: Dictionary = {}          # port -> true
# Keyboard events (RetroKeyboard / desktop typing): queued transitions, packed
# up to KEY_SLOTS per scheduled frame as [keycode|down<<16, character] pairs.
# Like aux, supplied by the port-0 owner. Overflow rolls to the next frame.
const KEY_SLOTS := 4
## Wire sizes of the two fixed blocks that follow a frame's ports. Named
## because every reader has to check it has them before unpacking, and the
## three call sites used to carry the number by hand: they said 15 where
## _put_aux writes 13, so every reader demanded two bytes more than the writer
## produced and bailed out on the LAST frame of every packet. The redundancy
## window hid it for streamed frames and could not hide it for a re-request,
## which sends one frame and had it dropped every time.
const AUX_BYTES := 13
const KEY_BYTES := KEY_SLOTS * 4
var _local_keys: Array = []                  # pending [packed, char] pairs
var _local_keys_by_frame: Dictionary = {}    # frame -> Array (redundant resend)
var _recv_keys: Dictionary = {}              # host: frame -> Array

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
	return _running or _join_paused or not _await_core.is_empty() or not _ready_peers.is_empty()


# ── Cold start (host) ─────────────────────────────────────────────────────────

## Host entry point. `owners` maps participating port -> peer_id. Verifies the
## core is netplay-capable, then drives the cold-start handshake on all peers.
## rollback: 1 = force on, 0 = force lockstep, -1 = auto (core capability).
func start_host(system: Object, core: String, rom_md5: String, owners: Dictionary,
		delay: int, rollback := -1) -> bool:
	if not _nm.is_host():
		return false
	# A cold start is no longer instantaneous — the host's own core has to come
	# up before anyone is invited — so a second press of the power button lands
	# in the middle of the first one's wait. Refuse rather than restart.
	if is_active():
		return false
	if not NetplayCores.is_capable(core):
		push_warning("[Netplay] core '%s' is not determinism-verified; refusing to start" % core)
		return false
	_set_group(_resolve_group(system))
	_core = core
	_rom_md5 = rom_md5
	_options = NetplayCores.forced_options(core)
	_delay = clampi(delay, 1, 8)
	_rollback = NetplayCores.rollback_capable(core) if rollback < 0 else rollback == 1
	if _rollback and (_group.size() > 1 or _is_linked(system)):
		push_warning("[Netplay] machine is on a link bus; starting in lockstep, not rollback")
		_rollback = false
	_set_owners(owners)
	_ready_peers.clear()
	_host_identity.clear()
	_local_identity.clear()

	# SRAM: every peer must boot with IDENTICAL battery-save content or the
	# cores desync at frame 0. Ship the host's .srm bytes; the host itself
	# boots from the same bytes but keeps its real file for persistence.
	_await_sram = PackedByteArray()
	if system.has_method("net_sram_file_bytes"):
		_await_sram = system.net_sram_file_bytes()

	# The host's core comes up FIRST, before anyone is invited. Until it does,
	# the host cannot say what build it is running, and that is the one thing
	# every peer has to match. _np_start goes out from _poll_core_ready.
	if not _cold_start_local(0):
		push_warning("[Netplay] host could not start core '%s'" % _core)
		_stop_local("host could not start its core")
		return false
	_begin_await("host")
	return true


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_start(group_net_ids: PackedInt32Array, core: String, rom_md5: String,
		options: Dictionary, owners: Dictionary, delay: int, start_frame: int,
		rollback := false, sram := PackedByteArray(), host_identity := {}) -> void:
	_core = core
	_rom_md5 = rom_md5
	_options = options
	_delay = delay
	_rollback = rollback
	_host_identity = host_identity.duplicate()
	_local_identity.clear()
	_set_owners(owners)
	# Every machine on the bus, not just the one the host anchored to: a peer
	# missing the far end would run half a cable.
	if not _adopt_group(group_net_ids):
		_np_ready_fail.rpc_id(1, "cannot resolve every machine in the game")
		return
	# ROM policy: verify-by-hash only (never transferred). A peer without a
	# byte-identical local copy can't join the lockstep game.
	if _system.has_method("net_resolve_rom") and not _system.net_resolve_rom(rom_md5):
		_np_ready_fail.rpc_id(1, "missing ROM (md5 %s…)" % rom_md5.left(8))
		return
	# Boot with the host's SRAM, and never persist someone else's game locally.
	if _system.has_method("net_set_sram"):
		_system.net_set_sram("", sram)
	if not _cold_start_local(start_frame):
		_np_ready_fail.rpc_id(1, "cannot start core '%s'" % core)
		return
	_begin_await("cold")


# ── The machine group ─────────────────────────────────────────────────────────

## How many machines this session covers. One normally; more when the machine
## netplay was started on is cabled to others.
func group_size() -> int:
	return _group.size()


## Which machine a global port index belongs to, and which of that machine's own
## ports it is.
static func machine_of_port(global_port: int) -> int:
	return global_port / PORTS_PER_MACHINE


static func port_on_machine(global_port: int) -> int:
	return global_port % PORTS_PER_MACHINE


## The whole bus `system` sits on, itself first, or just itself when it is not
## cabled to anything. Order matters and must be the same on every peer: the
## machine at index 0 owns the clock, exactly as the head lead decides offline.
func _resolve_group(system: Object) -> Array:
	if system != null and system.has_method("net_link_group"):
		var bus: Array = system.net_link_group()
		if bus.size() > 1:
			return bus.duplicate()
	return [system]


func _set_group(group: Array) -> void:
	_group = group
	_system = _group[0] if not _group.is_empty() else null
	_group_net_ids = PackedInt32Array()
	for machine: Object in _group:
		_group_net_ids.append(_resolve_net_id(machine))


## Client side: rebuild the host's group locally from its net ids. False when
## any machine is missing here, which has to fail the whole peer rather than
## quietly running a shorter bus.
func _adopt_group(net_ids: PackedInt32Array) -> bool:
	var group: Array = []
	for net_id in net_ids:
		var machine: Object = _resolve_system(net_id)
		if machine == null:
			push_warning("[Netplay] cannot resolve machine net_id %d" % net_id)
			return false
		group.append(machine)
	if group.is_empty():
		return false
	_group = group
	_system = group[0]
	_group_net_ids = net_ids
	return true


## The mask of `machine_index`'s OWN ports that this session drives, in that
## machine's local numbering — which is what the gate wants, since each core
## still only knows about its own four ports.
func _mask_for_machine(machine_index: int) -> int:
	var mask := 0
	for global_port: int in _owners:
		if machine_of_port(int(global_port)) == machine_index:
			mask |= 1 << port_on_machine(int(global_port))
	return mask


## Bring every machine in the group up under the netplay gate at `start_frame`.
## False when any of them refused outright (no core for this systemid, no
## cartridge, no television). A true here means "started", NOT "running" — see
## _begin_await.
func _cold_start_local(start_frame: int) -> bool:
	_reset_runtime(start_frame)
	_libs = []
	for i in range(_group.size()):
		var machine: Object = _group[i]
		# Rollback flags must be set before StartContent spins the emu thread up.
		# get_libretro_node() exists on every system implementation (incl. mocks).
		var pre_lib: Object = machine.get_libretro_node() if machine.has_method("get_libretro_node") else null
		if pre_lib != null and pre_lib.has_method("SetNetplayRollback"):
			var local_mask := 0
			for global_port: int in _local_ports:
				if machine_of_port(global_port) == i:
					local_mask |= 1 << port_on_machine(global_port)
			pre_lib.SetNetplayRollback(_rollback, local_mask, MAX_AHEAD)
		# net_start_core sets the gate (SetNetplayMode) BEFORE StartContent so
		# the core holds at the start frame until inputs post.
		#
		# The core NAME comes from the host, not from _resolve_core(). A machine
		# resolves its own default per systemid, and those defaults differ per
		# player and per platform — a core the buildbot ships for Windows may
		# not exist for Android at all. Two peers quietly running different
		# emulators is not a desync anyone can diagnose from the symptom.
		var lib: Object = machine.net_start_core(_core, _mask_for_machine(i),
			start_frame, _options)
		if lib == null:
			_libs = []
			return false
		_libs.append(lib)
		if lib.has_signal("netplay_crc"):
			var handler := _on_local_crc.bind(i)
			if not lib.netplay_crc.is_connected(handler):
				lib.netplay_crc.connect(handler)
	_lib = _libs[0]
	return true


# ── Waiting for the local core, and checking what came up ─────────────────────

## Begin waiting for the local core to report an identity. `kind` says what to
## do once it does: "host" broadcasts the invitation, "cold" answers one, "join"
## loads the state a late joiner was sent.
func _begin_await(kind: String) -> void:
	_await_core = kind
	_await_deadline = _now() + CORE_READY_MS


## The running core's build identity, or {} while it is still coming up. Doubles
## as the readiness test: the C++ side publishes it from the emulation thread
## the moment retro_load_game has succeeded, and clears it when content stops.
func _core_identity() -> Dictionary:
	if _libs.is_empty():
		return {}
	# EVERY machine, not just the anchor. Answering ready while the far end of
	# a cable is still loading is how a peer joins a bus it cannot serve.
	for lib: Object in _libs:
		if lib == null or not lib.has_method("GetCoreIdentity"):
			return {}
		if (lib.GetCoreIdentity() as Dictionary).is_empty():
			return {}
	return _libs[0].GetCoreIdentity()


func _poll_core_ready() -> void:
	var ident: Dictionary = _core_identity()
	if ident.is_empty():
		if _now() < _await_deadline:
			return
		var kind_late := _await_core
		_await_core = ""
		var why := "core '%s' did not come up" % _core
		if _nm.is_host() and kind_late == "host":
			push_warning("[Netplay] %s" % why)
			_stop_local(why)
		else:
			_np_ready_fail.rpc_id(1, why)
			_stop_local(why)
		return

	var kind := _await_core
	_await_core = ""
	_local_identity = ident

	if kind == "host":
		_host_identity = ident
		print("[Netplay] host core: %s" % identity_str(ident))
		_np_start.rpc(_group_net_ids, _core, _rom_md5, _options, _owners, _delay, 0,
			_rollback, _await_sram, ident)
		_await_sram = PackedByteArray()
		_mark_ready(1)
		return

	# Every client checks itself against the host's build before answering. Same
	# core name is not the same core: cross-platform peers take their builds from
	# four different nightly directories, cut at four different times.
	var bad := identity_mismatch(_host_identity, ident)
	if not bad.is_empty():
		push_warning("[Netplay] %s" % bad)
		_np_ready_fail.rpc_id(1, bad)
		_stop_local(bad)
		return

	if kind == "join":
		_join_loaded = 0
		for i in range(_libs.size()):
			var lib: Object = _libs[i]
			if lib == null or not lib.has_method("RequestLoadState"):
				continue
			if not lib.savestate_loaded.is_connected(_on_join_loaded):
				lib.savestate_loaded.connect(_on_join_loaded)
			var state: PackedByteArray = PackedByteArray()
			if i < _await_states.size():
				state = _await_states[i]
			lib.RequestLoadState(state, _await_state_frame)
		_await_states = []
		return

	_np_ready.rpc_id(1)


## Why `got` cannot play against `want`, or "" when it can. Ordered so the
## message names the most specific difference: which build, then whether a
## savestate can even cross between them, then the API they were built against.
static func identity_mismatch(want: Dictionary, got: Dictionary) -> String:
	if want.is_empty() or got.is_empty():
		return "core did not report a build identity"
	if str(want.get("library_name", "")) != str(got.get("library_name", "")) \
			or str(want.get("library_version", "")) != str(got.get("library_version", "")):
		return "core build mismatch: host runs %s, you run %s" % [
			identity_str(want), identity_str(got)]
	# A late join and every desync resync ship the host's serialized state for
	# this peer to load. Different sizes means that transfer cannot work, and
	# the symptom would be a failed join rather than anything naming the cause.
	#
	# 0 is "not measured yet", not "zero bytes". A core cannot always be asked
	# its savestate size before it has run a frame — Dolphin segfaults on the
	# question — and under the netplay gate no peer has run one yet at cold
	# start, because the gate is waiting for the readiness this check is part
	# of. So at cold start both sides are usually 0 and the version comparison
	# above carries the weight; by the time a resync ships a state, the peers
	# have been running frames and this is a real comparison.
	var want_size := int(want.get("serialize_size", 0))
	var got_size := int(got.get("serialize_size", 0))
	if want_size > 0 and got_size > 0 and want_size != got_size:
		return "savestate size mismatch: host %d bytes, you %d" % [want_size, got_size]
	if int(want.get("api_version", 0)) != int(got.get("api_version", 0)):
		return "libretro API mismatch: host %d, you %d" % [
			int(want.get("api_version", 0)), int(got.get("api_version", 0))]
	return ""


static func identity_str(ident: Dictionary) -> String:
	if ident.is_empty():
		return "(unknown)"
	return "%s %s" % [str(ident.get("library_name", "?")),
		str(ident.get("library_version", "?"))]


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
	# Cleared here rather than in _reset_runtime: the host's identity arrives in
	# _np_start, and a cold start reaches _reset_runtime AFTER that.
	_await_core = ""
	_await_sram = PackedByteArray()
	_await_states = []
	_join_states = []
	_join_frame = -1
	_join_loaded = 0
	_host_identity.clear()
	_local_identity.clear()
	for i in range(_libs.size()):
		var lib: Object = _libs[i]
		if lib == null:
			continue
		if lib.has_signal("netplay_crc"):
			var handler := _on_local_crc.bind(i)
			if lib.netplay_crc.is_connected(handler):
				lib.netplay_crc.disconnect(handler)
		if lib.has_method("SetNetplayRollback"):
			lib.SetNetplayRollback(false, 0, MAX_AHEAD)
	for machine: Object in _group:
		if machine != null and machine.has_method("net_stop_core"):
			machine.net_stop_core()
	_libs = []
	_group = []
	_group_net_ids = PackedInt32Array()
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
	_local_aux = [0, 0, 0, 0, 0, 0, 0]
	_local_aux_by_frame.clear()
	_recv_aux.clear()
	_drain_ports.clear()
	_local_keys.clear()
	_local_keys_by_frame.clear()
	_recv_keys.clear()
	_running = false
	_join_paused = false


# ── Input seam ────────────────────────────────────────────────────────────────

## Called from retro_controller for a port plugged into `system`. Returns true if
## netplay consumed the input (caller must NOT drive the core directly). Offline
## or a non-participating system → false (unchanged local behaviour).
func route(system: Object, port: int, m: Dictionary) -> bool:
	if not _running or system == null:
		return false
	var machine_index := _group.find(system)
	if machine_index < 0:
		return false
	port = machine_index * PORTS_PER_MACHINE + port
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
		# Delta devices (mouse): their values are per-frame quantities — mark
		# the port so _capture_local zeroes the deltas after one frame uses them.
		if m.get("drain", false):
			_drain_ports[port] = true
	# Participating port (local or remote-owned) is driven by the gate — swallow.
	return true


func _capture_local() -> Dictionary:
	var out := {}
	for port: int in _local_ports:
		var vals: Array = _pending_local_route.get(port, [0, 0, 0, 0, 0])
		out[port] = vals
		# Deltas are consumed by the first scheduled frame; later frames get
		# zero motion (buttons persist — they are held state).
		if _drain_ports.has(port):
			_pending_local_route[port] = [vals[0], 0, 0, 0, 0]
	return out


## Aux feeds from the game system (only meaningful on the port-0 owner).
func set_aux_sensor(system: Object, x_mg: int, y_mg: int, z_mg: int) -> void:
	if system != _system or not _local_ports.has(0):
		return
	_local_aux[0] = int(_local_aux[0]) | 1
	_local_aux[1] = x_mg
	_local_aux[2] = y_mg
	_local_aux[3] = z_mg


func set_aux_pointer(system: Object, px: int, py: int, pressed: bool) -> void:
	if system != _system or not _local_ports.has(0):
		return
	_local_aux[0] = int(_local_aux[0]) | 2
	_local_aux[4] = px
	_local_aux[5] = py
	_local_aux[6] = 1 if pressed else 0


## Queue a keyboard transition into the deterministic schedule. Returns true
## when consumed (a lockstep game is running for this system and this peer
## supplies the keyboard block).
func queue_key_event(system: Object, keycode: int, down: bool, character: int) -> bool:
	if not _running or _rollback or system != _system:
		return false
	if not _local_ports.has(0):
		# Participating game but another peer owns the keyboard feed — swallow
		# so the local core isn't driven directly (would desync).
		return true
	_local_keys.append([(keycode & 0xFFFF) | (65536 if down else 0), character])
	return true


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
	print("[Netplay] disc op %d armed @frame %d%s" %
		[op, frame, "" if path.is_empty() else " (" + path.get_file() + ")"])
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


# ── Plugging a link cable in, mid-game ────────────────────────────────────────
# Seating or pulling a link plug changes deterministic state on both cores, so
# it lands on ONE agreed frame everywhere, exactly like a disc swap. Applying it
# the instant a hand moves forks the session: LinkCoordinator says so itself —
# the one thing it cannot enforce is that Connect and Disconnect happen at the
# same emulated frame on every peer, and that it is the caller's job.
#
# `members` are indices into the group and `ports` their machine-local ports.
# op 1 = join those machines into one bus, head first; op 0 = drop the single
# named machine's port off it.

## Host: schedule a link change for this session's bus. Lockstep only, for the
## same reason a disc swap is: a rollback would have to re-run the join.
func schedule_link_op(system: Object, op: int, members: Array, ports: Array) -> void:
	if not _nm.is_host() or not _running or _rollback:
		return
	if _group.find(system) < 0:
		return
	if members.is_empty() or members.size() != ports.size():
		return
	for m: int in members:
		if int(m) < 0 or int(m) >= _group.size():
			return
	var frame := _complete_upto + _delay + LINK_LEAD
	var member_ids := PackedInt32Array()
	for m: int in members:
		member_ids.append(int(m))
	var port_ids := PackedInt32Array()
	for pt: int in ports:
		port_ids.append(int(pt))
	print("[Netplay] link op %d over machines %s @frame %d" % [op, str(member_ids), frame])
	_np_link.rpc(op, member_ids, port_ids, frame)
	_apply_link_op(op, member_ids, port_ids, frame)


## True when `machine` is one of the machines this session is running, which is
## what decides whether a cable seated on it is the session's business.
func covers(machine: Object) -> bool:
	return _running and _group.find(machine) >= 0


## The room's form of schedule_link_op: it knows machines and their link ports,
## not indices into a session it cannot see. `entries` are
## [{machine, port}, ...], head first, exactly as the cable walk produced them.
## Any machine outside the session aborts the whole op rather than joining a
## partial bus.
func schedule_link_for(op: int, entries: Array) -> void:
	if not _nm.is_host() or not _running:
		return
	var members: Array = []
	var ports: Array = []
	for entry: Dictionary in entries:
		var idx := _group.find(entry.get("machine"))
		if idx < 0:
			push_warning("[Netplay] link op touches a machine outside the session")
			return
		members.append(idx)
		ports.append(int(entry.get("port", 0)))
	schedule_link_op(_system, op, members, ports)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_link(op: int, members: PackedInt32Array, ports: PackedInt32Array, frame: int) -> void:
	_apply_link_op(op, members, ports, frame)


## Hand the op to the C++ gate, which applies it on the emulation thread
## strictly before running `frame` — the same path a netplay disc swap takes.
## Doing it from here instead would land it whenever the main thread got round
## to it, which is a different frame on every peer.
func _apply_link_op(op: int, members: PackedInt32Array, ports: PackedInt32Array,
		frame: int) -> void:
	if members.is_empty() or _libs.size() <= int(members[0]):
		return
	var head: Object = _libs[int(members[0])]
	if head == null or not head.has_method("ScheduleLinkOp"):
		return
	var others: Array = []
	for i in range(1, members.size()):
		var idx := int(members[i])
		if idx < 0 or idx >= _libs.size():
			return
		others.append(_libs[idx])
	head.ScheduleLinkOp(frame, op, others, ports)


# ── The link cable ────────────────────────────────────────────────────────────

## The bus ports a machine can be cabled on.
##
## Two of them, because a Game Boy Advance has ONE socket and the lead in it
## decides which conversation it is having: another handheld on a link cable, or
## a console on a GameCube lead. The frontend keeps a port per conversation and
## the cable picks which one it means.
const LINK_PORTS: Array[int] = [0, 1]


## Whether this machine is cabled to another one.
##
## Asked because rollback and a link cable cannot both be on. Rollback rewinds
## ONE core in isolation, and a cabled machine's state is only half a
## conversation: rewind one end and not the other and it replays a transfer the
## far end has already answered, after which the two disagree about the wire and
## never find out. It is not a desync the CRC checker can resync either, because
## both peers are wrong in the same way.
##
## So a linked machine starts in lockstep whatever the core is capable of. The
## real fix is group rollback, rewinding every core on the bus AND the
## coordinator to one frame, which is a project rather than a flag, and the plan
## records it as such.
##
## Asked of the CORE rather than of the room, deliberately: the cable is what
## joined them, but the core is what knows it is joined, and it keeps knowing
## across the restart a cold start puts it through.
func _is_linked(system: Object) -> bool:
	if system == null or not system.has_method("get_libretro_node"):
		return false
	var lib: Object = system.get_libretro_node()
	if lib == null or not lib.has_method("LinkPeerCount"):
		return false
	for port: int in LINK_PORTS:
		# Two, not one. A port with only this machine on it is a socket with a
		# lead hanging out of it, which is a cable nobody is on the far end of.
		if int(lib.LinkPeerCount(port)) >= 2:
			return true
	return false


# ── Per-frame drive ───────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _await_core.is_empty():
		_poll_core_ready()
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
		if _local_ports.has(0):
			_local_aux_by_frame[_sched_frame] = _local_aux.duplicate()
			var kv: Array = []
			while not _local_keys.is_empty() and kv.size() < KEY_SLOTS * 2:
				var ev: Array = _local_keys.pop_front()
				kv.append(int(ev[0]))
				kv.append(int(ev[1]))
			_local_keys_by_frame[_sched_frame] = kv
		if _nm.is_host():
			for port: int in inp:
				_recv_put(_sched_frame, port, inp[port])
			if _local_ports.has(0):
				_recv_aux[_sched_frame] = _local_aux.duplicate()
				_recv_keys[_sched_frame] = _local_keys_by_frame[_sched_frame]
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
		_put_aux(buf, _local_aux_by_frame.get(f, [0, 0, 0, 0, 0, 0, 0]))
		_put_keys(buf, _local_keys_by_frame.get(f, []))
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
		if buf.get_available_bytes() < AUX_BYTES + KEY_BYTES:
			return
		var aux := _get_aux(buf)
		var keys := _get_keys(buf)
		# Aux (tilt/touch) + key events ride with the port-0 owner packets.
		if _owner_for_frame(0, f) == sender and f > _complete_upto:
			_recv_aux[f] = aux
			_recv_keys[f] = keys


func _host_assemble() -> void:
	var changed := false
	while true:
		var f := _complete_upto + 1
		if not _frame_ready(f):
			break
		_frames[f] = _flat_from_frame(_recv.get(f, {}),
			_recv_aux.get(f, [0, 0, 0, 0, 0, 0, 0]), _recv_keys.get(f, []))
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
		_put_aux(buf, _aux_of(flat))
		var kflat: Array = []
		for i in range(KEY_SLOTS * 2):
			kflat.append(flat[_port_ints() + AUX_INTS + i])
		_put_keys(buf, kflat)
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
		var need := 4 + _all_ports.size() * 10 + AUX_BYTES + KEY_BYTES
		if buf.get_available_bytes() < need:
			return
		var f := int(buf.get_u32())
		var flat := PackedInt32Array()
		flat.resize(_port_ints() + AUX_INTS + KEY_SLOTS * 2)
		for port in _all_ports:
			var base := port * 5
			flat[base] = buf.get_u16()
			flat[base + 1] = buf.get_16(); flat[base + 2] = buf.get_16()
			flat[base + 3] = buf.get_16(); flat[base + 4] = buf.get_16()
		var aux := _get_aux(buf)
		for i in range(AUX_INTS):
			flat[_port_ints() + i] = int(aux[i])
		var keys := _get_keys(buf)
		for i in range(KEY_SLOTS * 2):
			flat[_port_ints() + AUX_INTS + i] = int(keys[i])
		if f >= _next_post and not _frames.has(f):
			_frames[f] = flat


func _drain_to_core() -> void:
	var progressed := false
	while _frames.has(_next_post):
		var flat: PackedInt32Array = _frames[_next_post]
		for i in range(_libs.size()):
			_libs[i].PostNetplayInputs(_next_post, _slice_for_machine(flat, i))
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
				var owner_peer := _owner_for_frame(port, f)
				if owner_peer != 1 and owner_peer > 0 and not _spectators.has(owner_peer):
					_np_input_req.rpc_id(owner_peer, f)
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
		_put_aux(buf, _aux_of(flat))
		var kflat: Array = []
		for i in range(KEY_SLOTS * 2):
			kflat.append(flat[_port_ints() + AUX_INTS + i])
		_put_keys(buf, kflat)
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
	_put_aux(buf, _local_aux_by_frame.get(frame, [0, 0, 0, 0, 0, 0, 0]))
	_put_keys(buf, _local_keys_by_frame.get(frame, []))
	_np_input.rpc_id(1, buf.data_array)


# ── Late join (host stalls, ships a savestate) ────────────────────────────────

## Called by NetworkManager when a peer registers mid-session.
func on_peer_joined(peer_id: int) -> void:
	if not _nm.is_host() or not _running:
		return
	_joining[peer_id] = true
	_ready_peers.erase(peer_id)
	_join_paused = true      # freeze the pipeline — everyone stalls at the gate
	# A state per machine: a joiner arriving into a cabled pair needs both ends
	# of the bus, or it resumes half a conversation.
	_join_states.clear()
	_join_states.resize(_libs.size())
	_join_frame = -1
	for i in range(_libs.size()):
		var lib: Object = _libs[i]
		if lib == null or not lib.has_method("RequestSaveState"):
			continue
		var handler := _on_savestate_for_join.bind(i)
		if not lib.savestate_ready.is_connected(handler):
			lib.savestate_ready.connect(handler)
		lib.RequestSaveState()


func _on_savestate_for_join(data: PackedByteArray, frame: int, machine_index: int) -> void:
	var lib: Object = _libs[machine_index] if machine_index < _libs.size() else null
	if lib != null:
		var handler := _on_savestate_for_join.bind(machine_index)
		if lib.savestate_ready.is_connected(handler):
			lib.savestate_ready.disconnect(handler)
	if data.is_empty():
		push_warning("[Netplay] late-join savestate failed; core lacks serialization")
		_join_states.clear()
		_join_paused = false
		return
	if machine_index < _join_states.size():
		_join_states[machine_index] = data
	# The joiner resumes at ONE frame, and the anchor machine's is the session's.
	if machine_index == 0:
		_join_frame = frame
	for state: Variant in _join_states:
		if state == null:
			return          # still collecting the rest of the bus
	if _join_frame < 0:
		return
	for peer_id: int in _joining.keys():
		_np_savestate.rpc_id(peer_id, _group_net_ids, _core, _rom_md5, _options,
			_owners, _delay, _join_states.duplicate(), _join_frame, _rollback,
			_host_identity)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_savestate(group_net_ids: PackedInt32Array, core: String, rom_md5: String,
		options: Dictionary, owners: Dictionary, delay: int, states: Array, frame: int,
		rollback := false, host_identity := {}) -> void:
	_core = core
	_rom_md5 = rom_md5
	_options = options
	_delay = delay
	_rollback = rollback
	_host_identity = host_identity.duplicate()
	_local_identity.clear()
	_set_owners(owners)
	if not _adopt_group(group_net_ids):
		_np_ready_fail.rpc_id(1, "cannot resolve every machine in the game")
		return
	if _system.has_method("net_resolve_rom") and not _system.net_resolve_rom(rom_md5):
		_np_ready_fail.rpc_id(1, "missing ROM (md5 %s…)" % rom_md5.left(8))
		return
	# Late joiner: SRAM arrives inside the serialized state; don't persist.
	if _system.has_method("net_set_sram"):
		_system.net_set_sram("", PackedByteArray())
	if not _cold_start_local(frame):
		_np_ready_fail.rpc_id(1, "cannot start core '%s'" % core)
		return
	# The state cannot be loaded into a core that has not finished loading its
	# content, and a state from a different build cannot be loaded at all — so
	# both the wait and the identity check come first, and the load happens in
	# _poll_core_ready.
	_await_states = states.duplicate()
	_await_state_frame = frame
	_begin_await("join")


## One of these per machine. The joiner is only in the game once EVERY core on
## the bus has taken its state: resuming after the first would put a fresh far
## machine on a wire whose near end is an hour into a save.
func _on_join_loaded(ok: bool) -> void:
	if not ok:
		push_warning("[Netplay] late-join load failed")
		_disconnect_join_loaded()
		_np_ready_fail.rpc_id(1, "savestate load failed")
		return
	_join_loaded += 1
	if _join_loaded < _libs.size():
		return
	_disconnect_join_loaded()
	_begin_running()
	_np_ready.rpc_id(1)


func _disconnect_join_loaded() -> void:
	for lib: Object in _libs:
		if lib != null and lib.has_signal("savestate_loaded") \
				and lib.savestate_loaded.is_connected(_on_join_loaded):
			lib.savestate_loaded.disconnect(_on_join_loaded)


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

## Each machine's core emits its own CRC stream, so the machine index is bound
## into the handler at connect time. A cabled pair that diverged on the far
## machine only would otherwise be compared against the near one's numbers and
## look like agreement.
func _on_local_crc(frame: int, crc: int, machine_index: int) -> void:
	var self_id := _self_id()
	_crc_record(frame, machine_index, self_id, crc)
	if _nm.is_host():
		_check_crc(frame, machine_index)
	else:
		_np_crc.rpc_id(1, frame, machine_index, crc)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_crc(frame: int, machine_index: int, crc: int) -> void:
	if not _nm.is_host():
		return
	_crc_record(frame, machine_index, multiplayer.get_remote_sender_id(), crc)
	_check_crc(frame, machine_index)


## frame -> machine index -> peer -> crc. Keyed by frame at the top so _prune
## stays a single comparison against the gate.
func _crc_record(frame: int, machine_index: int, peer_id: int, crc: int) -> void:
	if not _crc_table.has(frame):
		_crc_table[frame] = {}
	var by_machine: Dictionary = _crc_table[frame]
	if not by_machine.has(machine_index):
		by_machine[machine_index] = {}
	by_machine[machine_index][peer_id] = crc


func _check_crc(frame: int, machine_index: int) -> void:
	var t: Dictionary = (_crc_table.get(frame, {}) as Dictionary).get(machine_index, {})
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


## Ints of port data in an assembled frame: every machine in the group gets
## PORTS_PER_MACHINE x 5, and aux and keys follow all of them.
func _port_ints() -> int:
	return maxi(_group.size(), 1) * PORTS_PER_MACHINE * 5


## Assembled frame: one 5-int block per GLOBAL port, then aux
## [flags, sx, sy, sz, px, py, pressed], then up to KEY_SLOTS key events x 2
## ints [keycode|down<<16, character].
##
## Aux and keys are the group's, not each machine's: a tilt or a keystroke comes
## from one player's hands and there is one set of them per session. They ride
## with the port-0 owner of the FIRST machine and every core is handed the same
## block, which is what the gate has always been given.
func _flat_from_frame(pm: Dictionary, aux: Array, keys: Array) -> PackedInt32Array:
	var port_ints := _port_ints()
	var flat := PackedInt32Array()
	flat.resize(port_ints + AUX_INTS + KEY_SLOTS * 2)
	for port: int in pm:
		var v: Array = pm[port]
		var base := int(port) * 5
		if base + 5 > port_ints:
			continue
		for i in range(5):
			flat[base + i] = int(v[i])
	for i in range(AUX_INTS):
		flat[port_ints + i] = int(aux[i])
	for i in range(mini(keys.size(), KEY_SLOTS * 2)):
		flat[port_ints + AUX_INTS + i] = int(keys[i])
	return flat


## One machine's share of an assembled frame, in the shape a core expects:
## its own four ports, then the group's aux and key blocks. The C++ gate has
## never known about anything but its own machine and does not need to.
func _slice_for_machine(flat: PackedInt32Array, machine_index: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(PORTS_PER_MACHINE * 5 + AUX_INTS + KEY_SLOTS * 2)
	var base := machine_index * PORTS_PER_MACHINE * 5
	for i in range(PORTS_PER_MACHINE * 5):
		out[i] = flat[base + i] if base + i < flat.size() else 0
	var tail := _port_ints()
	for i in range(AUX_INTS + KEY_SLOTS * 2):
		out[PORTS_PER_MACHINE * 5 + i] = flat[tail + i] if tail + i < flat.size() else 0
	return out


## The group's aux block out of an assembled frame.
func _aux_of(flat: PackedInt32Array) -> Array:
	var base := _port_ints()
	var out: Array = []
	for i in range(AUX_INTS):
		out.append(flat[base + i] if base + i < flat.size() else 0)
	return out


func _put_port(buf: StreamPeerBuffer, port: int, v: Array) -> void:
	buf.put_u8(port)
	buf.put_u16(int(v[0]) & 0xFFFF)
	buf.put_16(int(v[1])); buf.put_16(int(v[2]))
	buf.put_16(int(v[3])); buf.put_16(int(v[4]))


func _get_port(buf: StreamPeerBuffer) -> Array:
	return [buf.get_u16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16()]


## Aux wire block (AUX_BYTES): u8 flags, 3x s16 sensor milli-g, 2x s16 pointer,
## u8 pressed, u8 reserved.
func _put_aux(buf: StreamPeerBuffer, aux: Array) -> void:
	buf.put_u8(int(aux[0]) & 0xFF)
	buf.put_16(int(aux[1])); buf.put_16(int(aux[2])); buf.put_16(int(aux[3]))
	buf.put_16(int(aux[4])); buf.put_16(int(aux[5]))
	buf.put_u8(1 if int(aux[6]) != 0 else 0)
	buf.put_u8(0)


func _get_aux(buf: StreamPeerBuffer) -> Array:
	var flags := buf.get_u8()
	var sx := buf.get_16()
	var sy := buf.get_16()
	var sz := buf.get_16()
	var px := buf.get_16()
	var py := buf.get_16()
	var pressed := buf.get_u8()
	buf.get_u8()
	return [flags, sx, sy, sz, px, py, pressed]


## Key-event wire block (KEY_SLOTS x 4 bytes): u16 keycode|down<<15... packed
## as u16 (keycode | down<<15) + u16 character per slot; keycode 0 = empty.
func _put_keys(buf: StreamPeerBuffer, kv: Array) -> void:
	for slot in range(KEY_SLOTS):
		var packed := 0
		var ch := 0
		if slot * 2 + 1 < kv.size() or slot * 2 < kv.size():
			var p := int(kv[slot * 2]) if slot * 2 < kv.size() else 0
			ch = int(kv[slot * 2 + 1]) if slot * 2 + 1 < kv.size() else 0
			packed = (p & 0x7FFF) | (0x8000 if (p & 65536) != 0 else 0)
		buf.put_u16(packed)
		buf.put_u16(ch & 0xFFFF)


func _get_keys(buf: StreamPeerBuffer) -> Array:
	var out: Array = []
	for _slot in range(KEY_SLOTS):
		var packed := buf.get_u16()
		var ch := buf.get_u16()
		var keycode := packed & 0x7FFF
		var down := (packed & 0x8000) != 0
		out.append(keycode | (65536 if down else 0))
		out.append(ch)
	return out


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
	for f: int in _local_aux_by_frame.keys():
		if f < floor_frame:
			_local_aux_by_frame.erase(f)
	for f: int in _recv_aux.keys():
		if f < floor_frame:
			_recv_aux.erase(f)
	for f: int in _local_keys_by_frame.keys():
		if f < floor_frame:
			_local_keys_by_frame.erase(f)
	for f: int in _recv_keys.keys():
		if f < floor_frame:
			_recv_keys.erase(f)


func _self_id() -> int:
	if multiplayer != null and multiplayer.multiplayer_peer != null:
		return multiplayer.get_unique_id()
	return 1


func _now() -> int:
	return Time.get_ticks_msec()


func _resolve_net_id(system: Object) -> int:
	for net_id: int in systems_override:
		if systems_override[net_id] == system:
			return int(net_id)
	if _nm != null and _nm._object_sync != null and _nm._object_sync.has_method("id_of"):
		return _nm._object_sync.id_of(system)
	return -1


func _resolve_system(net_id: int) -> Object:
	if systems_override.has(net_id):
		return systems_override[net_id]
	if system_override != null:
		return system_override
	if _nm != null and _nm._object_sync != null and _nm._object_sync.has_method("node_for_id"):
		return _nm._object_sync.node_for_id(net_id)
	return null
