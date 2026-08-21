## NetplaySession — deterministic delay-based lockstep netplay (multiplayer M4b).
##
## Fixed-path child of NetworkManager ("Netplay") so RPC node paths match on
## every peer. Every peer runs the same per-machine core+ROM set locally; the
## only continuous traffic is one input frame per participating port. The C++ side
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
const RESET_LEAD := 8           # frames ahead a front-panel reset is scheduled
const LINK_LEAD := 8            # frames ahead a link plug/pull is scheduled
const OP_ACK_TIMEOUT_MS := 5000 # reliable control op accepted by every peer
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
# One launch description per machine: {core, rom_md5, options, sram}.  A linked
# session can be heterogeneous (GameCube + GBA), and even two identical
# consoles normally carry different cartridges and battery saves.
var _machine_specs: Array = []
var _core := ""
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
var _await_states: Array = []            # joiner: one state per machine, once the cores are up
var _await_state_frame := 0
# Host: states being collected for a late joiner, one slot per machine, and the
# frame the anchor machine was at when it took its own.
var _join_states: Array = []
var _join_frame := -1
var _join_loaded := 0
var _join_capture_pending := false
var _join_capture_frame := -1

# Core build identity (library_name/library_version/api_version/serialize_size).
# The host's is the reference every peer must match; a peer's own is what it
# reports. This is the ONLY identity that survives cross-platform play: a
# Windows player and a Quest player never hold the same core file, so a hash of
# the binary would refuse every legitimate session and catch nothing.
var _host_identities: Array = []
var _local_identities: Array = []

# Aux input is per controller port: two accelerometers, two gyroscopes and four
# pointer/IR contacts. Layout is flags, accel[2]*xyz, gyro[2]*xyz, pointer[4]*
# {x,y,pressed}. Flags bits 0..1 = accel, 2..3 = gyro, 4..7 = pointer valid.
# Values are milli-g / centi-radians-per-second / signed libretro coordinates.
const AUX_SENSOR_COUNT := 2
const AUX_POINTER_COUNT := 4
const AUX_INTS_PER_PORT := 25
const AUX_INTS := PORTS_PER_MACHINE * AUX_INTS_PER_PORT
var _local_aux: Dictionary = {}             # global port -> Array(25)
var _local_aux_by_frame: Dictionary = {}    # frame -> {global port -> Array(25)}
var _recv_aux: Dictionary = {}              # host: frame -> {global port -> Array(25)}
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
const AUX_BYTES_PER_PORT := 45
const AUX_BYTES := PORTS_PER_MACHINE * AUX_BYTES_PER_PORT
const KEY_BYTES := KEY_SLOTS * 4
var _local_keys: Dictionary = {}             # machine -> pending [packed, char] pairs
var _local_keys_by_frame: Dictionary = {}    # frame -> {machine -> Array}
var _recv_keys: Dictionary = {}              # host: frame -> {machine -> Array}

# Scheduling / assembly.
var _sched_frame := 0                    # next frame to schedule local input for
var _next_post := 0                      # next frame to feed the local core
var _complete_upto := -1                 # host: highest contiguous assembled frame
var _pending_local_route: Dictionary = {}  # port -> [btn,alx,aly,arx,ary] (this visual frame)
var _local_inputs: Dictionary = {}       # frame -> {port -> Array(5)} (for redundant resend)
var _recv: Dictionary = {}               # host: frame -> {port -> Array(5)}
var _frames: Dictionary = {}             # frame -> PackedInt32Array(20), ready to post
# Link operations keyed by their agreed frame.  They are applied on the main
# thread immediately before that frame's inputs are released to ANY core.  At
# that point every emulation thread is still gated below the boundary, which is
# the only way to keep every core on a local bus on the same topology.
var _link_ops: Dictionary = {}           # frame -> Array[{op,members,ports}]
var _link_serial := 0
## Host only: serial -> peers that have not yet queued the reliable operation.
## Assembly pauses until each participant acknowledges, so frame traffic cannot
## overtake a topology change sent on another ENet channel.
var _link_waiting: Dictionary = {}
var _link_deadlines: Dictionary = {}
var _disc_serial := 0
## Disc changes travel on the reliable control channel while completed input
## frames use a different channel. Pause assembly until every participant has
## armed the native frame schedule, or frame traffic can overtake the swap.
var _disc_waiting: Dictionary = {}
var _disc_deadlines: Dictionary = {}
var _reset_serial := 0
## Reset changes deterministic core state just like a disc swap. Assembly waits
## until every peer has armed the native reset at the same future frame.
var _reset_waiting: Dictionary = {}
var _reset_deadlines: Dictionary = {}
var _deferred_joiners: Dictionary = {}

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
	_set_group(_resolve_group(system))
	if not _build_machine_specs(core, rom_md5):
		_group = []
		_system = null
		return false
	_core = str(_machine_specs[0]["core"])
	print("[Netplay] preparing %d machine(s): %s" % [
		_machine_specs.size(), str(_spec_summaries(_machine_specs))])
	_delay = clampi(delay, 1, 8)
	_rollback = NetplayCores.rollback_capable(core) if rollback < 0 else rollback == 1
	if _rollback and (_group.size() > 1 or _is_linked(system)):
		push_warning("[Netplay] machine is on a link bus; starting in lockstep, not rollback")
		_rollback = false
	if _rollback and _requires_lockstep_input():
		push_warning("[Netplay] movable or sensor peripheral requires lockstep; disabling rollback")
		_rollback = false
	_set_owners(owners)
	_ready_peers.clear()
	_host_identities.clear()
	_local_identities.clear()

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
func _np_start(group_net_ids: PackedInt32Array, machine_specs: Array,
		owners: Dictionary, delay: int, start_frame: int, rollback := false,
		host_identities: Array = []) -> void:
	_machine_specs = machine_specs.duplicate(true)
	_core = str(_machine_specs[0].get("core", "")) if not _machine_specs.is_empty() else ""
	_delay = delay
	_rollback = rollback
	_host_identities = host_identities.duplicate(true)
	_local_identities.clear()
	_set_owners(owners)
	# Every machine on the bus, not just the one the host anchored to: a peer
	# missing the far end would run half a cable.
	if not _adopt_group(group_net_ids):
		_np_ready_fail.rpc_id(1, "cannot resolve every machine in the game")
		return
	if not _prepare_local_media():
		_np_ready_fail.rpc_id(1, "missing ROM for one of the linked machines")
		return
	if not _cold_start_local(start_frame):
		_np_ready_fail.rpc_id(1, "cannot start one of the linked cores")
		_stop_local("cannot start one of the linked cores")
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


