## Headless two-branch probe for NetplaySession (M4b).
##
## Drives the real NetworkManager + NetplaySession over loopback ENet with a
## MOCK core+system (no HW render, no real libretro), so the lockstep
## orchestration is testable without a display:
##   A. cold-start 2-player lockstep advances in step and RAM CRCs agree
##   B. a stalled peer freezes the pipeline, then resumes cleanly
##   C. stopping during a stall tears down without deadlock/errors
##   D. a diverging peer's CRC is detected (desync_detected)
##
## The mock core simulates the C++ frame gate: it runs frame N only when
## PostNetplayInputs(N) arrives in order, and emits a deterministic RAM CRC every
## 60 frames folded from the exact inputs posted — so two peers fed the same
## assembled frames produce identical CRC streams (real determinism is separately
## proven by netplay_spike.gd against an actual core).
##
## Run: godot --headless --path RetroXR res://Tools/netplay_session_probe.tscn
extends Node

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const PORT := 42911

var _fail := false


# ── Mock core: simulates the C++ netplay gate + deterministic RAM CRC ─────────
class MockLib extends Node:
	signal netplay_crc(frame: int, crc: int)
	signal savestate_ready(data: PackedByteArray, frame: int)
	signal savestate_loaded(ok: bool)
	var _count := 0
	var _acc := 0
	var _enabled := false
	var desync := false
	## How many machines are on each of this core's link bus ports. The guard
	## asks the CORE whether it is cabled, so the mock has to be able to say.
	var link_peers: Dictionary = {}

	func LinkPeerCount(port: int) -> int:
		return int(link_peers.get(port, 0))

	func setup_gate(_mask: int, start_frame: int) -> void:
		_enabled = true
		_count = start_frame
		_acc = start_frame          # deterministic seed → identical across peers
	func stop() -> void:
		_enabled = false
	func GetFrameCount() -> int:
		return _count
	func PostNetplayInputs(frame: int, flat: PackedInt32Array) -> void:
		if not _enabled or frame != _count:
			return                  # gate: only the expected next frame runs
		var h := frame
		for v in flat:
			h = (h * 1103515245 + int(v) + 12345) & 0x3FFFFFFF
		_acc = (_acc ^ h) & 0x3FFFFFFF
		_count += 1
		if _count % 60 == 0:
			var c := _acc
			if desync:
				c = (c ^ 0xABCDE) & 0x3FFFFFFF
			netplay_crc.emit(_count, c)
	func RequestSaveState() -> void:
		var d := PackedByteArray()
		d.resize(8)
		d.encode_s64(0, _acc)
		savestate_ready.emit(d, _count)
	func RequestLoadState(data: PackedByteArray, frame: int) -> void:
		_count = frame
		_acc = data.decode_s64(0) if data.size() >= 8 else frame
		_enabled = true
		savestate_loaded.emit(true)


# ── Mock system: the net_start_core / net_stop_core seam the session drives ────
class MockSys extends Node:
	var lib: MockLib
	func _init() -> void:
		lib = MockLib.new()
		lib.name = "Lib"
		add_child(lib)
	func get_libretro_node() -> Node:
		return lib
	func net_start_core(port_mask: int, start_frame: int, _options: Dictionary) -> Node:
		lib.setup_gate(port_mask, start_frame)
		return lib
	func net_stop_core() -> void:
		lib.stop()


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT — aborting")
		get_tree().quit(1))
	_run()


func _await_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _make_branch(bname: String) -> Node:
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


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[probe] FAIL: %s" % msg)


