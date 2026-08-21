extends Node

## Netplay self-tests — the whole lockstep stack, headless, with mock cores.
##
##   "$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn
##   "$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn -- --only=start
##
## Exits non-zero on failure, so it can gate a commit. ~60 s, no ROM, no core,
## no headset, no display.
##
## Two kinds of case here, and the split is deliberate.
##
## The pure ones (cores/ identity/ wire/ owners/ assemble/) drive a NetplaySession
## with a stub parent and no network at all, because the wire format, the port
## bookkeeping and the assembler are decisions, not conversations.
##
## The rest run TWO — for the join cases, THREE — complete NetworkManagers in
## this one process, each with its own SceneMultiplayer, talking over real
## loopback ENet. That is closer to two copies of the app than two OS processes
## would be for anything this suite can assert: the RPCs, the channels, the
## serialization and the handshake are all the real ones, and the run stays
## deterministic and headless. What it does NOT cover is a real core's
## arithmetic; that needs two machines and lives in Tools/netplay_spike.gd
## (--spike-state-out / --spike-state-in for the cross-architecture leg).
##
## The mock core implements the C++ frame gate — it runs frame N only when
## PostNetplayInputs(N) arrives in order — and folds a deterministic RAM CRC from
## exactly the inputs posted, so two peers fed the same assembled frames produce
## identical CRC streams. It also reports a core IDENTITY the way the real
## Wrapper does: empty until content has loaded, then library_name/version/
## api_version/serialize_size. Several cases here exist only because that is
## asynchronous.

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const GROUPS := ["cores", "identity", "wire", "owners", "assemble", "start",
	"lockstep", "desync", "join", "leave", "rollback", "link"]
const PORT := 42913

## What a real fceumm reports, near enough. The exact strings do not matter to
## any case — only that two peers can be made to agree or disagree about them.
const IDENT_A := {"library_name": "FCEUmm", "library_version": "(SVN)",
	"api_version": 1, "serialize_size": 13701}

var _fail := 0
var _ran := 0
var _only := ""


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	if _want("cores"):
		_test_cores()
	if _want("identity"):
		_test_identity()
	if _want("wire"):
		await _test_wire()
	if _want("owners"):
		await _test_owners()
	if _want("assemble"):
		await _test_assemble()
	if _want("start"):
		await _test_start()
	if _want("lockstep"):
		await _test_lockstep()
	if _want("desync"):
		await _test_desync()
	if _want("join"):
		await _test_join()
	if _want("leave"):
		await _test_leave()
	if _want("rollback"):
		await _test_rollback()
	if _want("link"):
		await _test_link()

	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ══ The allowlist ═════════════════════════════════════════════════════════════
# A core is netplay-capable only after netplay_spike has proven it deterministic.
# The table is the record of what was measured, so the rules that read it are
# worth pinning: an unvetted core must be indistinguishable from an unknown one.

func _test_cores() -> void:
	_ok(NetplayCores.is_capable("fceumm"), "cores/a vetted core is capable")
	_ok(not NetplayCores.is_capable("snes9x"),
		"cores/a listed but unvetted core is not")
	_ok(not NetplayCores.is_capable("dolphin"),
		"cores/an unlisted core is not")
	_ok(not NetplayCores.is_capable(""), "cores/no core at all is not")

	# rollback needs BOTH determinism and a state cheap enough to take every
	# frame, so it can never be true where is_capable is false.
	for core: String in NetplayCores.CORES:
		if NetplayCores.rollback_capable(core):
			_ok(NetplayCores.is_capable(core),
				"cores/%s cannot roll back without being verified" % core)
	_ok(NetplayCores.rollback_capable("fceumm"), "cores/fceumm rolls back")
	_ok(not NetplayCores.rollback_capable("snes9x"),
		"cores/an unvetted core does not roll back")

	# forced_options is handed to a core at start; a caller mutating what it got
	# back would edit the table for every later session in this process.
	var opts := NetplayCores.forced_options("fceumm")
	opts["poisoned"] = "yes"
	_ok(not NetplayCores.forced_options("fceumm").has("poisoned"),
		"cores/forced options are copied, not shared")
	_ok(NetplayCores.forced_options("nonesuch").is_empty(),
		"cores/an unknown core forces nothing")

	# Every entry has to carry its provenance, or the table stops being evidence.
	for core: String in NetplayCores.CORES:
		_ok(not NetplayCores.notes(core).is_empty(),
			"cores/%s records why it is where it is" % core)


# ══ Core build identity ═══════════════════════════════════════════════════════
# The reason this exists at all: cores come from buildbot.libretro.com under
# nightly/<platform>/latest/, so a Windows player and a Quest player take their
# fceumm from two different directories, cut at two different times, from two
# different commits. They can never hold the same FILE, which is why the check
# is on what the core says it is rather than on a hash of the binary.

