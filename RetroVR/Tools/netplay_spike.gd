## Netplay determinism spike (M4a) — vets a core for lockstep netplay.
##
## Runs the core under the netplay frame gate with a deterministic scripted
## input timeline, savestates mid-run, replays from the state, and compares
## RAM CRC checkpoints. A core PASSES when the replay CRCs are identical.
## Run the tool twice and diff the [crc] lines to also verify cold-start
## determinism across processes (and across machines/architectures).
##
## Usage (windowed; needs the GDExtension + a real core/ROM):
##   godot --path RetroVR --rendering-driver opengl3 res://Tools/netplay_spike.tscn \
##     -- --spike-core=fceumm "--spike-rom=C:/path/to/rom.nes"
extends Node3D

var root_dir := "C:/Users/user/retrovr/libretro"
var core := "fceumm"
var rom := "C:/Users/user/retrovr/roms/nes/probe.nes"

const SAVE_AT := 600
const END_AT := 1800

var _lib: Node = null
var _mesh: MeshInstance3D = null
var _next_feed := 0
var _crc_a := {}
var _crc_b := {}
var _phase := "A"
var _state_data := PackedByteArray()
var _state_frame := -1
var _saved := false
var _done := false


func _ready() -> void:
	# Android/adb path: args come from user://spike.cfg (one --spike-* per
	# line), planted by NetworkManager's QA hook. Delete it IMMEDIATELY so a
	# crashing run can't wedge the app into spike mode.
	var cfg_args: PackedStringArray = []
	if FileAccess.file_exists("user://spike.cfg"):
		var f := FileAccess.open("user://spike.cfg", FileAccess.READ)
		if f:
			cfg_args = f.get_as_text().split("\n", false)
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://spike.cfg"))
	for arg: String in OS.get_cmdline_user_args() + cfg_args:
		arg = arg.strip_edges()
		if arg.begins_with("--spike-core="):
			core = arg.trim_prefix("--spike-core=")
		elif arg.begins_with("--spike-rom="):
			rom = arg.trim_prefix("--spike-rom=")
		elif arg.begins_with("--spike-root="):
			root_dir = arg.trim_prefix("--spike-root=")
	get_tree().create_timer(110.0).timeout.connect(func() -> void:
		var f: int = _lib.GetFrameCount() if _lib else -1
		print("[spike] TIMEOUT phase=%s frame=%d" % [_phase, f])
		get_tree().quit(1))
	_mesh = MeshInstance3D.new()
	_mesh.mesh = QuadMesh.new()
	add_child(_mesh)
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	add_child(_lib)
	_lib.connect("netplay_crc", _on_crc)
	_lib.connect("savestate_ready", _on_state_ready)
	_lib.connect("savestate_loaded", _on_state_loaded)
	# Gate BEFORE starting content: the core holds at frame 0 until inputs post.
	_lib.SetNetplayMode(true, 0x1, 0)
	_lib.StartContent(_mesh, root_dir, core, rom)
	print("[spike] started %s / %s" % [core, rom.get_file()])


## Deterministic scripted play: START to get in-game, then run right with
## periodic jumps — same function drives both phases.
func _input_for_frame(f: int) -> int:
	var btn := 0
	if (f >= 180 and f < 195) or (f >= 300 and f < 320):
		btn |= 1 << 3          # START
	if f >= 400:
		btn |= 1 << 7          # RIGHT
		if (f % 90) < 25:
			btn |= 1 << 8      # A (jump)
		if (f % 51) < 10:
			btn |= 1 << 0      # B (run)
	return btn


func _flat(f: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(20)
	arr[0] = _input_for_frame(f)
	return arr


func _process(_delta: float) -> void:
	if _done or _lib == null or _phase == "B_LOADING":
		return
	var cur: int = _lib.GetFrameCount()
	while _next_feed < cur + 90:
		_lib.PostNetplayInputs(_next_feed, _flat(_next_feed))
		_next_feed += 1
	if _phase == "A" and not _saved and cur >= SAVE_AT:
		_saved = true
		_lib.RequestSaveState()
	elif _phase == "B" and cur >= END_AT + 30:
		_finish()


func _on_crc(frame: int, crc: int) -> void:
	if _phase == "A":
		print("[crc] %d %08x" % [frame, crc])
		_crc_a[frame] = crc
		if frame >= END_AT and _state_frame >= 0:
			_phase = "B_LOADING"
			print("[spike] phase A done (%d checkpoints) — loading state @%d" % [_crc_a.size(), _state_frame])
			_lib.RequestLoadState(_state_data, _state_frame)
	elif _phase == "B":
		_crc_b[frame] = crc


func _on_state_ready(data: PackedByteArray, frame: int) -> void:
	print("[spike] savestate captured: %d bytes at frame %d" % [data.size(), frame])
	if data.is_empty():
		print("[spike] RESULT=FAIL (core has no savestate support)")
		get_tree().quit(1)
		return
	_state_data = data
	_state_frame = frame


func _on_state_loaded(ok: bool) -> void:
	print("[spike] state loaded ok=%s — replaying from %d" % [ok, _state_frame])
	if not ok:
		print("[spike] RESULT=FAIL (unserialize failed)")
		get_tree().quit(1)
		return
	_next_feed = _state_frame
	_phase = "B"


func _finish() -> void:
	_done = true
	var mismatches := 0
	var compared := 0
	for f: int in _crc_b:
		if f <= _state_frame or f > END_AT:
			continue
		if _crc_a.has(f):
			compared += 1
			if int(_crc_a[f]) != int(_crc_b[f]):
				mismatches += 1
				print("[spike] MISMATCH frame %d: A=%08x B=%08x" % [f, _crc_a[f], _crc_b[f]])
	var ok := compared >= 15 and mismatches == 0
	print("[spike] compared %d CRC checkpoints after reload, %d mismatches" % [compared, mismatches])
	print("[spike] RESULT=%s" % ("PASS" if ok else "FAIL"))
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)
