## AV suite — what reaches a television's inputs, and what it shows.
##
## Covers the two halves that used to be worked out in several places at once:
## ROUTING (which cords reach which socket, across every lead a device is on) and
## DISPLAY (which input the set is showing, and what it paints when there is
## nothing). Every bug this suite pins down shipped at least once.
##
##   godot --headless --path RetroXR res://Tests/av_suite.tscn
##   godot --headless --path RetroXR res://Tests/av_suite.tscn -- --only=display
##
## Exits non-zero if anything fails. Headless on purpose: these are decisions, not
## appearances — what a picture LOOKS like needs a windowed run and a photograph.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const VCR_SCENE := preload("res://Scenes/Objects/appliances/vcr_player.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const VGA_CABLE := preload("res://Scenes/Objects/cables/vga_cable.tscn")
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

## A machine or deck reduced to the contract a television actually reads.
## Real hardware is used wherever routing is the thing under test; this stands in
## when the test is about what the SET does with what it is handed.
class StubSource extends Node3D:
	var texture: Texture2D = null
	var stage: Dictionary = {}
	## Per-TV stages, keyed by the asking set — a dual-screen machine answers each
	## of its two televisions differently.
	var stage_by_tv: Dictionary = {}
	var rf_channel: int = -1
	var volumes: Array[float] = []

	func get_video_texture() -> Texture2D:
		return texture

	func get_video_stage(tv: Node) -> Dictionary:
		return stage_by_tv.get(tv, stage)

	func set_audio_volume(v: float) -> void:
		volumes.append(v)

	func get_rf_channel() -> int:
		return rf_channel


var _case := ""
var _failed_cases := {}
var _checks := 0
var _spawned: Array[Node] = []


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[av] TIMEOUT during '%s'" % _case)
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.split("=")[1]

	var cases: Array = [
		["routing/one lead carries picture and both channels", _r_one_lead],
		["routing/two leads, neither clobbers the other", _r_two_leads],
		["routing/crossed audio pair swaps the speakers", _r_crossed],
		["routing/picture into an audio socket is not a picture", _r_video_into_audio],
		["routing/pulling the picture cord leaves the sound", _r_pull_picture],
		["routing/picture and sound on different inputs: picture wins", _r_video_wins],
		["routing/a machine on VGA is filed on the VGA input", _r_vga],
		["display/a monitor lands on its own socket, not the tuner", _d_monitor_default],
		["display/the selected input is shown", _d_selected],
		["display/another input is blue, not the last picture", _d_away],
		["display/coming back shows it again", _d_back],
		["display/a source that stops is blue, not frozen", _d_stopped],
		["display/a set switched off is dark", _d_off],
		["display/an empty input is blue", _d_empty],
		["display/the aerial input on the wrong channel is snow", _d_rf_untuned],
		["display/the aerial input on the right channel shows the machine", _d_rf_tuned],
		["display/a source's own stage shader is used", _d_stage],
		["display/two sets get their own window of one picture", _d_stage_per_tv],
		["guard/a host that is not shown is refused", _g_refused],
		["guard/the shown host may paint", _g_allowed],
		["guard/only the owner may take the picture down", _g_release],
		["audio/only the selected input is heard", _a_selected_only],
		["audio/a machine with nowhere to show is not heard", _a_no_display],
	]

	print("[av] running %d cases%s" % [cases.size(), "" if only.is_empty() else " matching '%s'" % only])
	for c: Array in cases:
		var name: String = c[0]
		if not only.is_empty() and not name.contains(only):
			continue
		_case = name
		await (c[1] as Callable).call()
		await _teardown()
		if not _failed_cases.has(name):
			print("[av] PASS  %s" % name)

	print("[av] %d checks, %d case(s) failed" % [_checks, _failed_cases.size()])
	print("[av] RESULT=%s" % ("FAIL" if _failed_cases.size() > 0 else "PASS"))
	get_tree().quit(1 if _failed_cases.size() > 0 else 0)


# ── Checks ────────────────────────────────────────────────────────────────────