func _test_identity() -> void:
	var a := IDENT_A.duplicate()
	var b := IDENT_A.duplicate()
	_ok(NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/the same build plays itself")

	b["library_version"] = "(SVN 2026-08-21)"
	var msg := NetplaySession.identity_mismatch(a, b)
	_ok(not msg.is_empty(), "identity/a different build version is refused")
	_ok(msg.contains("(SVN)") and msg.contains("(SVN 2026-08-21)"),
		"identity/and the refusal names BOTH builds, not just that they differ")

	b = IDENT_A.duplicate()
	b["library_name"] = "Nestopia"
	_ok(not NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a different core entirely is refused")

	# The savestate size is not cosmetic: a late join and every desync resync
	# ship the host's serialized state for this peer to load. Different sizes
	# means that transfer cannot work, and the symptom is a failed join.
	b = IDENT_A.duplicate()
	b["serialize_size"] = 13702
	msg = NetplaySession.identity_mismatch(a, b)
	_ok(not msg.is_empty(), "identity/a different savestate size is refused")
	_ok(msg.contains("13701") and msg.contains("13702"),
		"identity/and the refusal gives both sizes")

	# 0 is "not measured yet", not "zero bytes", and the difference decides
	# whether netplay can start at all. A core cannot always be asked its
	# savestate size before it has run a frame (Dolphin segfaults on the
	# question), and under the gate NO peer has run one at cold start, because
	# the gate is waiting on the readiness this check is part of. Treating an
	# unmeasured size as a difference refuses every session on both platforms.
	b = IDENT_A.duplicate()
	b["serialize_size"] = 0
	_ok(NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a size not measured yet is not a difference")
	_ok(NetplaySession.identity_mismatch(b, a).is_empty(),
		"identity/in either direction")
	var both_unmeasured := IDENT_A.duplicate()
	both_unmeasured["serialize_size"] = 0
	_ok(NetplaySession.identity_mismatch(both_unmeasured, both_unmeasured.duplicate()).is_empty(),
		"identity/nor when neither side has measured one")
	# ...but the version check still has to bite through an unmeasured size,
	# or "not measured" becomes a way to get past the whole check.
	var unmeasured_other := IDENT_A.duplicate()
	unmeasured_other["serialize_size"] = 0
	unmeasured_other["library_version"] = "(SVN 2026-08-20)"
	_ok(not NetplaySession.identity_mismatch(a, unmeasured_other).is_empty(),
		"identity/an unmeasured size does not excuse a different build")

	b = IDENT_A.duplicate()
	b["api_version"] = 2
	_ok(not NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a different libretro API is refused")

	# An absent identity is a refusal, never a pass. This is the case that
	# decides whether the whole check can be defeated by a core that says
	# nothing, and "unknown means allowed" is how a guard becomes decoration.
	_ok(not NetplaySession.identity_mismatch({}, a).is_empty(),
		"identity/a host that reported nothing is refused")
	_ok(not NetplaySession.identity_mismatch(a, {}).is_empty(),
		"identity/a peer that reported nothing is refused")
	_ok(not NetplaySession.identity_mismatch({}, {}).is_empty(),
		"identity/two peers reporting nothing are still refused")

	_eq(NetplaySession.identity_str(IDENT_A), "FCEUmm (SVN)",
		"identity/a build reads as name and version")
	_eq(NetplaySession.identity_str({}), "(unknown)",
		"identity/and an absent one says so")


# ══ The wire format ═══════════════════════════════════════════════════════════
# Everything crossing the wire is integers, which is what makes cross-platform
# play possible at all — but each field is packed to a fixed width, and a value
# that does not survive the round trip is a desync with no other symptom.

func _test_wire() -> void:
	var np := _stub_session()

	# A joypad port: 16-bit button mask plus four SIGNED analog axes. The signs
	# are the whole point — an axis packed unsigned reads as full deflection the
	# other way, which is a controller that plays by itself.
	for vals: Array in [[0, 0, 0, 0, 0], [0xFFFF, 32767, -32768, 1, -1],
			[0x8001, -32768, 32767, -12345, 12345], [1 << 15, 100, -200, 300, -400]]:
		var buf := StreamPeerBuffer.new()
		np._put_port(buf, 3, vals)
		buf.seek(0)
		_eq(buf.get_u8(), 3, "wire/port %s keeps its index" % str(vals[0]))
		_eq(np._get_port(buf), vals, "wire/port %s round-trips" % str(vals))

	# Aux: sensor tilt in milli-g and a touch pointer, both signed, plus flags.
	# This is the block a Quest player fills in and a desktop player does not,
	# so it crosses between platforms more than anything else here.
	for aux: Array in [[0, 0, 0, 0, 0, 0, 0], [3, -1000, 1000, -32768, 32767, -1, 1],
			[1, 981, -981, 0, 0, 0, 0], [2, 0, 0, 0, -5, 5, 1]]:
		var buf2 := StreamPeerBuffer.new()
		np._put_aux(buf2, aux)
		# Against the CONSTANT the readers budget with, not against a number
		# written out here — the two disagreeing is the bug this pins down.
		_eq(buf2.get_size(), NetplaySession.AUX_BYTES,
			"wire/aux is exactly the size every reader budgets for")
		buf2.seek(0)
		_eq(np._get_aux(buf2), aux, "wire/aux %s round-trips" % str(aux))

	# The pressed flag is a bit, not a number: anything non-zero has to come back
	# as exactly 1 or the two peers fold different values into their CRCs.
	var bufp := StreamPeerBuffer.new()
	np._put_aux(bufp, [2, 0, 0, 0, 0, 0, 99])
	bufp.seek(0)
	_eq(np._get_aux(bufp)[6], 1, "wire/a pressed pointer normalises to 1")

	# Keyboard: keycode plus a down bit plus a character, per slot.
	var keys: Array = [65 | 65536, 97, 66, 98]
	var bufk := StreamPeerBuffer.new()
	np._put_keys(bufk, keys)
	_eq(bufk.get_size(), NetplaySession.KEY_BYTES,
		"wire/keys are exactly the size every reader budgets for")
	bufk.seek(0)
	var got: Array = np._get_keys(bufk)
	_eq(got.size(), NetplaySession.KEY_SLOTS * 2, "wire/keys unpack to every slot")
	_eq(got[0], 65 | 65536, "wire/a key-down survives with its down bit")
	_eq(got[1], 97, "wire/and its character")
	_eq(got[2], 66, "wire/a key-up survives without one")
	_eq(got[3], 98, "wire/and its character")
	_eq(got[4], 0, "wire/an unused slot is empty")

	# More transitions than slots: the overflow must not corrupt the slots that
	# did fit. (The scheduler rolls the remainder to the next frame.)
	var many: Array = []
	for i in range(NetplaySession.KEY_SLOTS * 2 + 4):
		many.append(100 + i)
	var bufo := StreamPeerBuffer.new()
	np._put_keys(bufo, many)
	bufo.seek(0)
	var over: Array = np._get_keys(bufo)
	_eq(over[0], 100, "wire/an overfull key block keeps its first slot")
	_eq(over[NetplaySession.KEY_SLOTS * 2 - 1], 100 + NetplaySession.KEY_SLOTS * 2 - 1,
		"wire/and its last")

	# The two readers refuse to unpack a frame they do not have all of, and they
	# budget for it with arithmetic written out by hand at each call site. That
	# arithmetic has to equal what the writers actually produce: when it asked
	# for two bytes more, both readers bailed out on the LAST frame of every
	# packet, which the redundancy window hid for streamed frames and could not
	# hide for a re-request (one frame per packet, dropped every time).
	var one := StreamPeerBuffer.new()
	one.put_u32(7)
	for _p in range(2):
		one.put_u16(0)
		one.put_16(0); one.put_16(0); one.put_16(0); one.put_16(0)
	np._put_aux(one, [0, 0, 0, 0, 0, 0, 0])
	np._put_keys(one, [])
	_eq(one.get_size(), 4 + 2 * 10 + NetplaySession.AUX_BYTES + NetplaySession.KEY_BYTES,
		"wire/a broadcast frame is exactly the size the client budgets for")

	var inp := StreamPeerBuffer.new()
	inp.put_u32(7)
	inp.put_u8(1)
	np._put_port(inp, 0, [0, 0, 0, 0, 0])
	np._put_aux(inp, [0, 0, 0, 0, 0, 0, 0])
	np._put_keys(inp, [])
	_eq(inp.get_size(), 4 + 1 + 11 + NetplaySession.AUX_BYTES + NetplaySession.KEY_BYTES,
		"wire/and an input frame is the size the host budgets for")

	# The assembled frame is one flat int array with a fixed layout; the gate
	# indexes straight into it, so a field landing one slot over is silent.
	var flat := np._flat_from_frame({0: [1, 2, 3, 4, 5], 2: [6, 7, 8, 9, 10]},
		{0: [3, 11, 12, 13, 14, 15, 1]}, {0: [70 | 65536, 102]})
	_eq(flat.size(), 20 + NetplaySession.AUX_INTS + NetplaySession.KEY_SLOTS * 2,
		"wire/an assembled frame is one fixed-size block")
	_eq(flat[0], 1, "wire/port 0 lands at 0")
	_eq(flat[10], 6, "wire/port 2 lands at 10")
	_eq(flat[5], 0, "wire/an absent port is neutral, not stale")
	_eq(flat[20], 3, "wire/aux follows the four ports")
	_eq(flat[26], 1, "wire/and ends with the pointer button")
	_eq(flat[27], 70 | 65536, "wire/keys follow aux")

	# A linked machine owns a separate aux/key tail. Sharing one tail copied the
	# anchor handheld's tilt into every core and discarded the far machine's.
	var far_wire_machine := Node.new()
	np._group = [self, far_wire_machine]
	var linked_flat := np._flat_from_frame({},
		{0: [1, 10, 20, 30, 0, 0, 0], 1: [2, 0, 0, 0, 40, 50, 1]},
		{0: [65, 97], 1: [66 | 65536, 98]})
	var near_slice := np._slice_for_machine(linked_flat, 0)
	var far_slice := np._slice_for_machine(linked_flat, 1)
	_eq(near_slice[20], 1, "wire/the anchor keeps its own aux flags")
	_eq(near_slice[21], 10, "wire/the anchor keeps its own sensor")
	_eq(far_slice[20], 2, "wire/the far machine keeps its own aux flags")
	_eq(far_slice[24], 40, "wire/the far machine keeps its own pointer")
	_eq(near_slice[27], 65, "wire/the anchor keeps its own keyboard")
	_eq(far_slice[27], 66 | 65536, "wire/the far machine keeps its own keyboard")
	far_wire_machine.free()

	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Who owns which port ═══════════════════════════════════════════════════════
# A port has exactly one owner per frame. Two peers supplying one port, or none
# supplying it, are the two ways a lockstep pipeline forks or stops.

func _test_owners() -> void:
	var np := _stub_session()           # this peer is 1

	np._set_owners({0: 1, 2: 7})
	_eq(Array(np._all_ports), [0, 2], "owners/participating ports are sorted")
	_eq(np._port_mask, 0b101, "owners/and reduced to a mask")
	_ok(np._is_participating(0) and np._is_participating(2),
		"owners/a listed port participates")
	_ok(not np._is_participating(1), "owners/an unlisted one does not")
	_ok(np._local_ports.has(0) and not np._local_ports.has(2),
		"owners/only our own ports are sampled locally")

	# Passing a controller to another player. Every peer flips at the same
	# agreed frame, so the frames either side of the boundary must resolve to
	# different owners — that is the whole mechanism.
	np._pending[0] = {"frame": 100, "old": 1, "new": 7, "applied": false}
	_eq(np._owner_for_frame(0, 99), 1, "owners/before the boundary, the old owner")
	_eq(np._owner_for_frame(0, 100), 7, "owners/at it, the new one")
	_eq(np._owner_for_frame(0, 101), 7, "owners/and after")
	_eq(np._owner_for_frame(2, 100), 7, "owners/an unaffected port is untouched")

	np._apply_pending_transfers(99)
	_eq(int(np._owners[0]), 1, "owners/a handoff does not land early")
	_ok(np._local_ports.has(0), "owners/and we keep sampling until it does")
	np._apply_pending_transfers(100)
	_eq(int(np._owners[0]), 7, "owners/it lands exactly at its frame")
	_ok(not np._local_ports.has(0), "owners/and we stop sampling the port we gave away")

	# A dropped controller: nobody owns the port, and the host fills it with
	# neutral input rather than waiting for a peer that will never send.
	np._set_owners({0: 0, 1: 1})
	_eq(np._owner_for_frame(0, 5), 0, "owners/a dropped controller is unowned")
	_ok(not np._local_ports.has(0), "owners/and nobody samples it")

	# The input seam. A participating port is swallowed whatever happens to it,
	# because the gate is the only thing allowed to drive it.
	np._set_owners({0: 1, 1: 9})
	# The session addresses ports as machine * PORTS_PER_MACHINE + port, so it
	# needs a group to look a machine up in, not just an anchor.
	var sys := np._system
	var grp := np._group
	np._system = self
	np._group = [self]
	np._running = true
	_ok(np.route(self, 0, {"btn": 5}), "owners/our own participating port is consumed")
	_ok(np.route(self, 1, {"btn": 5}), "owners/so is a port another peer owns")
	_ok(not np.route(self, 3, {"btn": 5}), "owners/a port outside the game is left alone")
	_ok(not np.route(null, 0, {"btn": 5}), "owners/and so is another machine's")
	_eq(np._capture_local(), {0: [5, 0, 0, 0, 0]}, "owners/what we captured is what we routed")

	# Held buttons persist frame to frame; mouse motion is a per-frame quantity
	# and must not be re-applied, or the pointer runs away at a constant speed.
	np.route(self, 0, {"btn": 3, "alx": 40, "aly": -40, "drain": true})
	_eq(np._capture_local(), {0: [3, 40, -40, 0, 0]}, "owners/a delta device is captured once")
	_eq(np._capture_local(), {0: [3, 0, 0, 0, 0]}, "owners/and drains, keeping its buttons")

	np._running = false
	np._system = sys
	np._group = grp
	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Assembly ══════════════════════════════════════════════════════════════════

func _test_assemble() -> void:
	var np := _stub_session()
	np._set_owners({0: 1, 1: 5})

	np._recv_put(0, 0, [1, 0, 0, 0, 0])
	_ok(not np._frame_ready(0), "assemble/a frame missing an owned port is not ready")
	np._recv_put(0, 1, [2, 0, 0, 0, 0])
	_ok(np._frame_ready(0), "assemble/with every port present it is")

	# Unowned is not the same as missing. A dropped controller would otherwise
	# stall the assembler for ever, waiting on a peer that does not exist.
	np._set_owners({0: 1, 1: 0})
	np._recv.clear()
	np._recv_put(3, 0, [1, 0, 0, 0, 0])
	_ok(np._frame_ready(3), "assemble/an unowned port does not hold a frame up")

	# Pruning keeps the tables bounded during a long game. What it must never
	# drop is anything at or ahead of the gate.
	np._next_post = 500
	for f in [100, 379, 380, 381, 499, 500, 600]:
		np._frames[f] = PackedInt32Array()
		np._local_inputs[f] = {}
		np._crc_table[f] = {}
	np._prune()
	var floor_frame: int = 500 - NetplaySession.PRUNE_BEHIND
	_ok(not np._frames.has(100), "assemble/prune drops what is far behind")
	_ok(not np._frames.has(floor_frame - 1), "assemble/right up to the floor")
	_ok(np._frames.has(floor_frame), "assemble/and keeps the floor itself")
	_ok(np._frames.has(500) and np._frames.has(600),
		"assemble/never touching the gate or what is ahead of it")
	_ok(not np._local_inputs.has(100) and not np._crc_table.has(100),
		"assemble/every per-frame table is pruned together")

	# A landed handoff is dropped only once the pipeline has posted past it;
	# dropping it early would let a late packet be credited to the wrong peer.
	np._pending[0] = {"frame": 500, "old": 1, "new": 5, "applied": true}
	np._next_post = 500
	np._prune()
	_ok(np._pending.has(0), "assemble/a handoff survives until the gate passes it")
	np._next_post = 501
	np._prune()
	_ok(not np._pending.has(0), "assemble/and is dropped once it has")

	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Cold start ════════════════════════════════════════════════════════════════
# The asynchronous part, and where three of the four cross-platform bugs lived.
# StartContent spins the emulation thread and returns; the core may still be
# missing, refused or wedged. Until it reports an identity there is nothing to
# be ready WITH.

func _test_start() -> void:
	# The host does not invite anyone until its own core is up, because until
	# then it cannot say what build everybody has to match.
	var w := await _pair()
	w.host_sys.lib.ready_after = 6
	var started: bool = w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0)
	_ok(started, "start/the host accepts the request")
	await _await_frames(2)
	_ok(not w.client_sys.started, "start/and invites nobody while its own core comes up")
	_ok(w.host_np.is_active(), "start/but counts as active, so a second press is refused")
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/which it is")
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"start/a slow core still gets there")
	_ok(w.client_sys.started, "start/and the client started its core too")

	# The whole point of fix #2: the peer runs the core the HOST named. Its own
	# default is a per-player, per-platform answer — a core the buildbot ships
	# for Windows may not exist for Android at all.
	_eq(w.client_sys.started_core, "fceumm",
		"start/the client runs the host's core, not its own default")
	_eq(w.host_sys.started_core, "fceumm", "start/and so does the host")
	_ok(w.client_sys.default_core != "fceumm",
		"start/(the client's own default really was something else)")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A peer that cannot start a core at all. This is the cross-platform case:
	# the core is not installed for this platform, or the machine has no
	# cartridge. It must report the failure, never report itself ready.
	w = await _pair()
	w.client_sys.refuse = true
	var stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a peer with no core ends the cold start")
	_ok(not w.host_np.is_running(), "start/rather than leaving the host running alone")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("core"),
		"start/and the reason says so")
	_free(w)

	# A core that comes up but is a DIFFERENT BUILD. Same core name, same ROM,
	# two nightlies: this is what cross-platform play looks like by default,
	# because the four platforms build from four directories at four times.
	w = await _pair()
	w.client_sys.lib.identity = IDENT_A.duplicate()
	w.client_sys.lib.identity["library_version"] = "(SVN 2026-08-20)"
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a peer on a different build of the same core is refused")
	var why: String = str(stops[0] if stops.size() > 0 else "")
	_ok(why.contains("mismatch"), "start/and the reason is the mismatch, not a desync")
	_ok(why.contains("(SVN 2026-08-20)"), "start/naming the build that differs")
	_ok(not w.client_np.is_running(), "start/the refusing peer stops itself too")
	_free(w)

	# The same, one field over: a build whose savestates are a different size.
	# Left alone this surfaces much later, as a failed late join.
	w = await _pair()
	w.client_sys.lib.identity = IDENT_A.duplicate()
	w.client_sys.lib.identity["serialize_size"] = 20000
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a build with different savestates is refused")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("savestate"),
		"start/and the reason names the savestate, not the version")
	_free(w)

	# READINESS MUST NOT COST A FRAME. The gate runs frame 0 only once inputs
	# for it are posted, which happens only once every peer is ready, and being
	# ready IS reporting an identity. A core that only identifies itself after
	# running deadlocks that circle, and it is not a hypothetical: the identity
	# was briefly published after the first retro_run (to keep Dolphin from
	# being asked its savestate size before it had a machine to measure) and
	# every real cold start hung until its deadline.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"start/a normal cold start completes")
	_eq(w.host_sys.lib.frames_at_identity, 0,
		"start/the host answered ready with no frame run")
	_eq(w.client_sys.lib.frames_at_identity, 0,
		"start/and so did the client")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# The same thing from the other side: a core that WILL not identify itself
	# until it has run must fail, not quietly half-start. If this one ever goes
	# green, the gate has stopped gating.
	w = await _pair()
	w.client_sys.lib.identity_needs_frame = true
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return not w.client_np._await_core.is_empty())
	w.client_np._await_deadline = Time.get_ticks_msec() + 150
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a core that identifies itself only after a frame cannot start")
	_eq(w.client_sys.lib.GetFrameCount(), 0,
		"start/because the gate never let it run one")
	_free(w)

	# A core that never comes up. StartContent succeeded, the node exists, and
	# nothing will ever load — the deadline is the only thing between that and
	# a peer that reports ready with no core behind it.
	w = await _pair()
	w.client_sys.lib.ready_after = 1 << 30
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return not w.client_np._await_core.is_empty())
	w.client_np._await_deadline = Time.get_ticks_msec() + 150
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a core that never loads times out")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("did not come up"),
		"start/and says it never came up")
	_free(w)

	# The host's own core failing is a refusal at the door, not a stopped
	# session: nobody was ever invited.
	w = await _pair()
	w.host_sys.refuse = true
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/a host with no core refuses to host")
	_ok(not w.host_np.is_active(), "start/and is left with nothing running")
	_free(w)

	# An unverified core is refused before any of this — the allowlist is the
	# outer gate and nothing about identity can open it.
	w = await _pair()
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "snes9x", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/an unvetted core cannot host")
	_ok(not w.host_sys.started, "start/and its core is never even started")
	_free(w)