## Rollback can change only fixed, native-fed port state safely. A handheld's
## own motion sensors and any pickable room peripheral need the lockstep frame
## scheduler: it carries their aux data and can transfer ownership as hands move.
func _requires_lockstep_input() -> bool:
	for machine: Object in _group:
		if machine == null:
			continue
		if "_model" in machine:
			var model: Variant = machine.get("_model")
			if model != null and model.has_method("is_handheld") and model.is_handheld():
				return true
		if "_port_controllers" in machine:
			var controllers: Array = machine.get("_port_controllers")
			for controller: Variant in controllers:
				if controller != null and is_instance_valid(controller) \
						and controller.has_method("is_picked_up"):
					return true
	return false


## Capture exactly what every machine is running.  The anchor's values are
## supplied by the power-button caller; every other machine owns its own core,
## cartridge and SRAM and must not inherit the anchor's by accident.
func _build_machine_specs(anchor_core: String, anchor_rom_md5: String) -> bool:
	_machine_specs.clear()
	for i in range(_group.size()):
		var machine: Object = _group[i]
		var core := anchor_core
		var rom_md5 := anchor_rom_md5
		if i > 0:
			if machine != null and machine.has_method("resolve_core_name"):
				core = str(machine.resolve_core_name())
			if machine != null and machine.has_method("net_rom_md5"):
				rom_md5 = str(machine.net_rom_md5())
		if not NetplayCores.is_capable(core):
			push_warning("[Netplay] core '%s' is not determinism-verified; refusing to start" % core)
			_machine_specs.clear()
			return false
		if rom_md5.is_empty():
			push_warning("[Netplay] linked machine %d has no ROM hash" % i)
			_machine_specs.clear()
			return false
		var sram := PackedByteArray()
		if machine != null and machine.has_method("net_sram_file_bytes"):
			sram = machine.net_sram_file_bytes()
		_machine_specs.append({
			"core": core,
			"rom_md5": rom_md5,
			"options": NetplayCores.forced_options(core),
			"sram": sram,
		})
	return not _machine_specs.is_empty()


## Resolve and seed every local machine from the host's corresponding launch
## description.  ROMs remain verify-only; only SRAM bytes cross the wire.
func _prepare_local_media() -> bool:
	if _machine_specs.size() != _group.size():
		return false
	for i in range(_group.size()):
		var machine: Object = _group[i]
		var spec: Dictionary = _machine_specs[i]
		var md5 := str(spec.get("rom_md5", ""))
		if machine != null and machine.has_method("net_resolve_rom") \
				and not machine.net_resolve_rom(md5):
			push_warning("[Netplay] machine %d has no ROM matching md5 %s…" % [i, md5.left(8)])
			return false
		if machine != null and machine.has_method("net_set_sram"):
			machine.net_set_sram("", spec.get("sram", PackedByteArray()))
		print("[Netplay] machine %d media verified (core=%s rom=%s…)" % [
			i, str(spec.get("core", "")), md5.left(8)])
	return true


static func _spec_summaries(specs: Array) -> Array[String]:
	var out: Array[String] = []
	for spec: Dictionary in specs:
		out.append("%s/%s…" % [str(spec.get("core", "?")),
			str(spec.get("rom_md5", "")).left(8)])
	return out


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
		if i >= _machine_specs.size():
			_libs = []
			return false
		var spec: Dictionary = _machine_specs[i]
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
		var lib: Object = machine.net_start_core(str(spec.get("core", "")),
			_mask_for_machine(i), start_frame, spec.get("options", {}))
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
func _core_identities() -> Array:
	if _libs.is_empty():
		return []
	# EVERY machine, not just the anchor. Answering ready while the far end of
	# a cable is still loading is how a peer joins a bus it cannot serve.
	var identities: Array = []
	for lib: Object in _libs:
		if lib == null or not lib.has_method("GetCoreIdentity"):
			return []
		var identity: Dictionary = lib.GetCoreIdentity()
		if identity.is_empty():
			return []
		identities.append(identity)
	return identities


func _poll_core_ready() -> void:
	var identities := _core_identities()
	if identities.is_empty():
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
	_local_identities = identities
	# Restarting a core drops every LinkCoordinator endpoint it owned, while the
	# physical plugs remain seated. Re-resolve those cables now that every core
	# is attached again and before frame zero is released.
	if _group.size() > 1 and _system != null \
			and _system.has_method("net_refresh_link_cables"):
		_system.net_refresh_link_cables()
		print("[Netplay] restored the physical link topology after core restart")

	if kind == "host":
		_host_identities = identities.duplicate(true)
		print("[Netplay] host cores: %s" % str(_identity_strings(identities)))
		_np_start.rpc(_group_net_ids, _machine_specs, _owners, _delay, 0,
			_rollback, _host_identities)
		_mark_ready(1)
		return

	# Every client checks itself against the host's build before answering. Same
	# core name is not the same core: cross-platform peers take their builds from
	# four different nightly directories, cut at four different times.
	if _host_identities.size() != identities.size():
		var count_bad := "linked core count mismatch: host %d, you %d" % [
			_host_identities.size(), identities.size()]
		push_warning("[Netplay] %s" % count_bad)
		_np_ready_fail.rpc_id(1, count_bad)
		_stop_local(count_bad)
		return
	for i in range(identities.size()):
		var bad := identity_mismatch(_host_identities[i], identities[i])
		if not bad.is_empty():
			bad = "machine %d: %s" % [i, bad]
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