func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		return
	_failed_cases[_case] = true
	print("[av] FAIL  %s\n[av]         %s" % [_case, what])


func _check_eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s: got %s, want %s" % [what, got, want])


# ── Building a room ───────────────────────────────────────────────────────────

func _tv() -> RetroTV:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.freeze = true
	tv.position = Vector3(_spawned.size() * 3.0, 1, 0)
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	return tv


func _deck() -> VCRPlayer:
	var deck := VCR_SCENE.instantiate() as VCRPlayer
	deck.freeze = true
	deck.position = Vector3(_spawned.size() * 3.0, 1, 1.2)
	add_child(deck)
	deck.add_to_group("spawned")
	_spawned.append(deck)
	return deck


## The three sockets of one composite input, in cord order (VIDEO, L, R).
func _input_ports(tv: RetroTV, input: int) -> Array[RcaPort]:
	var suffix := "" if input == 0 else str(input + 1)
	var out: Array[RcaPort] = []
	for base in ["CompositePort", "AudioLIn", "AudioRIn"]:
		out.append(tv.get_node_or_null(base + suffix) as RcaPort)
	return out


func _out_ports(deck: Node3D) -> Array[RcaPort]:
	var out: Array[RcaPort] = []
	for n in ["VideoOut", "AudioLOut", "AudioROut"]:
		out.append(deck.get_node_or_null(n) as RcaPort)
	return out


## Spawn a lead and seat the cords named in `pairs` — [[cord, from, to], …].
func _lead(pairs: Array) -> Node3D:
	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(_spawned.size() * 3.0, 1, 0.6)
	add_child(cable)
	_spawned.append(cable)
	await _wait(20)
	for p: Array in pairs:
		var cord: int = p[0]
		(p[1] as RcaPort).pick_up_object(cable.get_node("PlugA%d" % cord) as RcaPlug)
		(p[2] as RcaPort).pick_up_object(cable.get_node("PlugB%d" % cord) as RcaPlug)
		await _wait(6)
	await _wait(25)
	return cable


## Put a stub on one of a set's inputs without cabling it up: these cases are
## about what the SET does, and _connected_systems is what it reads.
func _seat_stub(tv: RetroTV, input: int, source: StubSource) -> void:
	add_child(source)
	_spawned.append(source)
	tv._connected_systems[input] = source
	tv.set_source(input)
	await _wait(4)


## Take a plug out and leave it out.
##
## Dropping one is not enough, and shutting its own socket is not either: it is
## released standing in front of a whole back panel of sockets whose grab zones
## reach 60 mm, and whichever one is nearest takes it — the log reads "pulled
## VIDEO on TV" followed immediately by "seated VIDEO on TV". So every socket in
## the room is shut for the move, and the plug is frozen where it is put, because
## a live one falls back down past the panel and is caught on the way.
func _unplug(plug: RcaPlug) -> void:
	var shut: Array[RcaPort] = []
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.enabled:
			port.enabled = false
			shut.append(port)
	var seated := plug.seated_port()
	if seated != null:
		seated.drop_object()
	await _wait(4)
	plug.freeze = true
	plug.global_position += Vector3(0.0, 3.0, 0.0)
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	await _wait(15)
	for port in shut:
		if is_instance_valid(port):
			port.enabled = true
	await _wait(15)


func _which_input(tv: RetroTV, dev: Node3D) -> int:
	for i in (tv._connected_systems as Array).size():
		if tv._connected_systems[i] == dev:
			return i
	return -1


func _glass(tv: RetroTV) -> Material:
	return tv.get_screen_mesh().get_surface_override_material(0)


## The texture the glass is sampling, however it is being shown.
##
## Through the set's own record when the CRT material is up: phosphor persistence
## legitimately swaps source_tex for its ping-pong buffer, so reading the uniform
## back would report a ViewportTexture rather than the picture behind it.
func _shown(tv: RetroTV) -> Texture2D:
	var mat := _glass(tv)
	if mat == tv._crt_material:
		return tv._crt_source_tex
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		return std.emission_texture if std.emission_texture != null else std.albedo_texture
	return null