# ══ The pipeline ══════════════════════════════════════════════════════════════

func _test_lockstep() -> void:
	var w := await _pair()
	var desyncs: Array = []
	w.host_np.desync_detected.connect(func(pid: int, f: int) -> void: desyncs.append([pid, f]))
	w.host_np._pending_local_route[0] = [0x0F, 100, -200, 0, 0]
	w.client_np._pending_local_route[1] = [0xF0, -50, 75, 0, 0]

	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"lockstep/both peers reach running")
	await _await_frames(240)
	var hc: int = w.host_sys.lib.GetFrameCount()
	var cc: int = w.client_sys.lib.GetFrameCount()
	# Headless ticks are uncapped, so throughput here is latency-bound (about
	# `delay` frames per loopback round trip) rather than one frame per 16.6 ms.
	_ok(hc >= 40, "lockstep/the pipeline flows (%d frames)" % hc)
	_ok(absi(hc - cc) <= 10, "lockstep/and both peers stay together (%d vs %d)" % [hc, cc])
	_eq(desyncs.size(), 0, "lockstep/a clean run reports no desync")

	# One peer stops sending. Lockstep means exactly this: everyone waits.
	var before: int = w.host_sys.lib.GetFrameCount()
	w.client_np._running = false
	await _await_frames(40)
	var during: int = w.host_sys.lib.GetFrameCount()
	_ok(during - before <= 8, "lockstep/a stalled peer freezes the host too (%d to %d)"
		% [before, during])
	w.client_np._running = true
	w.client_np._last_progress_ms = Time.get_ticks_msec()
	await _await_frames(120)
	var after: int = w.host_sys.lib.GetFrameCount()
	_ok(after > during + 10, "lockstep/and the pipeline resumes when it comes back")
	_ok(absi(after - w.client_sys.lib.GetFrameCount()) <= 12,
		"lockstep/reconverging rather than drifting")

	# Stopping while stalled must not deadlock: the host is blocked at the gate
	# and the client is not answering.
	w.client_np._running = false
	await _await_frames(20)
	w.host_nm.netplay_stop("test stop")
	await _await_frames(20)
	_ok(not w.host_np.is_running(), "lockstep/a stop during a stall lands")
	_ok(not w.host_np.is_active(), "lockstep/leaving nothing active")
	_ok(not w.client_np.is_running(), "lockstep/and reaches the stalled peer")
	_ok(w.client_sys.stopped, "lockstep/whose core is stopped, not left running")
	_free(w)