static func _identity_strings(identities: Array) -> Array[String]:
	var out: Array[String] = []
	for identity: Dictionary in identities:
		out.append(identity_str(identity))
	return out


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
	# Save/load callbacks may arrive from the emulation thread after a network
	# stop. Disconnect them while the old core nodes still exist so they cannot
	# revive late-join bookkeeping in the next session.
	_disconnect_join_save_handlers()
	_disconnect_join_loaded()
	# Cleared here rather than in _reset_runtime: the host's identity arrives in
	# _np_start, and a cold start reaches _reset_runtime AFTER that.
	_await_core = ""
	_await_states = []
	_join_states = []
	_join_frame = -1
	_join_loaded = 0
	_join_capture_pending = false
	_join_capture_frame = -1
	_host_identities.clear()
	_local_identities.clear()
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
	_machine_specs = []
	_lib = null
	_system = null
	_ready_peers.clear()
	_frames.clear()
	_recv.clear()
	_local_inputs.clear()
	_link_ops.clear()
	_link_waiting.clear()
	_link_deadlines.clear()
	_disc_waiting.clear()
	_disc_deadlines.clear()
	_reset_waiting.clear()
	_reset_deadlines.clear()
	_deferred_joiners.clear()
	_joining.clear()
	_spectators.clear()
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
	_link_ops.clear()
	_link_waiting.clear()
	_link_deadlines.clear()
	_disc_waiting.clear()
	_disc_deadlines.clear()
	_reset_waiting.clear()
	_reset_deadlines.clear()
	_deferred_joiners.clear()
	_pending_local_route.clear()
	_crc_table.clear()
	_strikes.clear()
	_spectators.clear()
	_joining.clear()
	_join_capture_pending = false
	_join_capture_frame = -1
	_pending.clear()
	_local_aux.clear()
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


func _aux_default() -> Array:
	var out: Array = []
	out.resize(AUX_INTS_PER_PORT)
	out.fill(0)
	return out


func _global_port(system: Object, local_port: int) -> int:
	var machine_index := _group.find(system)
	return -1 if machine_index < 0 or local_port < 0 or local_port >= PORTS_PER_MACHINE \
		else machine_index * PORTS_PER_MACHINE + local_port


## Aux feeds from handhelds and motion controllers. True means the session owns
## the port, so the caller must not write the core directly.
func set_aux_sensor(system: Object, local_port: int, sensor_index: int,
		x_mg: int, y_mg: int, z_mg: int, gyro := false) -> bool:
	if not _running:
		return false
	var port := _global_port(system, local_port)
	if port < 0 or not _is_participating(port):
		return false
	if _rollback:
		stop("sensor input appeared during rollback; restart in lockstep")
		return true
	if not _local_ports.has(port):
		return true
	if sensor_index < 0 or sensor_index >= AUX_SENSOR_COUNT:
		return true
	var aux: Array = _local_aux.get(port, _aux_default())
	var flag_bit := sensor_index + (2 if gyro else 0)
	var base := (7 if gyro else 1) + sensor_index * 3
	aux[0] = int(aux[0]) | (1 << flag_bit)
	aux[base] = x_mg
	aux[base + 1] = y_mg
	aux[base + 2] = z_mg
	_local_aux[port] = aux
	return true


func set_aux_pointer(system: Object, local_port: int, pointer_index: int,
		px: int, py: int, pressed: bool) -> bool:
	if not _running:
		return false
	var port := _global_port(system, local_port)
	if port < 0 or not _is_participating(port):
		return false
	if _rollback:
		stop("pointer input appeared during rollback; restart in lockstep")
		return true
	if not _local_ports.has(port):
		return true
	if pointer_index < 0 or pointer_index >= AUX_POINTER_COUNT:
		return true
	var aux: Array = _local_aux.get(port, _aux_default())
	var base := 13 + pointer_index * 3
	aux[0] = int(aux[0]) | (1 << (4 + pointer_index))
	aux[base] = px
	aux[base + 1] = py
	aux[base + 2] = 1 if pressed else 0
	_local_aux[port] = aux
	return true


func set_lightgun_button(system: Object, local_port: int, button: int, pressed: bool) -> bool:
	var port := _global_port(system, local_port)
	if not _running or port < 0 or not _is_participating(port):
		return false
	if _local_ports.has(port):
		if _rollback:
			return false
		var vals: Array = _pending_local_route.get(port, [0, 0, 0, 1, 0])
		if pressed:
			vals[0] = int(vals[0]) | (1 << button)
		else:
			vals[0] = int(vals[0]) & ~(1 << button)
		_pending_local_route[port] = vals
	return true


func set_lightgun_aim(system: Object, local_port: int, px: int, py: int,
		offscreen: bool) -> bool:
	var port := _global_port(system, local_port)
	if not _running or port < 0 or not _is_participating(port):
		return false
	if _local_ports.has(port):
		if _rollback:
			return false
		var vals: Array = _pending_local_route.get(port, [0, 0, 0, 1, 0])
		vals[1] = px
		vals[2] = py
		vals[3] = 1 if offscreen else 0
		_pending_local_route[port] = vals
	return true


## Queue a keyboard transition into the deterministic schedule. Returns true
## when consumed (a lockstep game is running for this system and this peer
## supplies the keyboard block).
func queue_key_event(system: Object, keycode: int, down: bool, character: int) -> bool:
	if not _running or _rollback:
		return false
	var machine_index := _group.find(system)
	if machine_index < 0:
		return false
	var global_port := machine_index * PORTS_PER_MACHINE
	if not _is_participating(global_port):
		return false
	if not _local_ports.has(global_port):
		# Participating game but another peer owns the keyboard feed — swallow
		# so the local core isn't driven directly (would desync).
		return true
	if not _local_keys.has(machine_index):
		_local_keys[machine_index] = []
	_local_keys[machine_index].append([
		(keycode & 0xFFFF) | (65536 if down else 0), character])
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
	if not _nm.is_host() or not _running:
		return
	if controller == null or not is_instance_valid(controller):
		return
	var machine: Object = controller.get("_connected_system")
	var local_port := int(controller.get("_port_index"))
	handoff_port(machine, local_port, new_owner)