func _a_texture(colour: Color = Color.WHITE) -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	return ImageTexture.create_from_image(img)


func _teardown() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.queue_free()
	_spawned.clear()
	await _wait(3)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame


# ── Routing ───────────────────────────────────────────────────────────────────

func _r_one_lead() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_4)
	var outs := _out_ports(deck)
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck.connected_tv == tv, "the deck should know which set it feeds")
	_check(deck._feed_video, "the picture should have a path")
	_check_eq(deck._feed_left, 0, "left channel lands on the left speaker")
	_check_eq(deck._feed_right, 1, "right channel lands on the right speaker")
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_4, "the set files the deck")


func _r_two_leads() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_4)
	var outs := _out_ports(deck)
	# Picture on one lead, the pair on another. Each cable reports only its own
	# cords, so the deck has to read every lead it is on rather than the last
	# report it was handed.
	var picture := await _lead([[0, outs[0], ins[0]]])
	var sound := await _lead([[1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck._feed_video, "the picture survives the sound lead resolving after it")
	_check_eq(deck._feed_left, 0, "left channel")
	_check_eq(deck._feed_right, 1, "right channel")

	# And neither report order loses the other half.
	deck.on_av_topology_changed(sound.links())
	await _wait(3)
	_check(deck._feed_video, "a report from the sound lead must not drop the picture")
	deck.on_av_topology_changed(picture.links())
	await _wait(3)
	_check(deck._feed_left == 0 and deck._feed_right == 1,
		"a report from the picture lead must not drop the sound")


func _r_crossed() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(deck)
	# The pair swapped at the set's end: what a player does by accident, and the
	# whole reason the two channels are tracked separately.
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[2]], [2, outs[2], ins[1]]])
	_check(deck._feed_video, "the picture is unaffected")
	_check_eq(deck._feed_left, 1, "the left channel comes out of the RIGHT speaker")
	_check_eq(deck._feed_right, 0, "the right channel comes out of the LEFT speaker")


func _r_video_into_audio() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_2)
	var outs := _out_ports(deck)
	# The yellow plug in a white socket. Sound still arrives, so the deck reads as
	# connected — which is exactly how "I can hear it but not see it" happens.
	await _lead([[0, outs[0], ins[1]], [2, outs[2], ins[2]]])
	_check(deck.connected_tv == tv, "the deck is still connected")
	_check(not deck._feed_video, "a picture into an audio socket is not a picture")
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_2,
		"the set still files it on that input, on the strength of the sound")


func _r_pull_picture() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(deck)
	var lead := await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck._feed_video, "the picture starts connected")
	await _unplug(lead.get_node("PlugB0") as RcaPlug)
	_check(not deck._feed_video, "pulling the picture cord takes the picture away")
	_check(deck._feed_left == 0 and deck._feed_right == 1, "the sound is untouched")


func _r_video_wins() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var two := _input_ports(tv, RetroTV.Source.COMPOSITE_2)
	var three := _input_ports(tv, RetroTV.Source.COMPOSITE_3)
	var outs := _out_ports(deck)
	# Picture into one input, sound into another: the input is named for the
	# picture, so that is the one the deck belongs to.
	await _lead([[0, outs[0], two[0]]])
	await _lead([[1, outs[1], three[1]], [2, outs[2], three[2]]])
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_2, "the picture decides")