# ══ Desync ════════════════════════════════════════════════════════════════════

func _test_desync() -> void:
	var w := await _pair()
	var desyncs: Array = []
	w.host_np.desync_detected.connect(func(pid: int, f: int) -> void: desyncs.append([pid, f]))
	w.client_sys.lib.desync = true
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return desyncs.size() > 0, 900),
		"desync/a peer whose core diverges is caught")
	_eq(int(desyncs[0][0]) if desyncs.size() > 0 else -1, w.client_id,
		"desync/and named")
	# Three strikes: a peer that will not converge is demoted rather than left
	# stalling the assembler for everyone else.
	_ok(await _until(func() -> bool:
			return w.host_np._spectators.has(w.client_id), 1800),
		"desync/one that keeps diverging becomes a spectator")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)


# ══ Late join ═════════════════════════════════════════════════════════════════

func _test_join() -> void:
	var w := await _pair()
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"join/a game is running to join")
	await _await_frames(60)

	# A third player arrives mid-game. The host stalls everyone, ships a
	# savestate, and resumes once the newcomer has loaded it.
	var third := _branch("J")
	var jsys := MockSys.new()
	jsys.name = "Sys"
	third.add_child(jsys)
	third._netplay.system_override = jsys
	var jnp: NetplaySession = third._netplay
	third.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return w.host_nm.peers.size() == 3),
		"join/the newcomer is in the roster")
	_ok(await _until(func() -> bool: return jnp.is_running(), 900),
		"join/and is running the same game")
	_ok(jsys.started, "join/having started a core of its own")
	_eq(jsys.started_core, "fceumm", "join/the host's core, again")
	_ok(jsys.lib.loaded_state, "join/from the host's savestate rather than from boot")
	_ok(jsys.lib.GetFrameCount() > 0, "join/at the frame the game had reached")
	_ok(await _until(func() -> bool: return not w.host_np._join_paused),
		"join/and the pipeline is running again for everyone")
	var at_resume: int = w.host_sys.lib.GetFrameCount()
	await _await_frames(90)
	_ok(w.host_sys.lib.GetFrameCount() > at_resume, "join/which really does advance")

	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	third.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A newcomer on a different build. The identity check has to hold on the
	# late-join path too, or the one route that ships a savestate between two
	# peers is the one route with no build check on it.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	await _await_frames(40)
	var odd := _branch("K")
	var osys := MockSys.new()
	osys.name = "Sys"
	odd.add_child(osys)
	osys.lib.identity = IDENT_A.duplicate()
	osys.lib.identity["library_version"] = "(SVN 2026-08-19)"
	odd._netplay.system_override = osys
	odd.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return w.host_np._spectators.has(_other_id(w.host_nm, w.client_id)), 900),
		"join/a newcomer on a different build is refused")
	_ok(not osys.lib.loaded_state, "join/and never loads the host's savestate")
	_ok(w.host_np.is_running(), "join/while the running game carries on without them")
	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	odd.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A failed host snapshot must release the gate and demote only the newcomer.
	# Leaving _joining populated here freezes the existing game forever.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	await _await_frames(40)
	w.host_sys.lib.save_fails = true
	var broken := _branch("JF")
	var bsys := MockSys.new()
	bsys.name = "Sys"
	broken.add_child(bsys)
	broken._netplay.system_override = bsys
	broken.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		var newcomer := _other_id(w.host_nm, w.client_id)
		return newcomer > 0 and w.host_np._spectators.has(newcomer), 900),
		"join/a failed host snapshot demotes the newcomer")
	_ok(not w.host_np._join_paused and w.host_np._joining.is_empty(),
		"join/and releases every late-join gate")
	var after_failure: int = w.host_sys.lib.GetFrameCount()
	await _await_frames(90)
	_ok(w.host_sys.lib.GetFrameCount() > after_failure,
		"join/the existing game advances after snapshot failure")
	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	broken.get_parent().queue_free()
	_free(w)