## Host: schedule ownership for a known system/port. Plug/unplug events use this
## seam because on_unplugged has already cleared the controller's own fields.
func handoff_port(machine: Object, local_port: int, new_owner: int) -> void:
	if not _nm.is_host() or not _running:
		return
	var port := _global_port(machine, local_port)
	if port < 0:
		return
	if not _is_participating(port):
		return
	# Movable/sensor peripherals force lockstep at start. A fixed receiver can
	# still be unplugged during rollback; end cleanly instead of leaving a stale
	# owner and held input in the speculative timeline.
	if _rollback:
		stop("controller ownership changed during rollback; restart required")
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
	_clear_port_state(port)
	print("[Netplay] port %d handoff: peer %d -> %d @frame %d" %
		[port, old_owner, new_owner, frame])
	_np_transfer.rpc(port, old_owner, new_owner, frame)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_transfer(port: int, old_owner: int, new_owner: int, frame: int) -> void:
	_pending[port] = {"frame": frame, "old": old_owner, "new": new_owner, "applied": false}
	_clear_port_state(port)


func _clear_port_state(port: int) -> void:
	_pending_local_route.erase(port)
	_local_aux.erase(port)
	_drain_ports.erase(port)
	if port_on_machine(port) == 0:
		_local_keys.erase(machine_of_port(port))


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
	if not _nm.is_host() or not _running or _rollback:
		return
	var machine_index := _group.find(system)
	if machine_index < 0:
		return
	var frame := _complete_upto + _delay + DISK_LEAD
	_disc_serial += 1
	var serial := _disc_serial
	var waiting := _participating_remote_peers()
	if not waiting.is_empty():
		_disc_waiting[serial] = waiting
		_disc_deadlines[serial] = _now() + OP_ACK_TIMEOUT_MS
	print("[Netplay] disc op %d/%d machine=%d (md5 %s…) @frame %d; waiting=%s" % [
		serial, op, machine_index, md5.left(8), frame, str(waiting.keys())])
	if not _apply_disk_op(machine_index, op, md5, index, frame):
		stop("could not queue disc operation %d" % serial)
		return
	for peer_id: int in waiting:
		_np_disk.rpc_id(peer_id, serial, machine_index, op, md5, index, frame)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_disk(serial: int, machine_index: int, op: int, md5: String,
		index: int, frame: int) -> void:
	if _apply_disk_op(machine_index, op, md5, index, frame):
		_np_disk_ready.rpc_id(1, serial)
	else:
		_np_disk_failed.rpc_id(1, serial, "disc is unavailable or operation arrived late")


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_disk_ready(serial: int) -> void:
	if not _nm.is_host() or not _disc_waiting.has(serial):
		return
	var waiting: Dictionary = _disc_waiting[serial]
	waiting.erase(multiplayer.get_remote_sender_id())
	if waiting.is_empty():
		_disc_waiting.erase(serial)
		_disc_deadlines.erase(serial)
		print("[Netplay] disc op %d acknowledged by every peer" % serial)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_disk_failed(serial: int, reason: String) -> void:
	if not _nm.is_host() or not _disc_waiting.has(serial):
		return
	stop("disc op %d failed: %s" % [serial, reason])


func _apply_disk_op(machine_index: int, op: int, md5: String, index: int,
		frame: int) -> bool:
	if machine_index < 0 or machine_index >= _libs.size():
		return false
	var lib: Object = _libs[machine_index]
	if lib == null or not lib.has_method("ScheduleDiscOp"):
		return false
	if frame < _next_post:
		push_warning("[Netplay] disc op for frame %d arrived after frame %d was posted" % [
			frame, _next_post - 1])
		return false
	var path := ""
	if op == 1:
		path = _resolve_disk_path(machine_index, md5)
		if path.is_empty():
			push_warning("[Netplay] disc swap: no local file for md5 %s…" % md5.left(8))
			return false
	print("[Netplay] machine %d disc op %d armed @frame %d%s" %
		[machine_index, op, frame, "" if path.is_empty() else " (" + path.get_file() + ")"])
	lib.ScheduleDiscOp(frame, op, index, path)
	return true


# ── Front-panel reset ────────────────────────────────────────────────────────

## Host: reset one machine on a confirmed future boundary. Reset changes core
## state outside the input frame, so applying it whenever each peer receives a
## button event would immediately fork the emulation timeline.
func schedule_reset(system: Object) -> void:
	if not _nm.is_host() or not _running:
		return
	var machine_index := _group.find(system)
	if machine_index < 0:
		return
	var frame := _complete_upto + _delay + RESET_LEAD
	_reset_serial += 1
	var serial := _reset_serial
	var waiting := _participating_remote_peers()
	if not waiting.is_empty():
		_reset_waiting[serial] = waiting
		_reset_deadlines[serial] = _now() + OP_ACK_TIMEOUT_MS
	print("[Netplay] reset %d machine=%d @frame %d; waiting=%s" % [
		serial, machine_index, frame, str(waiting.keys())])
	if not _apply_reset(machine_index, frame):
		stop("could not queue reset %d" % serial)
		return
	for peer_id: int in waiting:
		_np_reset.rpc_id(peer_id, serial, machine_index, frame)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_reset(serial: int, machine_index: int, frame: int) -> void:
	if _apply_reset(machine_index, frame):
		_np_reset_ready.rpc_id(1, serial)
	else:
		_np_reset_failed.rpc_id(1, serial, "reset arrived late or core cannot schedule it")


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_reset_ready(serial: int) -> void:
	if not _nm.is_host() or not _reset_waiting.has(serial):
		return
	var waiting: Dictionary = _reset_waiting[serial]
	waiting.erase(multiplayer.get_remote_sender_id())
	if waiting.is_empty():
		_reset_waiting.erase(serial)
		_reset_deadlines.erase(serial)
		print("[Netplay] reset %d acknowledged by every peer" % serial)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_reset_failed(serial: int, reason: String) -> void:
	if not _nm.is_host() or not _reset_waiting.has(serial):
		return
	stop("reset %d failed: %s" % [serial, reason])


