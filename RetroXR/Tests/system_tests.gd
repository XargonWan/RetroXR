## RetroSystem self-tests — the pure-logic half of the machine controller, run
## headless with no core, no ROM, no headset and no device.
##
##     "$godot" --headless --path RetroXR res://Tests/system_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Every case below is a rule that a console, a core or a peripheral depends on
## and that nothing else checks: which libretro port a peripheral drives, which
## device id a core is told, which pad profile a plugged pad selects, which
## seated object names the save, and whether pulling the media stops the run.
## The light-gun cases are the regression record for a bug that shipped — the ray
## gun announced a device id fceumm does not know, and fceumm turns an unknown id
## into a gamepad, so plugging the gun in is what unplugged the Zapper.
##
## RetroSystem is a scene node with a `Libretro` child and a hardware model, so
## these build it with `.new()` and never add it to the tree: `_ready()` would
## look for children that a bare instance does not have. That is also the limit
## of what can be tested here — anything that touches `_libretro`, `_model`, the
## snap zones or the A/V graph needs a real scene and lives in `Tools/` probes or
## in `Tests/av_suite.tscn`. `_sync_core_tray()` is on the far side of that line;
## what is testable is the two questions it asks first, and those are below.
##
## Known gaps, asserted nowhere on purpose — add the case with the fix, not
## before it, or the suite goes red on behaviour nobody has agreed to yet:
##   - the light-gun name list does not know "Stunner" (the Saturn Virtua Gun's
##     US name), so a core naming its gun only that would not resolve;
##   - `attach_expanded_controller` (a multitap sub-port) announces the raw
##     device type, skipping `_core_device_id`, so a gun on a multitap is a
##     gamepad to fceumm until the next core start re-announces it.
extends Node


## A stand-in for a cartridge or a memory card: the system only ever reads named
## properties off the seated object, so a Node3D carrying them is enough.
class FakeSeated extends Node3D:
	var save_id: String = ""
	var card_id: String = ""
	var game_label: String = ""
	var systemid: String = ""
	var device_type: int = 1


## Port lists exactly as fceumm declares them (read back from the running core).
## Its Zapper is a MOUSE subclass, so nothing here has a light gun's base type —
## which is the whole reason the resolver cannot go by base type alone.
const FCEUMM_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513},
		{"name": "Zapper", "id": 258}]},
	{"port": 1, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513},
		{"name": "Arkanoid", "id": 514}, {"name": "Zapper", "id": 258},
		{"name": "Power Pad A", "id": 259}, {"name": "Power Pad B", "id": 515}]},
	{"port": 2, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513}]},
]

## A core that subclasses the light gun properly, the way libretro.h intends.
## 263 = SUBCLASS(LIGHTGUN, 0), 519 = SUBCLASS(LIGHTGUN, 1).
const SNES_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "SNES Joypad", "id": 1}, {"name": "SNES Mouse", "id": 2},
		{"name": "Super Scope", "id": 263}, {"name": "Justifier", "id": 519}]},
]

## A core declaring both shapes on one port. The base type is the stronger
## signal, so it must win however early the name match appears in the list.
const MIXED_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "Zapper", "id": 258}, {"name": "Super Scope", "id": 263}]},
]

const DEVICE_NONE := 0
const DEVICE_JOYPAD := 1
const DEVICE_MOUSE := 2
const DEVICE_KEYBOARD := 3
const DEVICE_LIGHTGUN := 7

var _pass := 0
var _fail := 0


func _ready() -> void:
	# A test scene must never hang a headless run.
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	_test_reads_as_lightgun()
	_test_core_device_id()
	_test_pad_type_choice()
	_test_libretro_port_routing()
	_test_port_device_cache()
	_test_cabinet_lookup()
	_test_seated_content()
	_test_media_removal()
	_test_expanded_port_binding()
	_test_belongs_here()
	_test_core_resolution()
	_test_forced_options_merge()
	_test_net_link_group_merge()
	_test_memcard_presence()
	_test_bios_seed()
	_test_bios_boot_table()
	_test_power_on_verdict()
	_test_state_paths()
	_test_state_thumbnail()
	_test_state_disk_round_trip()

	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % test_name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [test_name, "  — " + detail if not detail.is_empty() else ""])


func _eq(test_name: String, got: Variant, want: Variant) -> void:
	_ok(test_name, got == want, "got %s, want %s" % [str(got), str(want)])


## A bare instance: never added to the tree, so `_ready()` never runs and no
## child node is required. Caller frees it.
func _system(sysid: String = "nes") -> RetroSystem:
	var sys := RetroSystem.new()
	sys.systemid = sysid
	return sys


# ---------------------------------------------------------------------------
# Which device names read as a light gun.
# ---------------------------------------------------------------------------

func _test_reads_as_lightgun() -> void:
	for gun: String in ["Zapper", "Super Scope", "Konami Justifier", "GunCon",
			"Light Phaser", "Menacer", "Lightgun"]:
		_ok("gun name/'%s' is a gun" % gun, RetroSystem._reads_as_lightgun(gun))
	# The rest of a NES port list, plus the devices most likely to be mistaken
	# for one because they also report a screen position.
	for other: String in ["Auto", "Gamepad", "Arkanoid", "Power Pad A",
			"SNES Mouse", "Keyboard", "Multitap", "Oeka Kids Tablet",
			"Pointer", "Touchscreen"]:
		_ok("gun name/'%s' is not a gun" % other, not RetroSystem._reads_as_lightgun(other))


# ---------------------------------------------------------------------------
# The generic device type a peripheral carries -> the id the running core knows.
# ---------------------------------------------------------------------------