# ══ Somebody leaves ═══════════════════════════════════════════════════════════

func _test_leave() -> void:
	# A port owner walking out stalls the assembler for ever — there is nobody
	# left to supply that port — so the game ends for everyone.
	var w := await _pair()
	var stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()), "leave/a game is running")
	w.host_np.on_peer_left(w.client_id)
	_ok(stops.size() > 0, "leave/a departing port owner ends the game")
	_ok(not w.host_np.is_running(), "leave/for the host too")
	_free(w)

	# A peer that owns nothing is just cleaned up.
	w = await _pair()
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"leave/a one-owner game runs")
	w.host_np.on_peer_left(w.client_id)
	_eq(stops.size(), 0, "leave/a departing spectator does not end it")
	_ok(w.host_np.is_running(), "leave/and it keeps running")

	# A handoff in flight to or from the departed peer would stall the gate at
	# its boundary: nobody supplies that port for the affected frames.
	w.host_np._pending[0] = {"frame": 9999, "old": 1, "new": 4242, "applied": false}
	w.host_np.on_peer_left(4242)
	_ok(stops.size() > 0, "leave/a pending handoff to a departed peer ends it")
	_free(w)


# ══ Rollback and the link cable ═══════════════════════════════════════════════
# Rollback rewinds ONE core. A cabled machine's state is half a conversation, so
# rewinding one end replays a transfer the far end has already answered — and
# both peers are then wrong in the same way, which the CRC checker cannot see.

func _test_rollback() -> void:
	var w := await _pair()
	var owners := {0: 1, 1: w.client_id}

	w.host_sys.lib.link_peers = {}
	_ok(w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1),
		"rollback/an uncabled machine starts")
	_ok(w.host_np._rollback, "rollback/and is allowed to roll back")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	w.host_sys.lib.link_peers = {0: 2}
	_ok(w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1),
		"rollback/a cabled machine still starts")
	_ok(not w.host_np._rollback, "rollback/but in lockstep, whatever was asked for")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# The far port counts too: a console lead sits on port 1, and a guard that
	# only looked at port 0 would wave it straight through.
	w.host_sys.lib.link_peers = {1: 2}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(not w.host_np._rollback, "rollback/a console lead counts as a cable")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# A lead hanging out of a socket with nobody on the far end is not a link,
	# and refusing it would be rollback switched off everywhere.
	w.host_sys.lib.link_peers = {0: 1}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(w.host_np._rollback, "rollback/a lone machine on a bus still rolls back")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# Auto (-1) follows the core's own table rather than anything asked for.
	w.host_sys.lib.link_peers = {}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, -1)
	_eq(w.host_np._rollback, NetplayCores.rollback_capable("fceumm"),
		"rollback/auto asks the core")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)