func _apply_reset(machine_index: int, frame: int) -> bool:
	if machine_index < 0 or machine_index >= _libs.size():
		return false
	var lib: Object = _libs[machine_index]
	if lib == null or not lib.has_method("ScheduleReset"):
		return false
	if frame < _next_post:
		push_warning("[Netplay] reset for frame %d arrived after frame %d was posted" % [
			frame, _next_post - 1])
		return false
	var machine: Object = _group[machine_index]
	if machine != null and machine.has_method("net_play_reset"):
		machine.net_play_reset()
	lib.ScheduleReset(frame)
	return true


func _participating_remote_peers() -> Dictionary:
	var waiting := {}
	for peer_id: int in _nm.peers:
		if peer_id != 1 and _ready_peers.has(peer_id) and not _spectators.has(peer_id) \
				and not _joining.has(peer_id):
			waiting[peer_id] = true
	return waiting


## Find this peer's byte-identical copy of the new disc (verify-only, never
## transferred — same policy as ROMs at cold start).
func _resolve_disk_path(machine_index: int, md5: String) -> String:
	if md5.is_empty():
		return ""
	if machine_index < 0 or machine_index >= _group.size():
		return ""
	var machine: Object = _group[machine_index]
	if machine != null and machine.has_method("net_resolve_rom") \
			and machine.net_resolve_rom(md5):
		return str(machine.get("rom_path"))
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
	_link_serial += 1
	var serial := _link_serial
	var waiting := _participating_remote_peers()
	if not waiting.is_empty():
		_link_waiting[serial] = waiting
		_link_deadlines[serial] = _now() + OP_ACK_TIMEOUT_MS
	print("[Netplay] link op %d/%d over machines %s @frame %d; waiting=%s" % [
		serial, op, str(member_ids), frame, str(waiting.keys())])
	if not _apply_link_op(op, member_ids, port_ids, frame):
		stop("could not queue link operation %d" % serial)
		return
	for peer_id: int in waiting:
		_np_link.rpc_id(peer_id, serial, op, member_ids, port_ids, frame)


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
func _np_link(serial: int, op: int, members: PackedInt32Array,
		ports: PackedInt32Array, frame: int) -> void:
	if _apply_link_op(op, members, ports, frame):
		_np_link_ready.rpc_id(1, serial)
	else:
		_np_link_failed.rpc_id(1, serial, "operation arrived after its frame")


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_link_ready(serial: int) -> void:
	if not _nm.is_host() or not _link_waiting.has(serial):
		return
	var waiting: Dictionary = _link_waiting[serial]
	waiting.erase(multiplayer.get_remote_sender_id())
	if waiting.is_empty():
		_link_waiting.erase(serial)
		_link_deadlines.erase(serial)
		print("[Netplay] link op %d acknowledged by every peer" % serial)


@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _np_link_failed(serial: int, reason: String) -> void:
	if not _nm.is_host() or not _link_waiting.has(serial):
		return
	stop("link op %d failed: %s" % [serial, reason])


## Queue the op until the frame gate is about to release `frame`.  Scheduling it
## on only the head core's emulation thread races every other core on the bus:
## one of them may already run the boundary frame before the head changes the
## topology.  _drain_to_core applies it while ALL cores are still gated, then
## posts that frame to each of them.
func _apply_link_op(op: int, members: PackedInt32Array, ports: PackedInt32Array,
		frame: int) -> bool:
	if frame < _next_post:
		push_warning("[Netplay] link op for frame %d arrived after frame %d was posted" % [
			frame, _next_post - 1])
		return false
	if members.is_empty() or members.size() != ports.size():
		return false
	for member: int in members:
		var idx := int(member)
		if idx < 0 or idx >= _libs.size():
			return false
	if not _link_ops.has(frame):
		_link_ops[frame] = []
	_link_ops[frame].append({"op": op, "members": members, "ports": ports})
	print("[Netplay] link op %d queued locally @frame %d (queue=%d)" % [
		op, frame, _link_ops[frame].size()])
	return true


## Apply every cable event at this boundary in network order.  Multiple cables
## can move before the same future frame, so this is an array rather than one
## dictionary entry that overwrites its predecessor.
func _land_link_ops(frame: int) -> bool:
	var ops: Array = _link_ops.get(frame, [])
	_link_ops.erase(frame)
	for pending: Dictionary in ops:
		var members: PackedInt32Array = pending["members"]
		var ports: PackedInt32Array = pending["ports"]
		if members.is_empty() or members.size() != ports.size():
			continue
		var head_idx := int(members[0])
		if head_idx < 0 or head_idx >= _libs.size():
			continue
		var head: Object = _libs[head_idx]
		if head == null:
			return false
		if int(pending["op"]) == 0:
			if not head.has_method("LinkDisconnect"):
				return false
			head.LinkDisconnect(int(ports[0]))
			print("[Netplay] link PULL landed @frame %d machine=%d port=%d" % [
				frame, head_idx, int(ports[0])])
			continue
		if not head.has_method("LinkConnectGroup"):
			return false
		var others: Array = []
		for i in range(1, members.size()):
			others.append(_libs[int(members[i])])
		var ok: bool = head.LinkConnectGroup(others, ports)
		print("[Netplay] link JOIN landed @frame %d machines=%s ok=%s" % [
			frame, str(members), ok])
		if not ok:
			return false
	return true