## A computer monitor and a tower: one DE-15 at each end and no phono row anywhere.
##
## The DE-15 used to answer for Composite 1, which meant a cabinet with no phono
## sockets at all announced "COMPOSITE 1", and a cabinet carrying both would have
## had them share one slot — plug in either and it evicts the other.
func _r_vga() -> void:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.tv_model = "crt_monitor"
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.model_id = "pc_tower"
	sys.systemid = "dos"
	sys.position = Vector3(2.0, 1, 0)
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(60)

	var tower_vga := sys.find_child("VgaPort", true, false) as XRToolsSnapZone
	var mon_vga := tv.get_node_or_null("VgaPort") as XRToolsSnapZone
	_check(tower_vga != null, "the tower wears a DE-15")
	_check(mon_vga != null and mon_vga.enabled, "the monitor's DE-15 is fitted and live")
	if tower_vga == null or mon_vga == null:
		return

	var lead := VGA_CABLE.instantiate() as Node3D
	lead.position = Vector3(1.0, 1, -0.5)
	add_child(lead)
	_spawned.append(lead)
	await _wait(20)
	tower_vga.pick_up_object(lead.get_node("PlugA0"))
	mon_vga.pick_up_object(lead.get_node("PlugB0"))
	await _wait(40)
	_check_eq(_which_input(tv, sys), RetroTV.Source.VGA, "the tower is filed on VGA")
	_check(sys.connected_tv == tv, "and the tower knows which monitor it feeds")


func _d_monitor_default() -> void:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.tv_model = "crt_monitor"
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	await _wait(40)
	# The tuner is available on every set, so picking the first available input in
	# enum order would sit a monitor on a channel list rather than on its one socket.
	_check_eq(tv.current_source, RetroTV.Source.VGA, "a monitor starts on its DE-15")
	_check(not tv._source_available(RetroTV.Source.COMPOSITE_1),
		"and does not offer a phono input it has no socket for")


# ── Display ───────────────────────────────────────────────────────────────────

func _d_selected() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	_check_eq(_shown(tv), src.texture, "the set shows the input it is on")


func _d_away() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	_check(_shown(tv) != src.texture, "an input with nothing on it must not show the other one")
	_check_eq(_shown(tv), tv._blue_texture, "it shows the no-signal screen")


func _d_back() -> void:
	# The reported bug: play, change input, come back, and the picture is gone
	# until you restart the source.
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	tv.set_source(RetroTV.Source.COMPOSITE_3)
	await _wait(6)
	_check_eq(_shown(tv), src.texture, "coming back to the input shows it again")


func _d_stopped() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	src.texture = null                   # switched off / stopped / unplugged
	await _wait(6)
	_check_eq(_shown(tv), tv._blue_texture, "a source that stops leaves no frozen frame")


func _d_off() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.remote_power_toggle()          # the set has no setter; this is the POWER key
	await _wait(6)
	_check(_shown(tv) != src.texture, "a set that is off shows nothing")
	_check_eq(_glass(tv), tv._dark_material, "it wears its own dark glass")


func _d_empty() -> void:
	var tv := _tv()
	await _wait(30)
	tv.set_source(RetroTV.Source.COMPOSITE_2)
	await _wait(6)
	_check_eq(_shown(tv), tv._blue_texture, "an input with nothing plugged in is blue")


func _d_rf_untuned() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	src.rf_channel = 4 if tv.rf_channel != 4 else 3     # deliberately not the set's
	await _seat_stub(tv, RetroTV.Source.RF, src)
	await _wait(6)
	_check(_shown(tv) != src.texture, "a machine modulating on the other channel is not shown")
	_check_eq(_glass(tv), tv._rf_static_material,
		"an aerial channel with nothing on it is SNOW, not the blue no-signal screen")


func _d_rf_tuned() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	src.rf_channel = tv.rf_channel                      # the one the set is tuned to
	await _seat_stub(tv, RetroTV.Source.RF, src)
	await _wait(6)
	_check_eq(_shown(tv), src.texture, "tuned to its channel, the machine appears")
	_check(tv.can_paint(src), "and it counts as the shown input")


func _d_stage() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	# A source that wants its picture put through a shader of its own — what the
	# VHS effect is. The set runs it; the source never touches a material.
	src.stage = {"shader": WINDOW_SHADER,
		"params": {"source_rect": Vector4(0.0, 0.5, 1.0, 0.5), "eye_shift": 0.0}}
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mat := _glass(tv) as ShaderMaterial
	_check(mat != null and mat.shader == WINDOW_SHADER, "the set uses the source's shader")
	if mat != null:
		_check_eq(mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.5, 1.0, 0.5),
			"and the source's own uniforms")
		_check_eq(mat.get_shader_parameter("source_tex"), src.texture, "fed with its picture")