# ══ A cabled pair ═════════════════════════════════════════════════════════════
# A link cable never crosses the network. LinkCoordinator is a process-wide
# singleton joining two cores in the SAME process, so under netplay every peer
# runs both machines and it is determinism, not a wire, that keeps the two
# buses agreeing.
#
# Which means a cabled pair is one session over TWO machines, and the session
# used to hold exactly one. The far machine was left out: on the host it ran
# anyway (it is in the room), on a client it did not run at all, so the client's
# gated core sat on a bus whose other end never published — and the coordinator
# waits for a peer that is behind rather than guessing, with deliberately no
# timeout. Host fine, client wedged, which is the worst shape a fault can have.

func _test_link() -> void:
	# A topology change cannot land while either local emulation thread is still
	# finishing an earlier frame. The old head-only schedule let the fast core
	# change the bus underneath the slow one.
	var barrier_np := _stub_session()
	var barrier_near := MockSys.new()
	var barrier_far := MockSys.new()
	barrier_np.add_child(barrier_near)
	barrier_np.add_child(barrier_far)
	barrier_near.lib.setup_gate(1, 5)
	barrier_far.lib.setup_gate(1, 4)
	barrier_np._group = [barrier_near, barrier_far]
	barrier_np._libs = [barrier_near.lib, barrier_far.lib]
	barrier_np._lib = barrier_near.lib
	barrier_np._next_post = 5
	barrier_np._frames[5] = barrier_np._flat_from_frame({}, {}, {})
	barrier_np._apply_link_op(1, PackedInt32Array([0, 1]),
		PackedInt32Array([0, 0]), 5)
	barrier_np._drain_to_core()
	_eq(barrier_np._next_post, 5,
		"link/a slow local core holds the topology boundary shut")
	_eq(barrier_near.lib.link_applied.size(), 0,
		"link/so the fast core cannot change the bus underneath it")
	barrier_far.lib.PostNetplayInputs(4, PackedInt32Array())
	barrier_np._drain_to_core()
	_eq(barrier_np._next_post, 6,
		"link/the boundary opens once every local core reaches it")
	_eq(barrier_near.lib.link_applied, [5],
		"link/and topology lands before the boundary frame runs")
	barrier_np.get_parent().queue_free()
	await get_tree().process_frame

	# The control. An uncabled machine is a group of one, and must stay one.
	var w := await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/an uncabled machine starts on its own")
	_eq(w.host_np.group_size(), 1, "link/and is a group of one")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A heterogeneous bus names every machine's core independently. Until both
	# have passed determinism vetting, refuse the session instead of silently
	# booting the far machine with the anchor's unrelated core.
	w = await _pair_cabled()
	w.host_far.machine_core = "snes9x"
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0),
		"link/an unverified far-machine core refuses the whole bus")
	_ok(not w.host_sys.started and not w.host_far.started,
		"link/and no machine is launched with the wrong core")
	_free(w)

	# Build identity is per machine too. Matching anchors must not hide a
	# different far-end build whose savestate and arithmetic can diverge.
	w = await _pair_cabled()
	w.client_far.lib.identity = IDENT_A.duplicate()
	w.client_far.lib.identity["library_version"] = "(different far build)"
	var far_stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: far_stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return far_stops.size() > 0),
		"link/a far-machine build mismatch aborts the start")
	_ok(str(far_stops[0] if not far_stops.is_empty() else "").contains("machine 1"),
		"link/and identifies which machine differs")
	_free(w)

	# The pair. Both peers must bring up BOTH machines, or the bus is asymmetric.
	w = await _pair_cabled()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/a cabled pair starts")
	_eq(w.host_np.group_size(), 2, "link/as a group of two")
	_ok(w.host_far.started, "link/the host runs the far machine")
	_ok(w.client_far.started, "link/and so does the client — the bus needs both ends")
	_eq(w.client_far.started_core, "fceumm",
		"link/the far machine runs the host's core too")
	_eq(w.client_far.resolved_md5, "FAR_MD5",
		"link/the far machine verifies its own cartridge, not the anchor's")
	_eq(w.client_far.received_sram, PackedByteArray([9, 8, 7]),
		"link/and boots from its corresponding host save")
	_ok(w.host_sys.link_refreshes > 0 and w.client_sys.link_refreshes > 0,
		"link/each peer re-seats the bus after restarting its cores")
	w.client_np.set_aux_sensor(w.client_far, 111, -222, 333)
	_ok(w.client_np._local_aux.has(1),
		"link/the far machine can supply its own sensor block")
	_eq((w.client_np._local_aux[1] as Array)[1], 111,
		"link/without writing the anchor's sensor block")
	_ok(w.client_np.queue_key_event(w.client_far, 65, true, 97),
		"link/the far machine can queue its own keyboard input")
	_ok(w.client_np._local_keys.has(1),
		"link/and the event is scoped to that machine")

	# Ports are per machine, so the second machine's pad is a different port
	# from the first machine's pad, and both are in the same frame.
	await _await_frames(120)
	_ok(w.host_far.lib.GetFrameCount() > 0, "link/the far machine is actually running")
	_ok(absi(w.host_far.lib.GetFrameCount() - w.client_far.lib.GetFrameCount()) <= 10,
		"link/in step across peers, like the near one")
	_ok(absi(w.host_sys.lib.GetFrameCount() - w.host_far.lib.GetFrameCount()) <= 10,
		"link/and in step with the machine it is cabled to")
	var far_controller := MockController.new()
	far_controller._connected_system = w.host_far
	far_controller._port_index = 0
	w.host_nm.add_child(far_controller)
	w.host_np.handoff_controller(far_controller, 1)
	_ok(w.host_np._pending.has(4),
		"link/a controller on the far machine hands off its global port")
	w.host_np.schedule_disk_op(w.host_far, 0, "", 2)
	w.host_np.schedule_disk_op(w.host_far, 1, "FAR_DISC", 2)
	_ok(await _until(func() -> bool:
		return w.host_far.lib.disc_ops.size() == 2 and w.client_far.lib.disc_ops.size() == 2),
		"link/a far machine's disc operation reaches both peers")
	_eq(w.host_far.lib.disc_ops[0][0], w.host_far.lib.disc_ops[1][0],
		"link/rapid eject and replace keep both operations at one boundary")
	_ok(await _until(func() -> bool: return w.host_np._disc_waiting.is_empty()),
		"link/and every peer arms it before assembly resumes")
	_eq(w.host_sys.lib.disc_ops.size(), 0,
		"link/without being applied to the anchor machine")
	w.host_np.schedule_reset(w.host_far)
	_ok(await _until(func() -> bool:
		return w.host_far.lib.reset_ops.size() == 1 \
			and w.client_far.lib.reset_ops.size() == 1),
		"link/a far machine reset reaches both peers")
	_eq(w.host_far.lib.reset_ops[0], w.client_far.lib.reset_ops[0],
		"link/the reset lands on the same emulated frame")
	_ok(w.host_far.reset_visuals == 1 and w.client_far.reset_visuals == 1,
		"link/the reset effect is shown on both peers")
	_eq(w.host_sys.lib.reset_ops.size(), 0,
		"link/without resetting another machine in the group")
	_ok(await _until(func() -> bool: return w.host_np._reset_waiting.is_empty()),
		"link/and every peer arms the reset before assembly resumes")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_ok(w.host_far.stopped and w.client_far.stopped,
		"link/stopping the session stops every machine in it")
	_free(w)

	# Seating a plug mid-game changes deterministic state on both cores, so it
	# has to land on the SAME emulated frame everywhere — the same rule as a
	# disc swap. Applying it the instant a hand moves forks the session.
	w = await _pair_cabled()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 4: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running())
	await _await_frames(60)
	# The HEAD of the bus applies the op while every core is still gated below
	# the boundary frame, before that frame is posted to any of them.
	var applied: Array = []
	w.host_sys.lib.link_applied = applied
	var client_applied: Array = []
	w.client_sys.lib.link_applied = client_applied
	w.host_np.schedule_link_op(w.host_sys, 1, [0, 1], [0, 0])
	_eq(applied.size(), 0, "link/a plug seated mid-game is not applied at once")
	_ok(await _until(func() -> bool: return applied.size() > 0 and client_applied.size() > 0),
		"link/it reaches every peer")
	_eq(int(applied[0]) if applied.size() > 0 else -1,
		int(client_applied[0]) if client_applied.size() > 0 else -2,
		"link/and lands on the same frame on both")

	# And a pull is the same decision in reverse.
	applied.clear()
	client_applied.clear()
	w.host_np.schedule_link_op(w.host_sys, 0, [0], [0])
	_eq(applied.size(), 0, "link/pulling a plug is not applied at once either")
	_ok(await _until(func() -> bool: return applied.size() > 0 and client_applied.size() > 0),
		"link/it too reaches every peer")
	_eq(int(applied[0]) if applied.size() > 0 else -1,
		int(client_applied[0]) if client_applied.size() > 0 else -2,
		"link/on one agreed frame")

	# More than one cable can move before the same future boundary. A map keyed
	# only by frame used to let the second event erase the first.
	applied.clear()
	client_applied.clear()
	w.host_np.schedule_link_op(w.host_sys, 1, [0, 1], [0, 0])
	w.host_np.schedule_link_op(w.host_sys, 0, [0], [0])
	_ok(await _until(func() -> bool: return applied.size() >= 2 and client_applied.size() >= 2),
		"link/two operations sharing a frame both land")
	_eq(applied.slice(0, 2), client_applied.slice(0, 2),
		"link/and land at the same boundaries on both peers")

	# A core savestate does not serialize the process-wide LinkCoordinator bus.
	# A newcomer may watch, but must not load two cores without that missing bus
	# state and pretend to be a participant.
	var linked_joiner := _branch("LJ")
	linked_joiner.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		var newcomer := _other_id(w.host_nm, w.client_id)
		return newcomer > 0 and w.host_np._spectators.has(newcomer), 900),
		"link/a late joiner to a linked game remains a spectator")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	linked_joiner.get_parent().queue_free()
	_free(w)