func _test_core_device_id() -> void:
	var sys := _system()
	sys._controller_info = FCEUMM_PORTS

	# The bug this suite exists for: 7 is not a device fceumm knows, and its
	# switch turns an unknown id into a gamepad. Port 2 (index 1) is where a NES
	# Zapper goes.
	_eq("device/fceumm gun -> Zapper", sys._core_device_id(DEVICE_LIGHTGUN, 1), 258)
	_eq("device/fceumm gun on port 1 -> Zapper", sys._core_device_id(DEVICE_LIGHTGUN, 0), 258)

	# A port that declares no gun keeps the generic id rather than borrowing the
	# gun another port declares.
	_eq("device/no gun on this port passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 2), DEVICE_LIGHTGUN)
	# A port the core never declared at all.
	_eq("device/unknown port passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 9), DEVICE_LIGHTGUN)

	# Only a light gun is translated. A pad, a mouse, a keyboard and an unplug
	# all have to reach the core exactly as sent.
	for dev: int in [DEVICE_NONE, DEVICE_JOYPAD, DEVICE_MOUSE, DEVICE_KEYBOARD]:
		_eq("device/type %d untranslated" % dev, sys._core_device_id(dev, 1), dev)

	# Nothing is known about the core until it starts, and a peripheral can be
	# plugged into a machine that is off. The generic id is the honest answer;
	# _reannounce_port_devices() corrects it once the core declares its list.
	sys._controller_info = []
	_eq("device/machine off passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 1), DEVICE_LIGHTGUN)

	# A core that subclasses the light gun properly is taken at its word.
	sys._controller_info = SNES_PORTS
	_eq("device/subclassed gun wins", sys._core_device_id(DEVICE_LIGHTGUN, 0), 263)

	# Base type beats the name, however early the name matches.
	sys._controller_info = MIXED_PORTS
	_eq("device/base type beats name", sys._core_device_id(DEVICE_LIGHTGUN, 0), 263)

	sys.free()


# ---------------------------------------------------------------------------
# Which pad profile a plugged pad selects (PCSX-ReARMed's padNtype).
# ---------------------------------------------------------------------------

func _test_pad_type_choice() -> void:
	var full: Array = ["standard", "analog", "dualshock"]
	_eq("pad/dualshock takes dualshock",
		RetroSystem._decide_pad_type(full, "dualshock", "standard"), "dualshock")
	# A core offering no DualShock still deserves the analog pad rather than the
	# digital one — the sticks are physically there.
	_eq("pad/dualshock falls back to analog",
		RetroSystem._decide_pad_type(["standard", "analog"], "dualshock", "standard"), "analog")
	_eq("pad/no fallback available",
		RetroSystem._decide_pad_type(["standard"], "dualshock", "standard"), "")
	# Already right: setting an option costs a core round trip and a rewritten
	# .opt file, so the no-op has to stay a no-op.
	_eq("pad/already selected",
		RetroSystem._decide_pad_type(full, "dualshock", "dualshock"), "")
	_eq("pad/no options known",
		RetroSystem._decide_pad_type([], "dualshock", "standard"), "")
	# A preference this core has never heard of is left alone, not guessed at.
	_eq("pad/unknown preference",
		RetroSystem._decide_pad_type(full, "wavebird", "standard"), "")
	_eq("pad/plain analog pad",
		RetroSystem._decide_pad_type(full, "analog", "standard"), "analog")


# ---------------------------------------------------------------------------
# Which libretro port a peripheral drives, and whether it claims one at all.
# ---------------------------------------------------------------------------

func _test_libretro_port_routing() -> void:
	var pc := _system("dos")
	# A computer's cores poll the mouse on port 0 wherever the cabinet put it,
	# which is what lets a mouse and a keyboard share the machine.
	_eq("routing/computer mouse pinned to port 0",
		pc._libretro_port_for(DEVICE_MOUSE, 1), 0)
	_eq("routing/computer pad keeps its socket",
		pc._libretro_port_for(DEVICE_JOYPAD, 1), 1)
	_eq("routing/computer keyboard keeps its socket",
		pc._libretro_port_for(DEVICE_KEYBOARD, 1), 1)
	# ...but the GAME PORT does drive port 0: a DOS or Amiga core reads its one
	# joystick there, and a pad announced on port 2 is a pad the game never sees.
	# Narrow on purpose — pinning every joypad socket would break the machines
	# that really do have two.
	#
	# Instantiated and added rather than built with _system(): which socket is the
	# game port is the MODEL's to say, and a bare RetroSystem has no model. Adding
	# it runs _ready, which loads one — no frame needed.
	var tower := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	tower.systemid = "dos"
	add_child(tower)
	_eq("routing/computer game port drives port 0",
		tower._libretro_port_for(DEVICE_JOYPAD, 2), 0)
	_eq("routing/its other sockets are untouched",
		tower._libretro_port_for(DEVICE_JOYPAD, 1), 1)
	tower.queue_free()
	# ...but does not occupy it: its keys are global to port 0 regardless, and
	# claiming a numbered port would take the slot the mouse needs.
	_ok("routing/computer keyboard claims no port",
		not pc._claims_port_device(DEVICE_KEYBOARD))
	_ok("routing/computer mouse claims a port", pc._claims_port_device(DEVICE_MOUSE))
	pc.free()

	var console := _system("nes")
	_eq("routing/console mouse keeps its socket",
		console._libretro_port_for(DEVICE_MOUSE, 1), 1)
	_ok("routing/console keyboard claims a port",
		console._claims_port_device(DEVICE_KEYBOARD))
	_ok("routing/console gun claims a port", console._claims_port_device(DEVICE_LIGHTGUN))
	console.free()


# ---------------------------------------------------------------------------
# The cached selection the options panel reads back.
# ---------------------------------------------------------------------------

func _test_port_device_cache() -> void:
	var sys := _system()
	# Deep-copied: the fixtures are consts shared with the other cases, and the
	# cache is written in place.
	sys._controller_info = FCEUMM_PORTS.duplicate(true)

	sys.set_controller_port_device(1, 258)
	_eq("cache/port 2 shows the Zapper", sys._controller_info[1]["current_id"], 258)
	_ok("cache/port 1 untouched", not sys._controller_info[0].has("current_id"))

	# A port the core did not declare must not invent an entry or disturb one.
	sys.set_controller_port_device(9, 513)
	_eq("cache/unknown port adds nothing", sys._controller_info.size(), 3)
	_eq("cache/unknown port leaves port 2 alone", sys._controller_info[1]["current_id"], 258)

	sys.free()


# ---------------------------------------------------------------------------
# Which cabinet socket holds a peripheral. The socket is not the libretro port:
# a saved room that recorded the port put two peripherals in one socket.
# ---------------------------------------------------------------------------

func _test_cabinet_lookup() -> void:
	var sys := _system()
	var pad := FakeSeated.new()
	var stray := FakeSeated.new()
	sys._port_controllers = [null, pad, null, null]

	_eq("cabinet/finds the socket", sys.cabinet_port_of(pad), 1)
	_eq("cabinet/absent peripheral", sys.cabinet_port_of(stray), -1)
	_eq("cabinet/holder of an occupied socket", sys.port_holder(1), pad)
	_eq("cabinet/holder of an empty socket", sys.port_holder(0), null)
	_eq("cabinet/holder past the end", sys.port_holder(9), null)
	_eq("cabinet/holder below zero", sys.port_holder(-1), null)

	pad.free()
	stray.free()
	sys.free()


# ---------------------------------------------------------------------------
# What the seated media says about the run: its label, its system and its save.
# ---------------------------------------------------------------------------

func _test_seated_content() -> void:
	var sys := _system()
	sys.rom_path = "C:/roms/nes/Duck Hunt (World).nes"

	# Nothing seated: the file on disk is all there is to go on.
	_eq("content/label falls back to the file", sys._content_label(), "Duck Hunt (World)")
	_eq("content/system falls back to the machine", sys._resolve_systemid(), "nes")
	_eq("content/no cart means no save slot", sys._sram_slot(), "")
	_eq("content/no cart means no save path", sys._compose_sram_path("fceumm"), "")

	var cart := FakeSeated.new()
	cart.game_label = "Duck Hunt"
	cart.save_id = "dh-001"
	cart.systemid = "fds"
	sys._snapped_cartridge = cart

	_eq("content/cart names the game", sys._content_label(), "Duck Hunt")
	# A Famicom Disk System disc in a NES: the disc decides, because that is what
	# picks the core and the save location.
	_eq("content/cart names the system", sys._resolve_systemid(), "fds")
	_eq("content/cart names the save slot", sys._sram_slot(), "dh-001")
	_ok("content/cart has a save path", not sys._compose_sram_path("fceumm").is_empty())

	# A blank label is not a label — the file name is better than an empty plate.
	cart.game_label = ""
	_eq("content/blank cart label falls back", sys._content_label(), "Duck Hunt (World)")
	cart.systemid = ""
	_eq("content/blank cart system falls back", sys._resolve_systemid(), "nes")

	# No core resolved and no ROM are both "nothing to persist", not a path built
	# out of empty strings.
	_eq("content/no core means no save path", sys._compose_sram_path(""), "")
	sys.rom_path = ""
	_eq("content/no rom means no save path", sys._compose_sram_path("fceumm"), "")

	cart.free()
	sys.free()


# ---------------------------------------------------------------------------
# Taking the media out. A console does not stop when a disc leaves the drive —
# that is what lets Monster Rancher read an arbitrary CD, and what keeps a
# multi-disc game alive between discs — and a floppy machine is the same. Only a
# cartridge deck stops, where pulling the cart takes the program away.
# ---------------------------------------------------------------------------

func _test_media_removal() -> void:
	var tray := _system("playstation")
	tray._disc_loader = MediaDimensions.LOADER_TRAY
	_ok("media/a tray console keeps running", tray._media_survives_removal())
	tray.free()

	var slot := _system("wii")
	slot._disc_loader = MediaDimensions.LOADER_SLOT
	_ok("media/a slot console keeps running", slot._media_survives_removal())
	slot.free()

	# No disc loader at all, but the media is a floppy — the drive is a slot in
	# the tower's bezel and the machine runs on regardless.
	var floppy := _system("dos")
	_eq("media/a floppy machine has no disc loader",
		floppy._disc_loader, MediaDimensions.LOADER_NONE)
	_ok("media/a floppy machine keeps running", floppy._media_survives_removal())
	floppy.free()

	# The cartridge IS the program. Pulling it stops the machine, as it always has.
	var cart := _system("nes")
	_ok("media/a cartridge deck stops", not cart._media_survives_removal())
	cart.free()

	# Whether a swap can reach the core is answered by the core's .info file
	# before the core is even loaded. The live disk_control_ready signal lands
	# some frames into the run, and a disc pulled before it did used to take the
	# no-disk-control path and power the machine off.
	var psx := _system("playstation")
	psx.core_name = "pcsx_rearmed"
	_ok("disk control/declared by a PS1 core", psx._supports_disk_control())
	psx.free()

	var amiga := _system("commodore_amiga")
	amiga.core_name = "puae"
	_ok("disk control/declared by a floppy core", amiga._supports_disk_control())
	amiga.free()

	var nes := _system("nes")
	nes.core_name = "fceumm"
	_ok("disk control/not declared by a cartridge core", not nes._supports_disk_control())
	# The running core is still the better witness: a core that reports the
	# interface at runtime is believed whatever its .info file says.
	nes._has_disk_control = true
	_ok("disk control/the live answer wins", nes._supports_disk_control())
	nes.free()

	var unknown := _system("playstation")
	unknown.core_name = "not_a_real_core"
	_ok("disk control/an unknown core claims nothing",
		not unknown._supports_disk_control())
	unknown.free()

	_test_lid_ops()


# ---------------------------------------------------------------------------
# The lid is the drive's sensor: the core's tray follows the LID, not the disc.
# Open it, swap freely, shut it — the core sees one tray cycle and one disc, so
# the swap trick works and a multi-disc game is never told anything else.
# ---------------------------------------------------------------------------

func _test_lid_ops() -> void:
	const NONE := RetroSystem.DISK_OP_NONE
	const EJECT := RetroSystem.DISK_OP_EJECT
	const CLOSE := RetroSystem.DISK_OP_CLOSE

	# Lid up over a drive the core thinks is shut: that is the moment the core
	# learns the disc is unavailable.
	_eq("lid/opening ejects", RetroSystem._tray_op_for(true, false, true), EJECT)
	_eq("lid/opening an empty drive ejects", RetroSystem._tray_op_for(true, false, false), EJECT)
	# Already open as far as the core is concerned — saying it twice would be a
	# second tray cycle the game can see.
	_eq("lid/opening again says nothing", RetroSystem._tray_op_for(true, true, true), NONE)

	# Shutting hands over whatever is in the well, including the disc that was
	# already mounted: a real drive re-reads what it finds.
	_eq("lid/shutting over a disc hands it over",
		RetroSystem._tray_op_for(false, true, true), CLOSE)
	_eq("lid/shutting over the same disc still re-reads",
		RetroSystem._tray_op_for(false, false, true), CLOSE)
	# Nothing in the well: the core keeps waiting with its tray open rather than
	# being told to close on an empty drive.
	_eq("lid/shutting over an empty well says nothing",
		RetroSystem._tray_op_for(false, true, false), NONE)
	_eq("lid/shutting an empty drive the core thinks is shut",
		RetroSystem._tray_op_for(false, false, false), NONE)


# ---------------------------------------------------------------------------
# An EXPANDED port — one a multitap fans out to — is a port to the core like any
# other. It used to be bound by an abridged copy of the cabinet path, and the
# abridgement dropped the device translation, so a gun on a multitap reached
# fceumm as a gamepad. Only the expanded half is reachable here: the cabinet half
# seats a plug into a snap zone and adds a physics exception.
# ---------------------------------------------------------------------------

func _test_expanded_port_binding() -> void:
	var sys := _system()
	sys._controller_info = FCEUMM_PORTS.duplicate(true)
	var gun := FakeSeated.new()
	gun.device_type = DEVICE_LIGHTGUN

	sys.attach_expanded_controller(1, gun)
	_eq("expanded/a gun is announced as the core's gun",
		sys._controller_info[1].get("current_id", -1), 258)
	_eq("expanded/the port remembers the peripheral", sys.port_holder(1), gun)
	# No cabinet socket, so nothing is recorded as a plug — that array belongs to
	# the sockets, and a stray entry would be released as if a cord were pulled.
	_ok("expanded/no cabinet plug recorded", sys._port_plugs[1] == null)

	sys.detach_expanded_controller(1, gun)
	_eq("expanded/unplugging clears the port", sys._controller_info[1]["current_id"], 0)
	_eq("expanded/unplugging frees the holder", sys.port_holder(1), null)

	# A port below zero is not a port; binding one used to be caught by the
	# caller, and _bind_port is now the only thing that can catch it.
	sys.attach_expanded_controller(-1, gun)
	_ok("expanded/a negative port binds nothing", sys.port_holder(0) == null)

	gun.free()
	sys.free()


# ---------------------------------------------------------------------------
# What a system's slot and ports will accept. One rule, two tables — an object
# that names no system is universal, which is what keeps RetroXR's stand-in
# props and unlabelled legacy media working everywhere.
# ---------------------------------------------------------------------------

func _test_belongs_here() -> void:
	var nes := _system("nes")
	var cart := FakeSeated.new()

	cart.systemid = "nes"
	_ok("belongs/its own media fits", nes._accepts_media(cart))
	cart.systemid = "snes"
	_ok("belongs/another system's media does not", not nes._accepts_media(cart))
	cart.systemid = ""
	_ok("belongs/unlabelled media fits anywhere", nes._accepts_media(cart))
	# An object with no systemid property at all — a prop that predates the rule.
	var plain := Node3D.new()
	_ok("belongs/an object naming no system fits", nes._accepts_media(plain))

	cart.systemid = "snes"
	_ok("belongs/the port gate reads the same way", not nes._accepts_plug(cart))
	cart.systemid = ""
	_ok("belongs/an unlabelled plug fits", nes._accepts_plug(cart))
	nes.free()

	# The media table is the console's, and it is not symmetric: a Wii takes a
	# GameCube disc, a GameCube does not take a Wii one.
	var wii := _system("wii")
	cart.systemid = "gamecube"
	_ok("belongs/a Wii takes a GameCube disc", wii._accepts_media(cart))
	# ...and the front of the machine agrees with the tray. This case used to
	# read the other way, pinning an empty port table, and the cost of that
	# showed up the day a GameCube-to-Game Boy Advance lead was carried over to
	# the one console in the room that could use it and was silently refused.
	_ok("belongs/and a GameCube plug in its front sockets", wii._accepts_plug(cart))
	wii.free()

	var cube := _system("gamecube")
	cart.systemid = "wii"
	_ok("belongs/a GameCube refuses a Wii disc", not cube._accepts_media(cart))
	cube.free()

	var gba := _system("game_boy_advance")
	cart.systemid = "game_boy"
	_ok("belongs/a GBA takes a Game Boy cart", gba._accepts_media(cart))
	gba.free()

	plain.free()
	cart.free()


# ---------------------------------------------------------------------------
# Which core and which directory this machine runs from. Every path asks these
# two — the options panel, netplay, the SRAM paths, achievements and the power
# button — so a machine that answered them itself would run a different core
# from the one the panel was editing.
# ---------------------------------------------------------------------------

func _test_core_resolution() -> void:
	var sys := _system("nes")

	sys.core_name = "some_core"
	_eq("resolve/a named core wins", sys._resolve_core(), "some_core")
	sys.core_name = ""
	_ok("resolve/a known system falls back to its default",
		not sys._resolve_core().is_empty())
	sys.systemid = ""
	_eq("resolve/nothing to go on", sys._resolve_core(), "")

	sys.core_directory = "C:/somewhere/libretro"
	_eq("resolve/a named directory wins", sys._resolve_dir(), "C:/somewhere/libretro")
	sys.core_directory = ""
	_eq("resolve/the directory falls back to the core root",
		sys._resolve_dir(), CoreDownloadManager.default_core_root())

	sys.free()


# ---------------------------------------------------------------------------
# The forced-options merge. A shell pins the options its screen needs before
# every launch, into the same <core>.opt file the running core loads and the
# options panel edits — so the merge has to leave the player's own keys alone,
# and it must not rewrite the file when nothing moved (a rewrite reorders it).
# ---------------------------------------------------------------------------

func _test_forced_options_merge() -> void:
	var root := "user://__system_selftest"
	var core := "selftest_core"
	var path := CoreOptionsStore.opt_path(root, core)

	_ok("forced/nothing forced writes nothing",
		not CoreOptionsStore.merge_values(root, core, {}))
	_ok("forced/and creates no file", not FileAccess.file_exists(path))

	# The player's own settings, as a run would have left them.
	CoreOptionsStore.save_values(root, core, {"user_key": "mine", "vb_3dmode": "anaglyph"})

	_ok("forced/a new pin is written",
		CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}))
	var after := CoreOptionsStore.load_values(root, core)
	_eq("forced/the pin took", after.get("vb_3dmode", ""), "sidebyside")
	_eq("forced/the player's own key survives", after.get("user_key", ""), "mine")

	# Already pinned: no write at all, so the file keeps its bytes and its order.
	var before_time := FileAccess.get_modified_time(path)
	_ok("forced/an unchanged pin rewrites nothing",
		not CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}))
	_eq("forced/the file was left alone", FileAccess.get_modified_time(path), before_time)

	# Values arrive from a model as ints and bools as often as strings.
	_ok("forced/a non-string value is written",
		CoreOptionsStore.merge_values(root, core, {"citra_factor_3d": 0}))
	_eq("forced/and reads back as its text",
		CoreOptionsStore.load_values(root, core).get("citra_factor_3d", ""), "0")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok("forced/cleaned up", not FileAccess.file_exists(path))


