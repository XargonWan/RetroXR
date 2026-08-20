## Two GBAs on one cable, playing Mario Bros. together.
##
##     "$godot" --headless --path RetroXR res://Tools/mario_link_probe.tscn -- --roms=Z:/roms
##
## The probe that asks the question the others cannot: does a real game actually
## play over this link, or does the cable merely negotiate?
##
## Super Mario Advance is the ROM for it. It carries the Mario Bros. arcade game
## alongside Super Mario Bros. 2, and that mode is a two-to-four player link game.
## Point --roms at a library holding a copy; nothing is bundled.
##
## Reaching the mode needs input, so this presses through the intro, the menu and
## the lobby rather than sitting at the title. That makes it fragile in a way a
## test may not be: a different revision puts a cursor somewhere else and the run
## proves nothing, which is why it lives here rather than in Tests/. What it does
## assert is the shape of a session that is genuinely running, and both halves of
## that matter:
##
##   RATE  -- a GBA multiplayer game in play clocks about nine transfers per
##            frame, not one. One a frame is the IDLE rate, the pairing poll, and
##            a run that stops there has negotiated a cable and played nothing.
##   SPEED -- and both machines still run at 60 fps while doing it. The bus
##            rendezvouses the two emulation threads tens of thousands of times a
##            second, so a link that carried the traffic by halving the framerate
##            would satisfy the first number and be worthless.
##
## The GAME is what proves it. Two cores at the right transfer rate could still be
## trading rubbish, so the run also saves both screens: at PHASE 1 they show the
## same level with P1 marked on one machine and P2 on the other.
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
var _wall_prev := 0
var _fa_prev := 0
var _fb_prev := 0
var _filming := false
var _film_frame := 0


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

	_filming = "--film" in OS.get_cmdline_user_args()

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

	# Cable up straight away, the way a player who plugged the lead in before
	# switching on would have it.
	for i in range(20):
		await get_tree().process_frame
	var joined: bool = _a.LinkConnect(_b, 0, 0)
	print("[mario] cabled=%s" % str(joined))
	_wall_prev = Time.get_ticks_msec()

	# Through the logo, then interrupt the attract demo.
	#
	# The menu does NOT wait for anyone. Boot runs logo, fade, and straight into
	# a Super Mario 2 demo; Start interrupts that and brings up the title with
	# Single Player / Multiplayer on it. Every earlier attempt pressed into the
	# demo and read the result as a menu refusing input.
	#
	# Counted in EMULATED frames rather than process frames. Headless Godot has
	# no vsync, so its loop free-runs while a core paces itself to 60 Hz, and the
	# two counts drift apart by a factor of three or more. A menu press timed in
	# process frames is therefore timed in nothing at all: the same code waits a
	# different number of game frames on every run and on every machine.
	await _wait_frames(240)
	_shot("a_demo")

	# Start interrupts the attract demo and raises the title; the game does not
	# wait on its menu. Then Down to Multiplayer and A to take it, which is the
	# route confirmed by hand.
	await _hold(BTN_START, 6, 40)
	_shot("b_title")
	await _hold(BTN_DOWN, 6, 20)
	_shot("c_multiplayer")
	# The master takes Multiplayer first and starts calling.
	await _hold(BTN_A, 6, 60, [_a])
	_shot("d_master_calling")
	# Then the guest answers, a beat later, as the second player would.
	await _hold(BTN_A, 6, 60, [_b])
	_shot("d_guest_joining")

	# CHECKING. The two machines trade one word a frame while the game looks for
	# a partner, and it takes several hundred frames before it believes in one.
	# Watch the counter rather than guessing a duration.
	var quiet := 0
	var last_sent: int = _a.LinkSent(0)
	for step in range(40):
		await _wait_frames(30)
		var now_sent: int = _a.LinkSent(0)
		if now_sent == last_sent:
			quiet += 1
		else:
			quiet = 0
		last_sent = now_sent
		_report("check%02d" % step)
		# A confirm can land while the screen is mid-transition and be dropped.
		# Offering it again costs nothing on a machine that has already moved on.
		if step == 3 or step == 8 or step == 15:
			await _hold(BTN_A, 6, 20, [_b])
		# Traffic stopping is the signal the handshake has SETTLED, one way or
		# the other; sitting through the rest of the loop after that only wastes
		# the run.
		if quiet >= 3 and step >= 4:
			break
	_shot("e_lobby")

	# Both players are on the lobby now. Start takes the master through to the
	# Mario Bros. mode screen, where Classic or Battle is chosen, and A takes it.
	#
	# The link goes quiet between the lobby and the mode screen, which is why the
	# run keeps going rather than stopping at the first silence: pairing and
	# playing are separate conversations, and the second one has not been asked
	# for yet at the point the first ends.
	await _hold(BTN_START, 6, 90)
	_shot("f_after_start")
	_report("started")
	await _hold(BTN_A, 6, 90)
	_shot("g_after_mode")
	_report("mode")
	await _hold(BTN_A, 6, 90)
	_shot("h_after_mode2")
	_report("mode2")
	await _hold(BTN_START, 6, 90)
	_shot("i_after_start2")
	_report("start2")

	# From here on the game is in play, and everything measured at the end is
	# measured over this window alone. Counting from boot would fold in the long
	# idle poll of the pairing screens and bury the rate that matters.
	var play_sent: int = _a.LinkSent(0)
	var play_frames: int = _a.GetFrameCount()
	var play_wall: int = Time.get_ticks_msec()
	# Drive ONE player at a time, and only on its own machine.
	#
	# This is the part that cannot be faked. Machine A's joypad reaches machine
	# A's core and nothing else; the only way its Mario can appear to move on
	# machine B's screen is if the position crossed the cable. Standing still
	# proves nothing, because two cores running the same ROM from the same reset
	# will draw the same level whether or not a wire connects them.
	var script: Array[Array] = [
		[_a, BTN_RIGHT, "a_right"],
		[_a, BTN_LEFT | BTN_A, "a_left_jump"],
		[_b, BTN_LEFT, "b_left"],
		[_b, BTN_RIGHT | BTN_A, "b_right_jump"],
		[_a, BTN_RIGHT | BTN_A, "a_right_jump"],
		[null, 0, "idle"],
	]
	for step in range(script.size()):
		var machine: Libretro = script[step][0]
		var mask: int = script[step][1]
		if machine != null:
			machine.SetJoypadState(0, mask, 0, 0, 0, 0)
		if _filming:
			await _film(120)
		else:
			await _wait_frames(120)
		if machine != null:
			machine.SetJoypadState(0, 0, 0, 0, 0, 0)
		_shot("j_watch%d" % step)
		_report("watch%d %s" % [step, script[step][2]])

	# The master sends two messages per transfer, a start and its own word, so
	# halving its count gives transfers. Measured over the watch loop alone,
	# which is the only stretch where a game is actually being played.
	var transfers: float = (_a.LinkSent(0) - play_sent) / 2.0
	var frames: float = maxf(1.0, _a.GetFrameCount() - play_frames)
	var per_frame: float = transfers / frames
	var fps: float = frames / maxf(0.001, (Time.get_ticks_msec() - play_wall) / 1000.0)

	print("[mario] ---- %d transfers over %d frames: %.1f per frame, %.1f fps ----" % [
		int(transfers), int(frames), per_frame, fps])

	var failures: PackedStringArray = []
	if per_frame < 5.0:
		failures.append("only %.1f transfers per frame; a session in play runs about 9, one a frame is the idle poll" % per_frame)
	if fps < 50.0:
		failures.append("machines ran at %.1f fps; the link is being paid for in emulation speed" % fps)
	if _a.LinkPeerCount(0) != 2 or _b.LinkPeerCount(0) != 2:
		failures.append("cable reports %d and %d peers" % [_a.LinkPeerCount(0), _b.LinkPeerCount(0)])

	for f in failures:
		print("[mario] FAIL  %s" % f)
	if failures.is_empty():
		print("[mario] RESULT=PLAYING  two cores are running a link game over the cable")
	else:
		print("[mario] RESULT=FAILED")

	_a.StopContent()
	_b.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_restore()
	get_tree().quit(0 if failures.is_empty() else 1)


