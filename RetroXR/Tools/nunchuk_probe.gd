## Does a second accelerometer actually cross into a running core?
##
##     "$godot" --path RetroXR res://Tools/nunchuk_probe.tscn 2>&1 | grep -a "sub-device"
##
## Needs a real Dolphin core and a real Wii disc, which is why this is a probe
## and not a test. Everything decidable without one is in Tests/motion_tests.
##
## The oracle is the FRONTEND's own log, not anything printed here. InputHandler
## prints one line per sub-device a core enables, so a good run reads:
##
##     Sensor: accelerometer enabled on port 0 sub-device 0 rate=60
##     Sensor: gyroscope enabled on port 0 sub-device 0 rate=60
##     Sensor: accelerometer enabled on port 0 sub-device 1 rate=60
##
## That third line is the whole handshake: the core encoded the sub-device into
## the action, the frontend decoded it, and answered yes. Its absence with the
## first two present is a core that never asked. There is deliberately no
## gyroscope line for sub-device 1, because a Nunchuk has no gyroscope.
##
## It is also how the compatibility claim was checked. Build the frontend with
## MAX_SENSOR_INDEX at 1 and run this again: the sub-device 1 line goes away,
## sub-device 0 is untouched, and the core boots and runs on regardless — which
## is exactly what a frontend that has never heard of any of this does.
##
## What it does NOT show is a Nunchuk arm moving in a game. Driving a commercial
## Wii menu from a script means driving the pointer, and the pointer follows
## whichever IR mode the core options file happens to be carrying; put the
## headset on for that.
extends Node

const RETRO_DEVICE_WIIMOTE_NC := 769

var core := "dolphin"
var rom := ""
var root_dir := ""

var _lib: Node = null


func _ready() -> void:
	var home := OS.get_environment("USERPROFILE").replace("\\", "/")
	if home.is_empty():
		home = OS.get_environment("HOME")
	root_dir = home + "/retroxr/libretro"
	rom = home + "/retroxr/roms/wii/Wii Sports (USA) (Rev 1).rvz"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nc-rom="):
			rom = arg.trim_prefix("--nc-rom=")
		elif arg.begins_with("--nc-core="):
			core = arg.trim_prefix("--nc-core=")
		elif arg.begins_with("--nc-root="):
			root_dir = arg.trim_prefix("--nc-root=")

	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[nunchuk] TIMEOUT")
		get_tree().quit(1))

	if not FileAccess.file_exists(rom):
		print("[nunchuk] SKIP: no disc at %s" % rom)
		get_tree().quit(0)
		return

	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_run()


func _wait_core_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	var deadline := Time.get_ticks_msec() + int(n * 1000.0 / 20.0) + 8000
	while int(_lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _run() -> void:
	print("[nunchuk] booting %s" % rom.get_file())
	_lib.StartContent(root_dir, core, rom)
	await _wait_core_frames(120)
	print("[nunchuk] core reached frame %d" % int(_lib.GetFrameCount()))

	# A remote with a Nunchuk on it. This is what makes the core bind the
	# Nunchuk's own IMUAccelerometer, and so what makes it read sub-device 1.
	_lib.SetControllerPortDevice(0, RETRO_DEVICE_WIIMOTE_NC)
	await _wait_core_frames(60)

	# Drive the two apart, deliberately: the remote lying flat and the Nunchuk
	# on its side. Feeding both the same value would look identical whether the
	# second one arrived or was quietly answered with the first.
	var target: int = int(_lib.GetFrameCount()) + 240
	var deadline := Time.get_ticks_msec() + 20000
	while int(_lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		_lib.SetSensorAccel(0, 0.0, 0.0, 1.0, 0)
		_lib.SetSensorAccel(0, 1.0, 0.0, 0.0, 1)
		await get_tree().process_frame

	print("[nunchuk] drove both accelerometers to frame %d" % int(_lib.GetFrameCount()))
	_lib.StopContent()
	await get_tree().create_timer(1.5).timeout
	print("[nunchuk] done — the verdict is the frontend's sub-device lines above")
	get_tree().quit(0)