func _all_cores_at_link_boundary(frame: int) -> bool:
	for lib: Object in _libs:
		if lib == null or not lib.has_method("GetFrameCount") \
				or int(lib.GetFrameCount()) < frame:
			return false
	return true


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
## Asked of the CORE rather than inferred from a nearby socket: the cable is
## what joined them, but LinkCoordinator is the authority on whether another
## running endpoint is actually present. A later cold start explicitly
## re-resolves the physical cables because stopping content drops that state.
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
		if not _join_paused and _link_waiting.is_empty() and _disc_waiting.is_empty() \
				and _reset_waiting.is_empty():
			_host_assemble()
	_drain_to_core()
	_poll_join_capture()
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
		var aux_frame := {}
		var keys_frame := {}
		for port: int in _local_ports:
			aux_frame[port] = (_local_aux.get(port, _aux_default()) as Array).duplicate()
		for machine_index in range(_group.size()):
			if not _local_ports.has(machine_index * PORTS_PER_MACHINE):
				continue
			var kv: Array = []
			var pending_keys: Array = _local_keys.get(machine_index, [])
			while not pending_keys.is_empty() and kv.size() < KEY_SLOTS * 2:
				var ev: Array = pending_keys.pop_front()
				kv.append(int(ev[0]))
				kv.append(int(ev[1]))
			_local_keys[machine_index] = pending_keys
			keys_frame[machine_index] = kv
		_local_aux_by_frame[_sched_frame] = aux_frame
		_local_keys_by_frame[_sched_frame] = keys_frame
		if _nm.is_host():
			for port: int in inp:
				_recv_put(_sched_frame, port, inp[port])
			_recv_aux[_sched_frame] = aux_frame.duplicate(true)
			_recv_keys[_sched_frame] = keys_frame.duplicate(true)
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
		var aux_frame: Dictionary = _local_aux_by_frame.get(f, {})
		var keys_frame: Dictionary = _local_keys_by_frame.get(f, {})
		for machine_index in range(_group.size()):
			for local_port in range(PORTS_PER_MACHINE):
				var global_port := machine_index * PORTS_PER_MACHINE + local_port
				_put_aux(buf, aux_frame.get(global_port, _aux_default()))
			_put_keys(buf, keys_frame.get(machine_index, []))
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
		if buf.get_available_bytes() < _machine_count() * (AUX_BYTES + KEY_BYTES):
			return
		for machine_index in range(_machine_count()):
			for local_port in range(PORTS_PER_MACHINE):
				var aux := _get_aux(buf)
				var aux_port := machine_index * PORTS_PER_MACHINE + local_port
				if _owner_for_frame(aux_port, f) == sender and f > _complete_upto:
					if not _recv_aux.has(f):
						_recv_aux[f] = {}
					_recv_aux[f][aux_port] = aux
			var keys := _get_keys(buf)
			# Keyboard state is global to a core and rides with port 0's owner.
			var global_port := machine_index * PORTS_PER_MACHINE
			if _owner_for_frame(global_port, f) == sender and f > _complete_upto:
				if not _recv_keys.has(f):
					_recv_keys[f] = {}
				_recv_keys[f][machine_index] = keys


func _host_assemble() -> void:
	var changed := false
	while true:
		var f := _complete_upto + 1
		if not _frame_ready(f):
			break
		_frames[f] = _flat_from_frame(_recv.get(f, {}),
			_recv_aux.get(f, {}), _recv_keys.get(f, {}))
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
		for machine_index in range(_machine_count()):
			for local_port in range(PORTS_PER_MACHINE):
				_put_aux(buf, _aux_of(flat, machine_index, local_port))
			_put_keys(buf, _keys_of(flat, machine_index))
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
		var need := 4 + _all_ports.size() * 10 \
			+ _machine_count() * (AUX_BYTES + KEY_BYTES)
		if buf.get_available_bytes() < need:
			return
		var f := int(buf.get_u32())
		var flat := PackedInt32Array()
		flat.resize(_frame_ints())
		for port in _all_ports:
			var base := port * 5
			flat[base] = buf.get_u16()
			flat[base + 1] = buf.get_16(); flat[base + 2] = buf.get_16()
			flat[base + 3] = buf.get_16(); flat[base + 4] = buf.get_16()
		for machine_index in range(_machine_count()):
			var tail := _machine_tail_offset(machine_index)
			for local_port in range(PORTS_PER_MACHINE):
				var aux := _get_aux(buf)
				var aux_base := tail + local_port * AUX_INTS_PER_PORT
				for i in range(AUX_INTS_PER_PORT):
					flat[aux_base + i] = int(aux[i])
			var keys := _get_keys(buf)
			for i in range(KEY_SLOTS * 2):
				flat[tail + AUX_INTS + i] = int(keys[i])
		if f >= _next_post and not _frames.has(f):
			_frames[f] = flat


func _drain_to_core() -> void:
	var progressed := false
	while _frames.has(_next_post):
		if _link_ops.has(_next_post) and not _all_cores_at_link_boundary(_next_post):
			break
		var flat: PackedInt32Array = _frames[_next_post]
		if not _land_link_ops(_next_post):
			stop("link operation failed at frame %d" % _next_post)
			return
		for i in range(_libs.size()):
			_libs[i].PostNetplayInputs(_next_post, _slice_for_machine(flat, i))
		_next_post += 1
		progressed = true
	if progressed:
		_last_progress_ms = _now()
	if _nm.is_host():
		_start_next_deferred_join()


## Reliable re-request when the gate has been starved past STALL_MS.
func _check_stall() -> void:
	if _nm.is_host() and (not _link_waiting.is_empty() or not _disc_waiting.is_empty() \
			or not _reset_waiting.is_empty()):
		var timeout_reason := _expired_operation(_now())
		if not timeout_reason.is_empty():
			stop(timeout_reason)
		return
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


func _expired_operation(now: int) -> String:
	for serial: int in _link_deadlines:
		if now >= int(_link_deadlines[serial]):
			return "link operation %d acknowledgement timed out" % serial
	for serial: int in _disc_deadlines:
		if now >= int(_disc_deadlines[serial]):
			return "disc operation %d acknowledgement timed out" % serial
	for serial: int in _reset_deadlines:
		if now >= int(_reset_deadlines[serial]):
			return "reset %d acknowledgement timed out" % serial
	return ""


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
		for machine_index in range(_machine_count()):
			for local_port in range(PORTS_PER_MACHINE):
				_put_aux(buf, _aux_of(flat, machine_index, local_port))
			_put_keys(buf, _keys_of(flat, machine_index))
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
	var aux_frame: Dictionary = _local_aux_by_frame.get(frame, {})
	var keys_frame: Dictionary = _local_keys_by_frame.get(frame, {})
	for machine_index in range(_machine_count()):
		for local_port in range(PORTS_PER_MACHINE):
			var global_port := machine_index * PORTS_PER_MACHINE + local_port
			_put_aux(buf, aux_frame.get(global_port, _aux_default()))
		_put_keys(buf, keys_frame.get(machine_index, []))
	_np_input.rpc_id(1, buf.data_array)