## Wait for a number of EMULATED frames on the slower of the two machines.
##
## The distinction matters more than it looks. A headless run has no vsync, so
## get_tree().process_frame comes round several times per emulated frame, and a
## menu press counted in process frames lands for a fraction of a game frame or
## for ten of them depending on how loaded the box is. Counted here, a press is
## the same length every time.
func _wait_frames(n: int) -> void:
	var target_a: int = _a.GetFrameCount() + n
	var target_b: int = _b.GetFrameCount() + n
	while _a.GetFrameCount() < target_a or _b.GetFrameCount() < target_b:
		await get_tree().process_frame


## Save both screens every emulated frame, for encoding into a side-by-side clip.
##
## A still cannot show a link game working. Two machines can agree on a level and
## still be running two separate games in it, and the only thing that tells them
## apart is whether one player's Mario moves on the other player's screen.
func _film(n: int) -> void:
	var dir := "res://probe_out/film"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var target_a: int = _a.GetFrameCount() + n
	while _a.GetFrameCount() < target_a:
		await get_tree().process_frame
		var ia: Image = _a.GetVideoImage()
		var ib: Image = _b.GetVideoImage()
		if ia == null or ib == null or ia.is_empty() or ib.is_empty():
			continue
		ia.save_png("%s/%05d_a.png" % [dir, _film_frame])
		ib.save_png("%s/%05d_b.png" % [dir, _film_frame])
		_film_frame += 1