func _d_stage_per_tv() -> void:
	var tv_top := _tv()
	var tv_bottom := _tv()
	await _wait(30)
	# One machine, two sets, one composite frame: each set gets its own window of
	# it (the dual-screen handhelds).
	var src := StubSource.new()
	src.texture = _a_texture()
	src.stage_by_tv = {
		tv_top: {"shader": WINDOW_SHADER,
			"params": {"source_rect": Vector4(0.0, 0.0, 1.0, 0.5), "eye_shift": 0.0}},
		tv_bottom: {"shader": WINDOW_SHADER,
			"params": {"source_rect": Vector4(0.0, 0.5, 1.0, 0.5), "eye_shift": 0.0}},
	}
	add_child(src)
	_spawned.append(src)
	tv_top._connected_systems[RetroTV.Source.COMPOSITE_1] = src
	tv_bottom._connected_systems[RetroTV.Source.COMPOSITE_1] = src
	tv_top.set_source(RetroTV.Source.COMPOSITE_1)
	tv_bottom.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	var top_mat := _glass(tv_top) as ShaderMaterial
	var bottom_mat := _glass(tv_bottom) as ShaderMaterial
	_check(top_mat != null and bottom_mat != null, "both sets show the machine")
	if top_mat != null and bottom_mat != null:
		_check_eq(top_mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.0, 1.0, 0.5),
			"the first set gets the top half")
		_check_eq(bottom_mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.5, 1.0, 0.5),
			"the second set gets the bottom half")


# ── The set's guard ───────────────────────────────────────────────────────────

func _g_refused() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	var before := _glass(tv)
	var rogue := StandardMaterial3D.new()
	rogue.albedo_color = Color(1, 0, 1, 1)
	_check(not tv.can_paint(src), "a host on another input may not paint")
	_check(not tv.paint_screen(src, rogue), "and is refused when it tries")
	_check_eq(_glass(tv), before, "the glass is left alone")


func _g_allowed() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mine := StandardMaterial3D.new()
	_check(tv.can_paint(src), "the shown host may paint")
	_check(tv.paint_screen(src, mine), "and its paint is accepted")
	_check_eq(_glass(tv), mine, "its material is on the glass")
	_check_eq(tv._screen_owner, src, "and the set records who put it there")


func _g_release() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mine := StandardMaterial3D.new()
	tv.paint_screen(src, mine)
	var stranger := StubSource.new()
	add_child(stranger)
	_spawned.append(stranger)
	tv.release_screen(stranger)
	_check_eq(_glass(tv), mine, "a stranger cannot take somebody else's picture down")
	tv.release_screen(src)
	_check(_glass(tv) != mine, "the owner can")


# ── Audio ─────────────────────────────────────────────────────────────────────

func _a_selected_only() -> void:
	var tv := _tv()
	await _wait(30)
	var shown := StubSource.new()
	var hidden := StubSource.new()
	add_child(shown)
	add_child(hidden)
	_spawned.append(shown)
	_spawned.append(hidden)
	tv._connected_systems[RetroTV.Source.COMPOSITE_1] = shown
	tv._connected_systems[RetroTV.Source.COMPOSITE_2] = hidden
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(4)
	shown.volumes.clear()
	hidden.volumes.clear()
	tv.remote_volume_up()
	await _wait(4)
	_check(not shown.volumes.is_empty() and shown.volumes.back() > 0.0,
		"the input being watched is heard (got %s)" % str(shown.volumes))
	_check(not hidden.volumes.is_empty() and hidden.volumes.back() == 0.0,
		"the other input is silent (got %s)" % str(hidden.volumes))


func _a_no_display() -> void:
	# A machine wired to nothing makes no sound. This used to fall out of having
	# no screen mesh to paint, which stopped being a thing that could be asked.
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(40)
	_check(not sys._has_display(), "a console with no television has nowhere to show")
	var tv := _tv()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(sys)
	if outs[0] == null:
		print("[av]         (this cabinet wears a captive lead, not sockets — skipped)")
		return
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(sys._has_display(), "cabling it to a set gives it one")
