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