# ── Late join (host stalls, ships a savestate) ────────────────────────────────

## Called by NetworkManager when a peer registers mid-session.
func on_peer_joined(peer_id: int) -> void:
	if not _nm.is_host() or not _running:
		return
	# A core savestate does not contain LinkCoordinator's in-flight messages or
	# clock horizons. Until the bus itself has a snapshot format, loading only
	# the cores would create a subtly different linked machine on the newcomer.
	if _group.size() > 1:
		_spectators[peer_id] = true
		print("[Netplay] peer %d remains spectator: linked games cannot late-join safely" % peer_id)
		_np_join_refused.rpc_id(peer_id,
			"Late join is unavailable while emulated machines are linked")
		return
	if _join_paused or _join_capture_pending or not _link_waiting.is_empty() \
			or not _disc_waiting.is_empty() \
			or not _reset_waiting.is_empty() \
			or not _link_ops.is_empty():
		_deferred_joiners[peer_id] = true
		print("[Netplay] peer %d late join deferred until the current boundary settles" % peer_id)
		return
	_begin_join_capture(peer_id)


func _begin_join_capture(peer_id: int) -> void:
	_joining[peer_id] = true
	_ready_peers.erase(peer_id)
	_join_paused = true      # freeze the pipeline — everyone stalls at the gate
	_join_capture_pending = true
	_join_capture_frame = -1
	print("[Netplay] pausing at a common frame for peer %d's snapshot" % peer_id)


## Once every already-posted frame has executed on every local core, request
## the state. This keeps a snapshot from pairing frame N of one core with frame
## N+1 of another. Linked sessions are refused above because their external bus
## queues still need their own serialization format.
func _poll_join_capture() -> void:
	if not _nm.is_host() or not _join_capture_pending:
		return
	if _join_capture_frame < 0:
		_join_capture_frame = _next_post
	if not _all_cores_at_link_boundary(_join_capture_frame):
		return
	_join_capture_pending = false
	# A state per machine: a joiner arriving into a cabled pair needs both ends
	# of the bus, or it resumes half a conversation.
	_join_states.clear()
	_join_states.resize(_libs.size())
	_join_frame = _join_capture_frame
	for i in range(_libs.size()):
		var lib: Object = _libs[i]
		if lib == null or not lib.has_method("RequestSaveState"):
			_fail_join_capture("machine %d cannot save state" % i)
			return
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
		_fail_join_capture("machine %d could not serialize" % machine_index)
		return
	if frame != _join_frame:
		_fail_join_capture("machine %d saved frame %d, expected %d" % [
			machine_index, frame, _join_frame])
		return
	if machine_index < _join_states.size():
		_join_states[machine_index] = data
	for state: Variant in _join_states:
		if state == null:
			return          # still collecting the rest of the bus
	if _join_frame < 0:
		return
	for peer_id: int in _joining.keys():
		_np_savestate.rpc_id(peer_id, _group_net_ids, _machine_specs, _owners,
			_delay, _join_states.duplicate(), _join_frame, _rollback,
			_host_identities)


func _fail_join_capture(reason: String) -> void:
	push_warning("[Netplay] late-join snapshot failed: %s" % reason)
	_disconnect_join_save_handlers()
	_join_states.clear()
	_join_capture_pending = false
	_join_capture_frame = -1
	for peer_id: int in _joining.keys():
		_spectators[peer_id] = true
		_np_join_refused.rpc_id(peer_id, reason)
	_joining.clear()
	_join_paused = false
	_start_next_deferred_join()


func _disconnect_join_save_handlers() -> void:
	for i in range(_libs.size()):
		var lib: Object = _libs[i]
		if lib != null and lib.has_signal("savestate_ready"):
			var handler := _on_savestate_for_join.bind(i)
			if lib.savestate_ready.is_connected(handler):
				lib.savestate_ready.disconnect(handler)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_join_refused(reason: String) -> void:
	print("[Netplay] remaining spectator: %s" % reason)
	if _nm.has_signal("status_changed"):
		_nm.status_changed.emit(reason)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _np_savestate(group_net_ids: PackedInt32Array, machine_specs: Array,
		owners: Dictionary, delay: int, states: Array, frame: int,
		rollback := false, host_identities: Array = []) -> void:
	_machine_specs = machine_specs.duplicate(true)
	_core = str(_machine_specs[0].get("core", "")) if not _machine_specs.is_empty() else ""
	_delay = delay
	_rollback = rollback
	_host_identities = host_identities.duplicate(true)
	_local_identities.clear()
	_set_owners(owners)
	if not _adopt_group(group_net_ids):
		_np_ready_fail.rpc_id(1, "cannot resolve every machine in the game")
		return
	if not _prepare_local_media():
		_np_ready_fail.rpc_id(1, "missing ROM for one of the linked machines")
		return
	if not _cold_start_local(frame):
		_np_ready_fail.rpc_id(1, "cannot start one of the linked cores")
		_stop_local("cannot start one of the linked cores")
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
		_join_capture_frame = -1
		_last_progress_ms = _now()
		_start_next_deferred_join()


func _start_next_deferred_join() -> void:
	if not _nm.is_host() or _join_paused or _join_capture_pending \
			or not _link_waiting.is_empty() or not _disc_waiting.is_empty() \
			or not _reset_waiting.is_empty() \
			or not _link_ops.is_empty() \
			or _deferred_joiners.is_empty():
		return
	var peer_id := int(_deferred_joiners.keys()[0])
	_deferred_joiners.erase(peer_id)
	_begin_join_capture(peer_id)


