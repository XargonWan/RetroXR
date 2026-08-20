## The cable, in the room, with real machines on the end of it.
##
##     "$godot" --headless --path RetroXR res://Tools/link_room_probe.tscn -- --roms=Z:/roms
##
## Every other check on this feature tests one layer. The coordinator's C++ tests
## drive the bus directly, link_tests drives the scene logic with no core behind
## it, and mario_link_probe calls LinkConnect by hand and then plays a game. None
## of them touches the path a PLAYER uses, which is: pick a lead up, push a plug
## into a socket, and have two consoles start talking.
##
## That path runs through a snap zone, a plug group, a chain walk over junctions
## and LinkConnectGroup, and it is where an integration fault would live -- a
## socket that takes the plug and tells nobody, a lead that joins the machines
## and never unjoins them, a junction that conducts one way. So this seats real
## plugs into real GBA models with real cores running behind them, using the same
## snap-zone call a released hand makes.
##
## Three machines, not two, because the third is the only thing that exercises
## the junction, and a junction is a socket with no core behind it: the walk has
## to conduct THROUGH it rather than stop there.
extends Node3D

const SYS_SCENE := "res://Scenes/Objects/system.tscn"
const CABLE_SCENE := "res://Scenes/Objects/cables/link_cable.tscn"
const CORE := "mgba"
const OPT_KEY := "mgba_link_cable"

