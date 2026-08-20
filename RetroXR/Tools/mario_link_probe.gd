## Two GBAs on one cable, running Mario Bros.
##
##     "$godot" --headless --path RetroXR res://Tools/mario_link_probe.tscn
##
## The probe that asks the question the others cannot: does a real game actually
## trade bytes over the link, or does the cable merely negotiate?
##
## Super Mario Advance is the ROM for it. It carries the Mario Bros. arcade game
## alongside Super Mario Bros. 2, and that mode is a two-to-four player link game,
## so the guests start driving their serial ports as soon as multiplayer is
## chosen. Point --rom at a copy; nothing is bundled.
##
## Reaching the mode needs input, so this presses through the intro and the menu
## rather than sitting at the title. That makes it fragile in a way a test may not
## be: a different revision puts the cursor somewhere else and the run proves
## nothing. It reports what it saw rather than asserting a frame count, and the
## number that matters is the traffic counter climbing at all.
extends Node

const CORE := "mgba"
const OPT_KEY := "mgba_link_cable"

const BTN_A := 1 << 8
const BTN_START := 1 << 3
const BTN_DOWN := 1 << 5
const BTN_RIGHT := 1 << 7
const BTN_LEFT := 1 << 6

var _opt_path := ""
var _opt_backup := ""
var _restored := false
var _a: Libretro = null
var _b: Libretro = null


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[mario] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var rom := _find_rom()
	if rom.is_empty():
		print("[mario] SKIP  no Super Mario Advance ROM found")
		print("[mario]       looked for a .gba whose name contains 'super mario advance'")
		get_tree().quit(0)
		return
	print("[mario] rom  %s" % rom)

	var root := CoreDownloadManager.default_core_root()
	if not _enable_link_option(root):
		print("[mario] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	_a = Libretro.new()
	_b = Libretro.new()
	add_child(_a)
	add_child(_b)
	_a.StartContent(root, CORE, rom)
	_b.StartContent(root, CORE, rom)

	# Deliberately NOT calling SetInputEnabled. That flag lets a wrapper poll the
	# global Godot Input singleton, and it OVERWRITES the joypad every frame, so
	# turning it on throws away everything SetJoypadState puts there. Off is what
	# a probe wants: the state it sets is the state the core sees.

	for i in range(300):
		await get_tree().process_frame

	var joined: bool = _a.LinkConnect(_b, 0, 0)
	await get_tree().process_frame
	print("[mario] cabled=%s  peers A=%d B=%d" % [str(joined), _a.LinkPeerCount(0), _b.LinkPeerCount(0)])

	# Press through the intro and into the menu on BOTH machines, photographing
	# each step so a wrong turn can be seen rather than guessed at.
	# One shot per press, so the route can be READ off the frames instead of
	# guessed at. Both machines are driven together: the multiplayer handshake
	# only happens if they reach the same screen at about the same time.
	for i in range(180):
		await get_tree().process_frame
	_shot("a_boot")
	await _hold(BTN_START, 20, 150)
	await _hold(BTN_DOWN, 20, 90)
	_shot("b_multiplayer_selected")

	# Photograph the moments RIGHT AFTER the confirm as well as later. If the
	# game dips into a "looking for players" screen and bounces straight back,
	# a single late frame would show the menu and look like nothing happened.
	for machine: Libretro in [_a, _b]:
		machine.SetJoypadState(0, BTN_A, 0, 0, 0, 0)
	for i in range(20):
		await get_tree().process_frame
	for machine: Libretro in [_a, _b]:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	_shot("c_confirm_t0")
	for i in range(20):
		await get_tree().process_frame
	_shot("d_confirm_t20")
	for i in range(40):
		await get_tree().process_frame
	_shot("e_confirm_t60")
	for i in range(120):
		await get_tree().process_frame
	_shot("f_confirm_t180")

	# Then let them sit and watch the counter.
	var last := 0
	for round_i in range(12):
		for i in range(120):
			await get_tree().process_frame
		var ta: int = _a.LinkTraffic(0)
		var tb: int = _b.LinkTraffic(0)
		print("[mario] t+%2ds  sent A=%d B=%d  got A=%d B=%d  peers A=%d" % [
			(round_i + 1) * 2, _a.LinkSent(0), _b.LinkSent(0), ta, tb, _a.LinkPeerCount(0)])
		if ta + tb > last:
			last = ta + tb
		if round_i == 2 or round_i == 7:
			_shot("06_round%d" % round_i)

	print("[mario] ---- total link messages: %d ----" % last)
	if last > 0:
		print("[mario] RESULT=TRAFFIC  the guests are talking over the cable")
	else:
		print("[mario] RESULT=SILENT   the cable negotiated but nothing crossed it")

	_a.StopContent()
	_b.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_restore()
	get_tree().quit(0)


## Save what machine A is showing, so a run that goes wrong can be LOOKED at.
##
## Blind button pressing through a menu is guesswork, and a probe that reports
## silence without showing where it got stuck is not evidence of anything.
func _shot(tag: String) -> void:
	var img: Image = _a.GetVideoImage()
	if img == null or img.is_empty():
		print("[mario] shot %s: no frame yet" % tag)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	img.save_png("res://probe_out/mario_%s.png" % tag)
	print("[mario] shot %s" % tag)


## Press a button on both machines, then let go, then wait.
func _hold(mask: int, press_frames: int, gap_frames: int) -> void:
	for machine: Libretro in [_a, _b]:
		machine.SetJoypadState(0, mask, 0, 0, 0, 0)
	for i in range(press_frames):
		await get_tree().process_frame
	for machine: Libretro in [_a, _b]:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	for i in range(gap_frames):
		await get_tree().process_frame


func _find_rom() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
	# The bulk library lives off the project, so take it from the command line
	# rather than guessing a drive letter.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--roms="):
			roots.append(arg.substr(7))
	for root in roots:
		for systemid in ["game_boy_advance", "gba"]:
			var dir_path: String = root.path_join(systemid)
			var dir := DirAccess.open(dir_path)
			if dir == null:
				continue
			for f in dir.get_files():
				var lower := f.to_lower()
				if lower.ends_with(".gba") and lower.contains("super mario advance") \
						and not lower.contains("advance 2") and not lower.contains("advance 3") \
						and not lower.contains("advance 4") and not lower.contains("demo"):
					return dir_path.path_join(f)
	return ""


func _enable_link_option(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, CORE]
	var existing := ""
	if FileAccess.file_exists(_opt_path):
		var reader := FileAccess.open(_opt_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	_opt_backup = existing

	var lines: PackedStringArray = []
	for line in existing.split("\n", false):
		if not line.begins_with(OPT_KEY):
			lines.append(line)
	lines.append('%s = "enabled"' % OPT_KEY)

	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer == null:
		return false
	writer.store_string("\n".join(lines) + "\n")
	writer.close()
	return true


func _restore() -> void:
	if _restored or _opt_path.is_empty():
		return
	_restored = true
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()
		print("[mario] restored %s" % _opt_path)