# ══ Mocks ═════════════════════════════════════════════════════════════════════

## The C++ frame gate, a deterministic RAM CRC, and a core identity that appears
## only once "content has loaded" — which is what makes the cold-start cases
## mean anything.
class MockLib extends Node:
	signal netplay_crc(frame: int, crc: int)
	signal savestate_ready(data: PackedByteArray, frame: int)
	signal savestate_loaded(ok: bool)

	var identity: Dictionary = {"library_name": "FCEUmm", "library_version": "(SVN)",
		"api_version": 1, "serialize_size": 13701}
	## Process frames between the core being started and it reporting itself up.
	## The real thing loads on another thread; 0 here is the lucky case, not the
	## normal one.
	var ready_after := 0
	## Model a core that only reports itself once it has RUN a frame. The real
	## Wrapper must never behave this way and the start/ group proves why: under
	## the gate no frame runs until every peer is ready, and readiness is the
	## identity, so the two wait on each other for ever.
	var identity_needs_frame := false
	## The frame count at the moment the identity first became available, so a
	## case can assert a peer answered ready without its core having run.
	var frames_at_identity := -1
	var desync := false
	var loaded_state := false
	var save_fails := false
	var link_peers: Dictionary = {}
	## Frames at which a scheduled link op landed on this core, appended in
	## order. A case hands in its own array so it can watch a single window.
	var link_applied: Array = []
	var disc_ops: Array = []
	var reset_ops: Array = []

	var _count := 0
	var _acc := 0
	var _enabled := false
	var _ticks := -1
	var _start_frame := 0

	func _process(_d: float) -> void:
		if _ticks >= 0:
			_ticks += 1

	func GetCoreIdentity() -> Dictionary:
		if _ticks < 0 or _ticks < ready_after:
			return {}
		if identity_needs_frame and _count <= _start_frame:
			return {}
		if frames_at_identity < 0:
			frames_at_identity = _count - _start_frame
		return identity

	func LinkPeerCount(port: int) -> int:
		return int(link_peers.get(port, 0))

	func LinkConnectGroup(_peers: Array, _ports: PackedInt32Array) -> bool:
		link_applied.append(_count)
		return true

	func LinkDisconnect(_port: int) -> void:
		link_applied.append(_count)

	func ScheduleDiscOp(frame: int, op: int, index: int, path: String) -> void:
		disc_ops.append([frame, op, index, path])

	func ScheduleReset(frame: int) -> void:
		reset_ops.append(frame)

	func setup_gate(_mask: int, start_frame: int) -> void:
		_enabled = true
		_ticks = 0
		_count = start_frame
		_start_frame = start_frame
		frames_at_identity = -1
		_acc = start_frame          # deterministic seed, identical across peers

	func stop() -> void:
		_enabled = false
		_ticks = -1

	func GetFrameCount() -> int:
		return _count

	func PostNetplayInputs(frame: int, flat: PackedInt32Array) -> void:
		if not _enabled or frame != _count:
			return                  # the gate: only the expected next frame runs
		var h := frame
		for v in flat:
			h = (h * 1103515245 + int(v) + 12345) & 0x3FFFFFFF
		_acc = (_acc ^ h) & 0x3FFFFFFF
		_count += 1
		if _count % 60 == 0:
			netplay_crc.emit(_count, (_acc ^ 0xABCDE) & 0x3FFFFFFF if desync else _acc)

	func RequestSaveState() -> void:
		if save_fails:
			savestate_ready.emit(PackedByteArray(), _count)
			return
		var d := PackedByteArray()
		d.resize(8)
		d.encode_s64(0, _acc)
		savestate_ready.emit(d, _count)

	func RequestLoadState(data: PackedByteArray, frame: int) -> void:
		_count = frame
		_acc = data.decode_s64(0) if data.size() >= 8 else frame
		_enabled = true
		loaded_state = true
		savestate_loaded.emit(true)