var _pass := 0
var _fail := 0
var _opt_path := ""
var _opt_backup := ""
var _restored := false
var _systems: Array[RetroSystem] = []
var _cables: Array[Node3D] = []


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[room] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var rom := _find_rom()
	if rom.is_empty():
		print("[room] SKIP  no .gba ROM found; pass --roms=<library>")
		get_tree().quit(0)
		return
	print("[room] rom  %s" % rom)

	var root := CoreDownloadManager.default_core_root()
	if not FileAccess.file_exists(root.path_join("cores").path_join(CORE + "_libretro.dll")):
		print("[room] SKIP  the %s core is not installed" % CORE)
		get_tree().quit(0)
		return
	if not _enable_link_option(root):
		print("[room] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	# Three handhelds, switched on, exactly as the room builds them.
	#
	# Deliberately a MIXED set: a plain GBA, an SP, and another plain one. The GBA
	# and the SP are two models of one platform and their sockets sit in different
	# places on different shells, so a pair of identical machines would never
	# catch a port wired up on one model and not the other -- which is the most
	# ordinary way for a player's first attempt to be a mixed pair.
	var models: Array[String] = ["", "game_boy_advance_sp_primitive", ""]
	for i in range(3):
		var sys := (load(SYS_SCENE) as PackedScene).instantiate() as RetroSystem
		sys.systemid = "game_boy_advance"
		sys.model_id = models[i]
		sys.core_name = CORE
		sys.name = "GBA%d" % i
		add_child(sys)
		_systems.append(sys)
	await get_tree().process_frame
	for sys in _systems:
		sys.rom_path = rom
		sys.power_on()
	for i in _systems.size():
		_ok("machine %d powered on" % i, _systems[i].is_powered_on)
	await _settle(40)

	var ports: Array[LinkPort] = []
	for sys in _systems:
		var port := sys.find_child("LinkPort", true, false) as LinkPort
		ports.append(port)
	_ok("every GBA model carries a link socket", ports.count(null) == 0)
	if ports.count(null) > 0:
		return _finish()

	# ── One lead, two machines ────────────────────────────────────────────────
	var lead := (load(CABLE_SCENE) as PackedScene).instantiate() as LinkCable
	lead.name = "Lead0"
	add_child(lead)
	_cables.append(lead)
	await get_tree().process_frame

	_eq("nobody is cabled to start with", _peers(0), 0)

	(ports[0] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugA0"))
	await _settle(4)
	_eq("one end in a socket is still nobody", _peers(0), 0)

	(ports[1] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugB0"))
	await _settle(4)
	_eq("both ends in leaves machine 0 on a bus of two", _peers(0), 2)
	_eq("and machine 1 with it", _peers(1), 2)
	_eq("machine 2 is untouched", _peers(2), 0)

	# ── Pulling a plug ────────────────────────────────────────────────────────
	# The diegetic action and the emulated one are the same action, which is the
	# nicest property this feature has: yanking the lead IS detach.
	await _pull(lead.get_node("PlugB0") as RcaPlug)
	_eq("pulling one end drops machine 0", _peers(0), 0)
	_eq("and machine 1 with it", _peers(1), 0)

	(ports[1] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugB0"))
	await _settle(4)
	_eq("pushing it back in joins them again", _peers(0), 2)

	# ── A third player, through the junction ──────────────────────────────────
	# The junction is a socket on a lead rather than on a machine, so the walk
	# has to conduct through it and pick up whatever is on the far side. This is
	# the case a two-machine test can never reach.
	var lead2 := (load(CABLE_SCENE) as PackedScene).instantiate() as LinkCable
	lead2.name = "Lead1"
	add_child(lead2)
	_cables.append(lead2)
	await get_tree().process_frame

	var junction := lead.junction_port()
	_ok("the lead carries a junction socket", junction != null)
	if junction == null:
		return _finish()

	(junction as XRToolsSnapZone).pick_up_object(lead2.get_node("PlugA0"))
	await _settle(4)
	_eq("a second lead hanging off the junction changes nothing yet", _peers(0), 2)

	(ports[2] as XRToolsSnapZone).pick_up_object(lead2.get_node("PlugB0"))
	await _settle(6)
	_eq("the third machine joins the same bus", _peers(0), 3)
	_eq("as seen from the second", _peers(1), 3)
	_eq("and from the third itself", _peers(2), 3)

	# ── Carrying a lead out of the room ───────────────────────────────────────
	# _exit_tree counts as a pull. Leaving the cores joined would hold each other
	# up over a lead that no longer exists, and a scene change does exactly this.
	lead2.queue_free()
	_cables.erase(lead2)
	await _settle(6)
	_eq("removing the second lead drops the third machine", _peers(2), 0)
	_eq("and leaves the original pair joined", _peers(0), 2)

	_finish()


## Pull a plug out and get it clear, the way a hand carrying it away does.
##
## A dropped plug is a live rigid body a few millimetres from the socket it just
## left, and it falls straight back into it: the log reads "pulled" followed
## immediately by "seated", and the machines never notice they were parted. So
## every socket is shut for the move and the plug is frozen where it is put. The
## A/V suite carries the same helper for the same reason, which is the tell that
## this is the room behaving normally rather than a quirk of link leads.
func _pull(plug: RcaPlug) -> void:
	var shut: Array[RcaPort] = []
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.enabled:
			port.enabled = false
			shut.append(port)
	var seated := plug.seated_port()
	if seated != null:
		seated.drop_object()
	await _settle(4)
	plug.freeze = true
	plug.global_position += Vector3(0.0, 3.0, 0.0)
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	await _settle(6)
	for port in shut:
		if is_instance_valid(port):
			port.enabled = true
	plug.freeze = false
	await _settle(6)


## The machines still have to RUN while all this happens.
##
## Waiting on process frames alone would pass on a pair of cores that had stopped
## dead, which is exactly the failure a barrier can cause: counted in emulated
## frames, a stalled machine never satisfies the wait and the run times out
## instead of reporting a false pass.
func _settle(frames: int) -> void:
	var targets: Array[int] = []
	for sys in _systems:
		targets.append(int(sys.get_libretro_node().GetFrameCount()) + frames)
	while true:
		var done := true
		for i in _systems.size():
			if int(_systems[i].get_libretro_node().GetFrameCount()) < targets[i]:
				done = false
		if done:
			return
		await get_tree().process_frame


func _peers(which: int) -> int:
	var lib: Libretro = _systems[which].get_libretro_node()
	return lib.LinkPeerCount(0) if lib != null else -1


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[room] PASS  %s" % name)
	else:
		_fail += 1
		print("[room] FAIL  %s%s" % [name, "  - " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


func _finish() -> void:
	for cable in _cables:
		if is_instance_valid(cable):
			cable.queue_free()
	for sys in _systems:
		if is_instance_valid(sys):
			sys.power_off()
	for i in range(60):
		await get_tree().process_frame
	_restore()
	print("[room] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _find_rom() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
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
				if f.to_lower().ends_with(".gba"):
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
	# "ON", the option's own VALUE, not "enabled", which is only the label the
	# menu prints beside it. Writing the label put a string the option does not
	# offer into the file: the core read it, matched nothing, and left the link
	# driver uninstalled -- so a probe that wrote it was exercising a
	# configuration no player can produce, and passed while the room failed.
	lines.append('%s = "ON"' % OPT_KEY)

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