# ---------------------------------------------------------------------------
# Save states: the pure half — ids, paths, the thumbnail, and the disk round
# trip. Capture needs a live core and lives in Tools/state_probe.tscn; what is
# here is everything that decides WHERE a state goes and WHAT it looks like.
# ---------------------------------------------------------------------------

func _test_state_paths() -> void:
	# The id is the row's identity and outlives every overwrite, so it has to be
	# unique per capture and recognisable on sight.
	var seen := {}
	for i in range(200):
		seen[StatePaths.mint_id()] = true
	_eq("state/200 ids are 200 ids", seen.size(), 200)
	var one := StatePaths.mint_id()
	_ok("state/an id reads as one", StatePaths.is_state_id(one), one)
	_ok("state/a stray file does not", not StatePaths.is_state_id("autosave"))
	_ok("state/nor does a bare timestamp", not StatePaths.is_state_id("1787000000000"))
	_ok("state/nor does a path traversal", not StatePaths.is_state_id("../../etc/passwd"))

	# The three files are siblings sharing a basename: that is what lets delete
	# find them without an index, and what lets an overwrite keep its picture.
	var sp := StatePaths.state_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var shot := StatePaths.shot_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var meta := StatePaths.meta_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	_eq("state/paths differ only by extension",
		[sp.get_basename(), shot.get_basename(), meta.get_basename()],
		[sp.get_basename(), sp.get_basename(), sp.get_basename()])
	_eq("state/the state is a .state", sp.get_extension(), "state")
	_ok("state/keyed by core", sp.contains("fceumm"), sp)
	_ok("state/and by game", sp.contains("Game (USA)"), sp)
	# Two cores running the same game keep separate folders — a state is only
	# ever meaningful to the core that wrote it.
	_ok("state/another core is another folder",
		StatePaths.game_dir("nestopia", "C:/roms/nes/Game (USA).nes")
			!= StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"))
	# ...but the same game reached by a different path is the same folder, which
	# is what lets a ROM be moved without losing its states.
	_eq("state/the same game moved is the same folder",
		StatePaths.game_dir("fceumm", "D:/elsewhere/Game (USA).nes"),
		StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"))


func _test_state_thumbnail() -> void:
	# The core hands over RGBA8 with every pixel at alpha 0 — it draws opaque and
	# never writes the channel. A thumbnail that keeps it saves a fully
	# transparent rectangle, which is what this shipped as the first time.
	var frame := Image.create(256, 224, false, Image.FORMAT_RGBA8)
	frame.fill(Color(0.2, 0.6, 0.9, 0.0))
	var thumb := StatePaths.thumbnail(frame)
	_eq("thumb/alpha is dropped", thumb.get_format(), Image.FORMAT_RGB8)
	_eq("thumb/the picture survives it",
		thumb.get_pixel(thumb.get_width() / 2, thumb.get_height() / 2).a, 1.0)
	# Downscale keeps the aspect: a 4:3 frame must not come back square.
	_eq("thumb/scaled to the box", thumb.get_width(), StatePaths.THUMB_MAX_W)
	_eq("thumb/aspect kept", thumb.get_height(), 168)
	_ok("thumb/the source is left alone", frame.get_width() == 256
		and frame.get_format() == Image.FORMAT_RGBA8)

	# Never upscaled. Blowing a Game Boy frame up to fill the box only makes it
	# blurry, and the row centres it instead.
	var gb := Image.create(160, 144, false, Image.FORMAT_RGBA8)
	gb.fill(Color(1, 1, 1, 0))
	var small := StatePaths.thumbnail(gb)
	_eq("thumb/a small frame is left at its size", small.get_size(), Vector2i(160, 144))


func _test_state_disk_round_trip() -> void:
	# A scratch core name, so this writes beside the player's real states without
	# ever being able to collide with one.
	var core := "__state_selftest"
	var rom := "selftest.nes"
	var dir := StatePaths.game_dir(core, rom)
	if DirAccess.dir_exists_absolute(dir):
		for f: String in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(f))

	_eq("disk/nothing is listed to start", StatePaths.list_states(core, rom).size(), 0)

	var id := StatePaths.mint_id()
	var job := StatePaths.Job.new()
	job.state_path = StatePaths.state_path(core, rom, id)
	job.shot_path = StatePaths.shot_path(core, rom, id)
	job.meta_path = StatePaths.meta_path(core, rom, id)
	job.data = "the core".to_utf8_buffer()
	job.shot = Image.create(64, 48, false, Image.FORMAT_RGBA8)
	job.shot.fill(Color(1, 0, 0, 0))
	job.frame = 4242
	job.core = core
	job.rom = rom
	job.created_at = 1000
	_eq("disk/the write reports no error", StatePaths.write_job(job), "")

	var rows := StatePaths.list_states(core, rom)
	_eq("disk/one state is listed", rows.size(), 1)
	if rows.size() == 1:
		_eq("disk/under its own id", rows[0]["state_id"], id)
		_ok("disk/with its picture", not str(rows[0]["shot"]).is_empty())
		_eq("disk/and its size", int(rows[0]["bytes"]), job.data.size())
	var meta := StatePaths.read_meta(core, rom, id)
	_eq("disk/the sidecar carries the frame", int(meta.get("frame", -1)), 4242)
	_eq("disk/and the birthday", int(meta.get("created_at", -1)), 1000)

	# Overwrite: the same id, new contents, and the birthday is NOT restamped —
	# that is what makes a row behave like a slot rather than a new entry.
	job.data = "a longer core image".to_utf8_buffer()
	job.frame = 9999
	job.created_at = 2000
	_eq("disk/the overwrite reports no error", StatePaths.write_job(job), "")
	_eq("disk/still one state", StatePaths.list_states(core, rom).size(), 1)
	var meta2 := StatePaths.read_meta(core, rom, id)
	_eq("disk/the frame moved on", int(meta2.get("frame", -1)), 9999)
	_eq("disk/the birthday did not", int(meta2.get("created_at", -1)), 1000)
	_ok("disk/updated_at is stamped", int(meta2.get("updated_at", 0)) > 0)

	# Nothing half-written is ever offered: the promote is a rename, so a .part
	# left behind by a crash is invisible to the list.
	var stray := FileAccess.open(job.state_path + ".part", FileAccess.WRITE)
	stray.store_string("half")
	stray.close()
	_eq("disk/a .part is not a state", StatePaths.list_states(core, rom).size(), 1)
	DirAccess.remove_absolute(job.state_path + ".part")

	_eq("disk/total_bytes counts the picture too", StatePaths.total_bytes(core, rom),
		job.data.size() + NetFileTransfer.size_of(job.shot_path))

	_ok("disk/delete succeeds", StatePaths.delete_state(core, rom, id))
	_eq("disk/and the list is empty", StatePaths.list_states(core, rom).size(), 0)
	_ok("disk/the picture went with it", not FileAccess.file_exists(job.shot_path))
	_ok("disk/and the sidecar", not FileAccess.file_exists(job.meta_path))
	_ok("disk/deleting it twice is not a success", not StatePaths.delete_state(core, rom, id))
	_ok("disk/nor is deleting something that is not an id",
		not StatePaths.delete_state(core, rom, "../../boot"))
	DirAccess.remove_absolute(dir)


# ---------------------------------------------------------------------------
# BIOS boot: seeding a default, the table that decides what is offered, and the
# power button's own verdict. What a real core does with an empty disc needs a
# real core and a real BIOS and lives in Tools/bios_boot_probe.tscn.
# ---------------------------------------------------------------------------

func _test_bios_seed() -> void:
	var root := "user://__biosboot_selftest"
	var core := "selftest_core"
	var path := CoreOptionsStore.opt_path(root, core)

	_ok("seed/nothing to seed writes nothing", not CoreOptionsStore.seed_values(root, core, {}))
	_ok("seed/and creates no file", not FileAccess.file_exists(path))

	_ok("seed/a fresh key is written",
		CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}))
	_eq("seed/the default took",
		CoreOptionsStore.load_values(root, core).get("splash", ""), "enabled")

	# The whole point of a default: the player turns it off and it STAYS off.
	# merge_values would put it back on at the next power-on.
	CoreOptionsStore.set_value(root, core, "splash", "disabled")
	_ok("seed/seeding twice writes nothing",
		not CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}))
	_eq("seed/the player's choice survives",
		CoreOptionsStore.load_values(root, core).get("splash", ""), "disabled")

	# A core serialises its WHOLE option set on shutdown, so after one run every
	# key it declares is already in the file. Presence must not be mistaken for
	# "already seeded" or a BIOS installed later would never take effect.
	CoreOptionsStore.save_values(root, core, {"splash": "disabled", "later": "off"})
	_ok("seed/a key the core already wrote is still seedable",
		CoreOptionsStore.seed_values(root, core, {"later": "on"}))
	var after := CoreOptionsStore.load_values(root, core)
	_eq("seed/and takes", after.get("later", ""), "on")
	_eq("seed/without disturbing its neighbours", after.get("splash", ""), "disabled")

	# The record is per (core, key). genesis_plus_gx_bios really is shared by
	# five machines under one core, so the key alone cannot be the identity.
	_ok("seed/another core's same key is untouched",
		CoreOptionsStore.seed_values(root, "other_core", {"later": "on"}))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		CoreOptionsStore.opt_path(root, "other_core")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.seeded_path(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok("seed/cleaned up", not FileAccess.file_exists(path))


func _test_bios_boot_table() -> void:
	var db := CoreInfoDatabase.shared()
	for key: String in BiosBoot._ROWS:
		var parts := key.split("/", false)
		_eq("table/%s is keyed core-then-systemid" % key, parts.size(), 2)
		if parts.size() != 2:
			continue
		_ok("table/%s names a real core" % key,
			not db.get_by_core_name(parts[0]).is_empty())
		_ok("table/%s names a real system" % key,
			ResourceLoader.exists("res://SystemInfo/%s.tres" % parts[1]))
		var row: Dictionary = BiosBoot._ROWS[key]
		_ok("table/%s declares a boot rom" % key,
			not (row.get("boot_rom", []) as Array).is_empty())
		for opt_key: String in (row.get("splash", {}) as Dictionary):
			_ok("table/%s option %s is named" % [key, opt_key],
				not opt_key.strip_edges().is_empty())

	# Keyed on the PAIR. One core, five Sega machines, five different boot ROMs
	# — read by core alone this would offer a Game Gear the Mega Drive's.
	_eq("table/a Mega Drive wants its own boot rom",
		BiosBoot.entry("genesis_plus_gx", "mega_drive").get("boot_rom", []), ["bios_MD.bin"])
	_eq("table/a Game Gear wants its own",
		BiosBoot.entry("genesis_plus_gx", "game_gear").get("boot_rom", []), ["bios.gg"])

	# Measured, and the natural guess is the wrong way round: pcee2 says
	# pcsx2_fast_boot where LRPS2 says pcsx2_fastboot.
	_ok("table/pcee2 uses fast_boot",
		(BiosBoot.entry("pcee2", "playstation2").get("splash", {}) as Dictionary)
			.has("pcsx2_fast_boot"))
	_ok("table/pcsx2 uses fastboot",
		(BiosBoot.entry("pcsx2", "playstation2").get("splash", {}) as Dictionary)
			.has("pcsx2_fastboot"))

	# Only the PlayStation reaches a BIOS from an empty slot; measured over
	# sixteen cores, and the rest refuse a blank image or crash on one.
	_eq("table/a PlayStation takes a blank disc",
		BiosBoot.empty_media_extension("pcsx_rearmed", "playstation"), "cue")
	_eq("table/a GameCube does not",
		BiosBoot.empty_media_extension("dolphin", "gamecube"), "")
	_eq("table/nor does a machine with no row",
		BiosBoot.empty_media_extension("fceumm", "nes"), "")

	_ok("table/an unknown pair offers nothing",
		BiosBoot.entry("selftest_core", "nes").is_empty())
	_ok("table/and no splash", BiosBoot.splash_options("selftest_core", "nes").is_empty())
	_ok("table/a core with no .info requires nothing",
		BiosBoot.missing_required("selftest_core").is_empty())
	# The pair is required: a core alone names no machine.
	_ok("table/no systemid is not a match", BiosBoot.entry("pcsx_rearmed", "").is_empty())


func _test_power_on_verdict() -> void:
	var none: Array[Dictionary] = []

	var no_core := RetroSystem._power_on_verdict("", "nes", "/roms/a.nes", none, "")
	_ok("verdict/no core refuses", not no_core["start"])
	_eq("verdict/and says so", no_core["title"], "No core installed")

	var running := RetroSystem._power_on_verdict("fceumm", "nes", "/roms/a.nes", none, "")
	_ok("verdict/a game inserted starts", running["start"])
	_eq("verdict/with that game", running["rom"], "/roms/a.nes")

	var empty := RetroSystem._power_on_verdict("fceumm", "nes", "", none, "")
	_ok("verdict/an empty slot refuses when the machine cannot boot", not empty["start"])
	_eq("verdict/with the long-standing card", empty["title"], "No game inserted")
	_ok("verdict/worded for a cartridge", str(empty["description"]).contains("cartridge"))
	_eq("verdict/and nothing in the slot", empty["rom"], "")

	# The wording follows the machine, not the core. Untested before this.
	var disc := RetroSystem._power_on_verdict("pcsx_rearmed", "playstation", "", none, "")
	_ok("verdict/worded for a disc", str(disc["description"]).contains("disc"))

	# The substitution: a blank image was resolved, so the machine starts on it.
	var bios := RetroSystem._power_on_verdict(
		"pcsx_rearmed", "playstation", "", none, "/tmp/no_disc.cue")
	_ok("verdict/an empty slot with a blank disc starts", bios["start"])
	_eq("verdict/on the blank disc", bios["rom"], "/tmp/no_disc.cue")

	# A required BIOS blocks the run whether or not a game is in — the core
	# cannot start either way, and a black screen explains neither.
	var missing: Array[Dictionary] = [{
		"path": "pcsx2/bios", "desc": "'pcsx2/bios' folder",
		"dest": "/root/system/pcee2/pcsx2/bios",
	}]
	var no_bios := RetroSystem._power_on_verdict(
		"pcee2", "playstation2", "/roms/g.iso", missing, "")
	_ok("verdict/a missing required bios refuses", not no_bios["start"])
	_eq("verdict/and names the fault", no_bios["title"], "BIOS required")
	_ok("verdict/names the file",
		str(no_bios["description"]).contains("pcsx2/bios"))
	_ok("verdict/and where to get it",
		str(no_bios["description"]).contains("BIOS / Extras"))
	# The card is 520x132 px at 1400 px/m. An absolute system path overflowed it
	# top and bottom and clipped the instruction clean off — caught by rendering
	# it, not by any assertion, so the length is pinned here now.
	_ok("verdict/says it in two short lines",
		str(no_bios["description"]).split("\n").size() == 2)
	for line: String in str(no_bios["description"]).split("\n"):
		_ok("verdict/line fits the card: %s" % line, line.length() <= 52)
	_ok("verdict/one missing file is not counted up",
		not str(no_bios["description"]).contains("more"))

	var two: Array[Dictionary] = [missing[0], {
		"path": "pcsx2/resources", "desc": "'pcsx2/resources' folder",
		"dest": "/root/system/pcee2/pcsx2/resources",
	}]
	var counted := RetroSystem._power_on_verdict("pcee2", "playstation2", "/roms/g.iso", two, "")
	_ok("verdict/two missing files are counted",
		str(counted["description"]).contains("(+1 more)"))

	# Order matters: a machine that is both empty AND missing its BIOS is told
	# about the BIOS, which is the one the player cannot fix from where they
	# stand by reaching for a cartridge.
	_eq("verdict/a missing bios outranks an empty slot",
		RetroSystem._power_on_verdict("pcee2", "playstation2", "", missing, "")["title"],
		"BIOS required")


# ---------------------------------------------------------------------------
# Which machines belong to one replicated linked session.
# ---------------------------------------------------------------------------

func _test_net_link_group_merge() -> void:
	var console := Node.new()
	var gba1 := Node.new()
	var gba2 := Node.new()
	var gba3 := Node.new()
	var unrelated := Node.new()
	var buses: Array = [
		[{"machine": console}, {"machine": gba1}],
		[{"machine": console}, {"machine": gba2}],
		[{"machine": gba2}, {"machine": gba3}],
		[{"machine": unrelated}],
	]
	var group := RetroSystem.merge_link_buses(console, buses)
	_eq("link-group/the anchor stays first", group[0], console)
	_eq("link-group/every directly cabled machine is included", group.size(), 4)
	_ok("link-group/a second controller-port cable is not lost", group.has(gba2))
	_ok("link-group/transitively linked machines are included", group.has(gba3))
	_ok("link-group/an unrelated cable is excluded", not group.has(unrelated))
	console.free()
	gba1.free()
	gba2.free()
	gba3.free()
	unrelated.free()


# ---------------------------------------------------------------------------
# What the console is told about its memory card slot.
#
# Two questions that look like one. What KIND of card the slot holds is
# pcsx_rearmed_memcard1, and it gates the core's save buffer, so it is fixed for
# the run. Whether a card is IN that slot is pcsx_rearmed_memcard1_inserted,
# which touches nothing but what the SIO answers and moves whenever a hand does.
#
# Before the second key existed the room could only blank SAVE_RAM, and 128 KB
# of zeroes is a card -- merely an unformatted one. A game whose card was pulled
# mid-play offered to format it instead of saying there was no card in the slot.
# ---------------------------------------------------------------------------

func _test_memcard_presence() -> void:
	# Instantiated and added rather than built with _system(): whether a machine
	# takes cards is asked of the MODEL first, and a bare RetroSystem has none, so
	# it answers no to everything. Adding it runs _ready, which loads one.
	var psx := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	psx.systemid = "playstation"
	add_child(psx)

	# Nothing seated: the slot is typed absent AND reported empty. Both, because
	# they answer to different cores -- one built before the presence key shipped
	# reads only the first, and must still see an empty slot.
	var empty := psx._removable_media_options("pcsx_rearmed")
	_eq("memcard/an empty slot is typed absent",
		empty.get("pcsx_rearmed_memcard1", ""), "none")
	_eq("memcard/and reported empty",
		empty.get("pcsx_rearmed_memcard1_inserted", ""), "disabled")
	_eq("memcard/the cabinet's second slot is always absent",
		empty.get("pcsx_rearmed_memcard2", ""), "none")

	# A card seated before the machine starts.
	var card := Node3D.new()
	psx._snapped_memcard = card
	var seated := psx._removable_media_options("pcsx_rearmed")
	_eq("memcard/a seated card types the slot",
		seated.get("pcsx_rearmed_memcard1", ""), "libretro")
	_eq("memcard/and is reported present",
		seated.get("pcsx_rearmed_memcard1_inserted", ""), "enabled")

	# Only pcsx_rearmed has these keys, and only a machine that takes cards has a
	# slot. Pinning them anywhere else would write keys into another core's file.
	_ok("memcard/another core is told nothing",
		psx._removable_media_options("swanstation").is_empty())
	var nes := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	nes.systemid = "nes"
	add_child(nes)
	_ok("memcard/a cartridge console is told nothing",
		nes._removable_media_options("pcsx_rearmed").is_empty())

	# The runtime half. It reaches for the live core, so on a machine that is not
	# running it must do nothing at all rather than fault -- which is also what
	# guards the case where the option arrives before a core exists to take it.
	psx._set_card_presence(false)
	_ok("memcard/presence on a machine that is off does nothing",
		not psx.is_powered_on)

	card.free()
	nes.queue_free()
	psx.queue_free()