## The net_start_core / net_stop_core seam. `default_core` is deliberately not
## the core any test hosts with: a peer taking its OWN default is the bug the
## start/ group is about.
class MockSys extends Node:
	var lib: MockLib
	var default_core := "nestopia"
	var refuse := false             # this machine cannot start a core at all
	var started := false
	var stopped := false
	var started_core := ""
	var machine_core := "fceumm"
	var rom_md5 := "MD5"
	var rom_path := "mock.rom"
	var resolved_md5 := ""
	var sram_bytes := PackedByteArray()
	var received_sram := PackedByteArray()
	var link_refreshes := 0
	var reset_visuals := 0
	## The machines on this one's link bus, itself included, or empty when the
	## machine is not cabled to anything. This is the seam the session asks
	## through, so a probe needs no cables and no room.
	var link_group: Array = []

	func net_play_reset() -> void:
		reset_visuals += 1

	func _init() -> void:
		lib = MockLib.new()
		lib.name = "Lib"
		add_child(lib)

	func get_libretro_node() -> Node:
		return lib

	func net_start_core(core: String, port_mask: int, start_frame: int, _options: Dictionary) -> Node:
		if refuse:
			return null
		started = true
		stopped = false
		started_core = core if not core.is_empty() else default_core
		lib.setup_gate(port_mask, start_frame)
		return lib

	func net_stop_core() -> void:
		stopped = true
		lib.stop()

	func resolve_core_name() -> String:
		return machine_core

	func net_rom_md5() -> String:
		return rom_md5

	func net_resolve_rom(md5: String) -> bool:
		resolved_md5 = md5
		return true

	func net_sram_file_bytes() -> PackedByteArray:
		return sram_bytes

	func net_set_sram(_path: String, data: PackedByteArray) -> void:
		received_sram = data

	func net_link_group() -> Array:
		return link_group

	func net_refresh_link_cables() -> void:
		link_refreshes += 1


class MockController extends Node:
	var _connected_system: Object = null
	var _port_index := -1


## A NetworkManager stand-in for the cases that need a session but no network.
class StubNM extends Node:
	var peers: Dictionary = {1: {}}
	var _object_sync: Node = null
	var host := true

	func is_host() -> bool:
		return host


# ══ Harness ═══════════════════════════════════════════════════════════════════

class Pair:
	var host_nm: Node
	var client_nm: Node
	var host_sys: MockSys
	var client_sys: MockSys
	var host_np: NetplaySession
	var client_np: NetplaySession
	var client_id := -1
	## The far end of a link cable, when the pair was built cabled. Each peer
	## replicates BOTH machines, so there are two of these, one per branch.
	var host_far: MockSys
	var client_far: MockSys


## A session with a stub parent and no multiplayer peer, for the pure cases.
func _stub_session() -> NetplaySession:
	var nm := StubNM.new()
	add_child(nm)
	var np := NetplaySession.new()
	np.name = "Netplay"
	nm.add_child(np)
	return np


## One NetworkManager under its own SceneMultiplayer, so two of them can talk
## over loopback inside this one process.
func _branch(bname: String) -> Node:
	var root := Node.new()
	root.name = bname
	add_child(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	var nm := NM_SCRIPT.new()
	nm.name = "NetworkManager"
	nm.world_root = root
	nm.pose_source = func() -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(nm)
	return nm


## A connected host + client, each with a mock machine wired into its session.
func _pair() -> Pair:
	var p := Pair.new()
	p.host_nm = _branch("H%d" % _ran)
	p.client_nm = _branch("C%d" % _ran)
	p.host_sys = MockSys.new()
	p.host_sys.name = "Sys"
	p.host_nm.add_child(p.host_sys)
	p.client_sys = MockSys.new()
	p.client_sys.name = "Sys"
	p.client_nm.add_child(p.client_sys)
	p.host_np = p.host_nm._netplay
	p.client_np = p.client_nm._netplay
	p.host_np.system_override = p.host_sys
	p.client_np.system_override = p.client_sys
	p.host_nm.host_game(PORT)
	# Godot 4.7's ENet loopback is IPv6-only on some Linux hosts even though
	# ordinary IPv4 UDP works there.  This is an in-process transport test, so
	# use the native loopback address and leave LAN address coverage to device QA.
	p.client_nm.join_game("::1", PORT)
	if not await _until(func() -> bool:
			return p.host_nm.peers.size() == 2 and p.client_nm.peers.size() == 2):
		_ok(false, "harness/the two peers never connected")
		return p
	p.client_id = _other_id(p.host_nm, 1)
	return p


## The same pair with a second machine cabled to the first on both peers. Every
## peer replicates the whole bus, so each branch gets its own far machine, and
## the session is told about it through net_link_group().
func _pair_cabled() -> Pair:
	var p := await _pair()
	p.host_far = MockSys.new()
	p.host_far.name = "Far"
	p.host_far.rom_md5 = "FAR_MD5"
	p.host_far.sram_bytes = PackedByteArray([9, 8, 7])
	p.host_nm.add_child(p.host_far)
	p.client_far = MockSys.new()
	p.client_far.name = "Far"
	p.client_far.rom_md5 = "LOCAL_OTHER"
	p.client_nm.add_child(p.client_far)
	# Two machines with a lead between them: each names the whole bus, itself
	# first, and the session takes the order from the machine it was started on.
	p.host_sys.link_group = [p.host_sys, p.host_far]
	p.host_far.link_group = [p.host_sys, p.host_far]
	p.client_sys.link_group = [p.client_sys, p.client_far]
	p.client_far.link_group = [p.client_sys, p.client_far]
	# Both cores report themselves cabled, which is also what stops rollback.
	for lib: MockLib in [p.host_sys.lib, p.host_far.lib, p.client_sys.lib, p.client_far.lib]:
		lib.link_peers = {0: 2}
	# Each branch resolves its own two machines by the group's net ids.
	p.host_np.systems_override = {0: p.host_sys, 1: p.host_far}
	p.client_np.systems_override = {0: p.client_sys, 1: p.client_far}
	return p


func _other_id(nm: Node, exclude: int) -> int:
	for id: int in nm.peers:
		if id != 1 and id != exclude:
			return id
	for id: int in nm.peers:
		if id != 1:
			return id
	return -1


func _free(p: Pair) -> void:
	for nm: Node in [p.host_nm, p.client_nm]:
		if is_instance_valid(nm):
			nm.leave_session("test over")
			if is_instance_valid(nm.get_parent()):
				nm.get_parent().queue_free()


func _await_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _until(cond: Callable, ticks := 600) -> bool:
	for _i in range(ticks):
		await get_tree().process_frame
		if cond.call():
			return true
	return false


func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ran += 1
	if got == want:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s — got %s, want %s" % [what, str(got), str(want)])
