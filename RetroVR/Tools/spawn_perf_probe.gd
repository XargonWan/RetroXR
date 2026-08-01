## Times a spawn on the device it actually feels slow on.
##
## Desktop numbers were misleading: there the whole cabinet lands in 90-320 ms,
## while on Quest a stand-in reportedly takes seconds. Storage is far slower here
## and the CPU several times slower, and pipeline compilation on the mobile
## backend is a different animal — those need opposite fixes, so they get split
## apart per phase and per repeat rather than guessed at.
##
## Ships as its own package (see the QuestSpawnProbe preset) so the installed
## RetroVR is never touched.
extends Node3D

## [model_id, systemid]
const CASES := [
	["n3ds_primitive", "3ds"],
	["game_boy_primitive", "game_boy"],
	["placeholder", "playstation2"],
	["nes", "nes"],
]
const REPEATS := 3

var _frames := 0
var _alive := 0.0


func _us() -> int: return Time.get_ticks_usec()
func _ms(a: int) -> float: return float(_us() - a) / 1000.0


func _process(delta: float) -> void:
	# Heartbeat: tells "process died" apart from "process running, not ticking".
	_frames += 1
	_alive += delta
	if _frames % 120 == 0:
		print("[perf] alive t=%.1f frames=%d" % [_alive, _frames])


func _ready() -> void:
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[perf] TIMEOUT")
		get_tree().quit(1))
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.25, 0.6)
	cam.rotation_degrees = Vector3(-18, 0, 0)
	add_child(cam)
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 25, 0)
	add_child(light)
	await _run()
	get_tree().quit(0)


func _run() -> void:
	print("[perf] device=%s renderer=%s" % [OS.get_name(), RenderingServer.get_video_adapter_name()])
	print("[perf] %-22s %-5s %8s %8s %8s %8s %9s" %
		["case", "pass", "load", "inst", "ready", "draw", "TOTAL"])
	for c: Array in CASES:
		for pass_i in REPEATS:
			await _one(c, pass_i)
	print("[perf] DONE")


func _one(c: Array, pass_i: int) -> void:
	var row := SystemModelRegistry._row(c[0] as String) if c[0] != "placeholder" \
		else SystemModelRegistry.placeholder_row()
	var path: String = row.get("scene", "")

	var t := _us()
	if not path.is_empty():
		SystemModelRegistry.packed_scene(path)
	var t_load := _ms(t)

	t = _us()
	var sys := load("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	sys.systemid = c[1]
	sys.model_id = c[0]
	var t_inst := _ms(t)

	t = _us()
	add_child(sys)
	sys.freeze = true
	sys.ignore_gravity = true
	sys.position = Vector3(0, 0, 0)
	var t_ready := _ms(t)

	t = _us()
	await RenderingServer.frame_post_draw
	var t_draw := _ms(t)

	print("[perf] %-22s %-5d %7.1f %7.1f %7.1f %7.1f %8.1f" %
		[c[0], pass_i + 1, t_load, t_inst, t_ready, t_draw,
			t_load + t_inst + t_ready + t_draw])
	for i in 5:
		await get_tree().process_frame
	sys.queue_free()
	for i in 5:
		await get_tree().process_frame