func _run() -> void:
	var host_nm := _make_branch("H")
	var client_nm := _make_branch("C")
	# Attach mock systems and inject them into each branch's session.
	var host_sys := MockSys.new(); host_sys.name = "Sys"; host_nm.add_child(host_sys)
	var client_sys := MockSys.new(); client_sys.name = "Sys"; client_nm.add_child(client_sys)
	host_nm._netplay.system_override = host_sys
	client_nm._netplay.system_override = client_sys

	host_nm.host_game(PORT)
	client_nm.join_game("127.0.0.1", PORT)

	# Wait for the handshake (client appears in the host roster).
	var connected := false
	for _i in range(300):
		await get_tree().process_frame
		if host_nm.peers.size() == 2 and client_nm.peers.size() == 2:
			connected = true
			break
	if not connected:
		print("[probe] FAIL: handshake did not complete")
		return get_tree().quit(1)
	var client_id := -1
	for id: int in host_nm.peers:
		if id != 1:
			client_id = id
	print("[probe] connected — client peer id %d" % client_id)

	var host_np: NetplaySession = host_nm._netplay
	var client_np: NetplaySession = client_nm._netplay
	var desyncs: Array = []
	host_np.desync_detected.connect(func(pid: int, f: int) -> void: desyncs.append([pid, f]))

	# Non-trivial inputs so CRCs fold something real (host owns 0, client owns 1).
	host_np._pending_local_route[0] = [0x0F, 100, -200, 0, 0]
	client_np._pending_local_route[1] = [0xF0, -50, 75, 0, 0]

	# ── Phase A: cold-start lockstep ──────────────────────────────────────────
	# rollback=0: this probe's mock core implements the lockstep gate only —
	# rollback correctness is proven by the real-core netplay_spike.
	var ok: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 0)
	_fail_if(not ok, "netplay_start_host returned false")
	# Wait until running on both peers.
	var running := false
	for _i in range(120):
		await get_tree().process_frame
		if host_np.is_running() and client_np.is_running():
			running = true
			break
	_fail_if(not running, "sessions did not reach running")
	await _await_frames(240)
	var hcount: int = host_sys.lib.GetFrameCount()
	var ccount: int = client_sys.lib.GetFrameCount()
	print("[probe] A: host frame=%d client frame=%d desyncs=%d" % [hcount, ccount, desyncs.size()])
	# Headless ticks are uncapped/sub-ms, so throughput here is latency-bound
	# (~delay frames per loopback round-trip), not the 1-frame-per-16.6ms a real
	# 60 Hz session needs. 40+ frames in 240 ticks proves the pipeline flows.
	_fail_if(hcount < 40, "host did not advance enough (%d)" % hcount)
	_fail_if(absi(hcount - ccount) > 10, "host/client frames diverged (%d vs %d)" % [hcount, ccount])
	_fail_if(desyncs.size() != 0, "unexpected desync during clean run")

	# ── Phase B: stall then resume ────────────────────────────────────────────
	var before_pause: int = host_sys.lib.GetFrameCount()
	client_np._running = false          # client stops sending/advancing (stall)
	await _await_frames(40)
	var during_pause: int = host_sys.lib.GetFrameCount()
	print("[probe] B: host frame before=%d during-stall=%d" % [before_pause, during_pause])
	_fail_if(during_pause - before_pause > 8, "host did not stall while peer paused (%d→%d)" % [before_pause, during_pause])
	client_np._running = true            # resume
	client_np._last_progress_ms = Time.get_ticks_msec()
	await _await_frames(120)
	var after_resume: int = host_sys.lib.GetFrameCount()
	var cafter: int = client_sys.lib.GetFrameCount()
	print("[probe] B: host frame after-resume=%d client=%d" % [after_resume, cafter])
	_fail_if(after_resume <= during_pause + 10, "pipeline did not resume after stall")
	_fail_if(absi(after_resume - cafter) > 12, "peers did not reconverge after stall")

	# ── Phase C: clean stop during a stall (no deadlock/errors) ───────────────
	client_np._running = false           # induce a stall again
	await _await_frames(20)
	host_nm.netplay_stop("probe stop")
	await _await_frames(20)
	print("[probe] C: host running=%s client running=%s" % [host_np.is_running(), client_np.is_running()])
	_fail_if(host_np.is_running(), "host still running after stop")
	_fail_if(host_np.is_active(), "host still active after stop")
	# Client learns via the reliable _np_stop broadcast.
	_fail_if(client_np.is_running(), "client still running after stop")

	# ── Phase D: desync detection ─────────────────────────────────────────────
	desyncs.clear()
	host_sys.lib.desync = false
	client_sys.lib.desync = true         # client's core will diverge
	host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	var ok2: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 0)
	_fail_if(not ok2, "restart for desync test failed")
	# Run long enough to cross at least one CRC checkpoint (60 frames) + relay.
	var detected := false
	for _i in range(400):
		await get_tree().process_frame
		if desyncs.size() > 0:
			detected = true
			break
	print("[probe] D: desync detected=%s (%d events)" % [detected, desyncs.size()])
	_fail_if(not detected, "diverging peer CRC was not detected")
	host_nm.netplay_stop("probe done")
	await _await_frames(10)

	# ── Phase E: a cabled machine refuses rollback ────────────────────────────
	# Rollback rewinds one core, and a cabled machine's state is half a
	# conversation: rewinding one end replays a transfer the far end already
	# answered. Both peers would be wrong the same way, so the CRC checker
	# cannot even see it. Asking for rollback on a linked machine has to come
	# back as lockstep, and asking for it on an UNCABLED one still has to work,
	# or the guard is just rollback switched off everywhere.
	desyncs.clear()
	client_sys.lib.desync = false
	host_sys.lib.link_peers = {}
	client_sys.lib.link_peers = {}
	var ok3: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 1)
	_fail_if(not ok3, "rollback start failed")
	print("[probe] E: uncabled, asked for rollback -> rollback=%s" % host_np._rollback)
	_fail_if(not host_np._rollback, "an uncabled machine was denied rollback")
	host_nm.netplay_stop("probe done")
	await _await_frames(10)

	# Same request, same core, one cable in it.
	host_sys.lib.link_peers = {0: 2}
	var ok4: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 1)
	_fail_if(not ok4, "linked start failed")
	print("[probe] E: cabled, asked for rollback -> rollback=%s" % host_np._rollback)
	_fail_if(host_np._rollback, "a cabled machine was started in rollback")

	# And the far port counts too: a GameCube lead sits on port 1, not port 0,
	# and a guard that only looked at port 0 would wave it through.
	host_nm.netplay_stop("probe done")
	await _await_frames(10)
	host_sys.lib.link_peers = {1: 2}
	var ok5: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 1)
	_fail_if(not ok5, "console-lead start failed")
	print("[probe] E: on a console lead -> rollback=%s" % host_np._rollback)
	_fail_if(host_np._rollback, "a machine on a console lead was started in rollback")

	# A lead hanging out of the socket with nobody on the far end is not a link.
	host_nm.netplay_stop("probe done")
	await _await_frames(10)
	host_sys.lib.link_peers = {0: 1}
	var ok6: bool = host_nm.netplay_start_host(host_sys, "fceumm", "MD5", {0: 1, 1: client_id}, 3, 1)
	_fail_if(not ok6, "lone-port start failed")
	print("[probe] E: alone on the bus -> rollback=%s" % host_np._rollback)
	_fail_if(not host_np._rollback, "a machine alone on a bus was denied rollback")
	host_nm.netplay_stop("probe done")
	await _await_frames(10)

	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