## Host: a peer disconnected. A departed port owner stalls the assembler
## forever, so end the game; a spectator/non-owner just gets cleaned up.
func on_peer_left(peer_id: int) -> void:
	if not _nm.is_host():
		return
	_ready_peers.erase(peer_id)
	_joining.erase(peer_id)
	_strikes.erase(peer_id)
	_spectators.erase(peer_id)
	_deferred_joiners.erase(peer_id)
	for serial: int in _link_waiting.keys():
		var waiting: Dictionary = _link_waiting[serial]
		waiting.erase(peer_id)
		if waiting.is_empty():
			_link_waiting.erase(serial)
			_link_deadlines.erase(serial)
	for serial: int in _disc_waiting.keys():
		var waiting: Dictionary = _disc_waiting[serial]
		waiting.erase(peer_id)
		if waiting.is_empty():
			_disc_waiting.erase(serial)
			_disc_deadlines.erase(serial)
	for serial: int in _reset_waiting.keys():
		var waiting: Dictionary = _reset_waiting[serial]
		waiting.erase(peer_id)
		if waiting.is_empty():
			_reset_waiting.erase(serial)
			_reset_deadlines.erase(serial)
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
	_start_next_deferred_join()


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
## PORTS_PER_MACHINE x 5, followed by one aux/key tail for each machine.
func _port_ints() -> int:
	return _machine_count() * PORTS_PER_MACHINE * 5


func _machine_count() -> int:
	return maxi(_group.size(), 1)


func _machine_tail_offset(machine_index: int) -> int:
	return _port_ints() + machine_index * (AUX_INTS + KEY_SLOTS * 2)


func _frame_ints() -> int:
	return _port_ints() + _machine_count() * (AUX_INTS + KEY_SLOTS * 2)


## Assembled frame: one 5-int block per GLOBAL port, then one aux + keyboard
## block per machine. A linked handheld's tilt or keyboard belongs to that
## handheld alone and must not be dropped or copied into every other core.
func _flat_from_frame(pm: Dictionary, aux_by_port: Dictionary,
		keys_by_machine: Dictionary) -> PackedInt32Array:
	var port_ints := _port_ints()
	var flat := PackedInt32Array()
	flat.resize(_frame_ints())
	for port: int in pm:
		var v: Array = pm[port]
		var base := int(port) * 5
		if base + 5 > port_ints:
			continue
		for i in range(5):
			flat[base + i] = int(v[i])
	for machine_index in range(_machine_count()):
		var tail := _machine_tail_offset(machine_index)
		var keys: Array = keys_by_machine.get(machine_index, [])
		for local_port in range(PORTS_PER_MACHINE):
			var global_port := machine_index * PORTS_PER_MACHINE + local_port
			var aux: Array = aux_by_port.get(global_port, _aux_default())
			var aux_base := tail + local_port * AUX_INTS_PER_PORT
			for i in range(AUX_INTS_PER_PORT):
				flat[aux_base + i] = int(aux[i])
		for i in range(mini(keys.size(), KEY_SLOTS * 2)):
			flat[tail + AUX_INTS + i] = int(keys[i])
	return flat


## One machine's share of an assembled frame, in the shape a core expects:
## its own four ports, then its own aux and key blocks. The C++ gate has never
## known about anything but its own machine and does not need to.
func _slice_for_machine(flat: PackedInt32Array, machine_index: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(PORTS_PER_MACHINE * 5 + AUX_INTS + KEY_SLOTS * 2)
	var base := machine_index * PORTS_PER_MACHINE * 5
	for i in range(PORTS_PER_MACHINE * 5):
		out[i] = flat[base + i] if base + i < flat.size() else 0
	var tail := _machine_tail_offset(machine_index)
	for i in range(AUX_INTS + KEY_SLOTS * 2):
		out[PORTS_PER_MACHINE * 5 + i] = flat[tail + i] if tail + i < flat.size() else 0
	return out


## One machine's aux block out of an assembled frame.
func _aux_of(flat: PackedInt32Array, machine_index: int, local_port: int) -> Array:
	var base := _machine_tail_offset(machine_index) + local_port * AUX_INTS_PER_PORT
	var out: Array = []
	for i in range(AUX_INTS_PER_PORT):
		out.append(flat[base + i] if base + i < flat.size() else 0)
	return out


func _keys_of(flat: PackedInt32Array, machine_index: int) -> Array:
	var base := _machine_tail_offset(machine_index) + AUX_INTS
	var out: Array = []
	for i in range(KEY_SLOTS * 2):
		out.append(flat[base + i] if base + i < flat.size() else 0)
	return out


func _put_port(buf: StreamPeerBuffer, port: int, v: Array) -> void:
	buf.put_u8(port)
	buf.put_u16(int(v[0]) & 0xFFFF)
	buf.put_16(int(v[1])); buf.put_16(int(v[2]))
	buf.put_16(int(v[3])); buf.put_16(int(v[4]))


func _get_port(buf: StreamPeerBuffer) -> Array:
	return [buf.get_u16(), buf.get_16(), buf.get_16(), buf.get_16(), buf.get_16()]


## One port's aux wire block: flags, accel+gyro for two sensor indices, then
## four pointer contacts. All analogue values are signed 16-bit quantities.
func _put_aux(buf: StreamPeerBuffer, aux: Array) -> void:
	buf.put_u8(int(aux[0]) & 0xFF)
	for i in range(1, 13):
		buf.put_16(int(aux[i]))
	for pointer_index in range(AUX_POINTER_COUNT):
		var base := 13 + pointer_index * 3
		buf.put_16(int(aux[base]))
		buf.put_16(int(aux[base + 1]))
		buf.put_u8(1 if int(aux[base + 2]) != 0 else 0)


func _get_aux(buf: StreamPeerBuffer) -> Array:
	var out := _aux_default()
	out[0] = buf.get_u8()
	for i in range(1, 13):
		out[i] = buf.get_16()
	for pointer_index in range(AUX_POINTER_COUNT):
		var base := 13 + pointer_index * 3
		out[base] = buf.get_16()
		out[base + 1] = buf.get_16()
		out[base + 2] = buf.get_u8()
	return out


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