## One line of everything worth knowing: link traffic, and how fast each machine
## is actually running.
##
## Emulated speed belongs next to the traffic count because a link that looks
## slow may only be a core running slow. The barrier this rests on rendezvouses
## the two threads tens of thousands of times a second, and if that is what is
## costing the frames then a transfer rate says nothing about the game at all.
func _report(tag: String) -> void:
	var wall: int = Time.get_ticks_msec()
	var fa: int = _a.GetFrameCount()
	var fb: int = _b.GetFrameCount()
	var secs: float = max(1, wall - _wall_prev) / 1000.0
	print("[mario] %-9s sent A=%d B=%d  got A=%d B=%d  peers=%d  fps A=%.1f B=%.1f" % [
		tag, _a.LinkSent(0), _b.LinkSent(0), _a.LinkTraffic(0), _b.LinkTraffic(0),
		_a.LinkPeerCount(0), (fa - _fa_prev) / secs, (fb - _fb_prev) / secs])
	_wall_prev = wall
	_fa_prev = fa
	_fb_prev = fb


## Save what machine A is showing, so a run that goes wrong can be LOOKED at.
##
## Blind button pressing through a menu is guesswork, and a probe that reports
## silence without showing where it got stuck is not evidence of anything.
func _shot(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	# BOTH machines. Only ever photographing the master hid the whole first half
	# of the story: the two screens diverge for most of the handshake, and which
	# of them is stuck is the question being asked.
	for pair: Array in [[_a, "a"], [_b, "b"]]:
		var machine: Libretro = pair[0]
		var img: Image = machine.GetVideoImage()
		if img == null or img.is_empty():
			print("[mario] shot %s/%s: no frame yet" % [tag, pair[1]])
			continue
		img.save_png("res://probe_out/mario_%s_%s.png" % [tag, pair[1]])
	print("[mario] shot %s" % tag)


## Press a button on both machines, then let go, then wait.
## Press a button, then let go, then wait.
##
## `who` picks the machines: both by default, or one of them. Pressing both at
## once is not what two people do and not what the game expects. The parent goes
## into multiplayer first and starts calling, and the second machine joins a call
## that is already in progress; pressed together, the master reaches CHECKING and
## the other one is still on its own title screen refusing to move, which reads
## exactly like a link that never negotiated.
func _hold(mask: int, press_frames: int, gap_frames: int, who: Array = []) -> void:
	var machines: Array = who if not who.is_empty() else [_a, _b]
	for machine: Libretro in machines:
		machine.SetJoypadState(0, mask, 0, 0, 0, 0)
	await _wait_frames(press_frames)
	for machine: Libretro in machines:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait_frames(gap_frames)


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
