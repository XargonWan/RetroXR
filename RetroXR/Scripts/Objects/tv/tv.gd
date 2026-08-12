## TV — pickable television with a screen surface and a composite video input port.
class_name RetroTV
extends XRToolsPickable


## Emitted when a cable plug connects to this TV's composite port
signal cable_connected(plug)

## Emitted when the cable plug disconnects
signal cable_disconnected


const CRT_SHADER := preload("res://Shaders/crt_effect.gdshader")
const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")
# Dual-screen handhelds mirror one channel of their composite framebuffer onto
# the TV through this shader; the CRT stage chains inside it like the VCR's.
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")
# Analog snow, shown by the built-in tuner for every failure. Named here too
# because _route_osd and _update_crt both have to recognise it on the screen.
const STATIC_SHADER := preload("res://Shaders/tv_static.gdshader")

## Which input the set is showing. COMPOSITE_1..4 are the physical sockets on the
## back — a console, VCR or DVD deck on a composite lead — TV is the built-in tuner
## (see tv_tuner.gd) fed by channels.json, and RF is the aerial socket, which is how
## a console reaches a set through an RF switch (see rf_switch.gd).
##
## The composite inputs come FIRST and are contiguous, so a composite input's index
## is its own Source value and every per-input array is indexed by it directly. TV
## and RF are appended for the same reason: appending leaves that identity alone.
##
## RF is a real input rather than a flavour of TV even though a set has one aerial
## hole, because the tuner and an RF switch are two different things arriving at it
## and the viewer picks between them with SOURCE. The TV slot in the per-input arrays
## below is therefore always null — the tuner is not a "connected system" — and it is
## kept only so the arrays stay indexable by Source throughout.
##
## Named Source, not Input: `Input` is a native Godot singleton and an enum of
## that name shadows it, which fails to parse.
enum Source { COMPOSITE_1, COMPOSITE_2, COMPOSITE_3, COMPOSITE_4, TV, RF }

## How many composite inputs the set has. The back panel carries a socket trio per
## input (see tv.tscn) and tv_shell.gd lays them out for a fitted cabinet.
const COMPOSITE_INPUTS := 4

## Names as they appear in the OSD when SOURCE cycles. The OSD shouts, the way it
## does for POWER and MUTE; the back panel prints the same names in its own voice
## (AV_INPUT_NAMES).
const SOURCE_NAMES := ["COMPOSITE 1", "COMPOSITE 2", "COMPOSITE 3", "COMPOSITE 4",
	"TV", "RF"]

## The channels an RF switch can put a console on, and what the set has to be tuned
## to for it to appear. Two of them because that is what the switch on the back of an
## NES offers; the set steps between them with the CH keys while RF is selected.
const RF_CHANNELS := [3, 4]

## The same four inputs as SILK-SCREENED beside their sockets — title case, because
## that is printing rather than shouting. Fed to AvLegend.title.
const AV_INPUT_NAMES := ["Composite 1", "Composite 2", "Composite 3", "Composite 4"]

## Emitted when the selected source changes, so panels can follow.
signal source_changed(source: int)

## CRT display filter (curvature, scanlines, aperture mask). Applied to
## whatever source is showing — a system's game or the VCR's video.
@export var crt_enabled: bool = true

## Which cabinet to wear. Empty = the original box body authored in tv.tscn, and
## _load_shell() is then a strict no-op — the arcade and den TVs must render
## bit-identically to before this system existed.
@export var tv_model: String = ""

## Cabinet variants. A shell supplies geometry plus Marker3D seats; every
## functional node stays on this TV. See Scripts/Objects/tv/tv_shell.gd.
const _SHELL_SCENES := {
	"crt_90s":     "res://Scenes/Objects/tv_models/crt_90s.tscn",
	"crt_monitor": "res://Scenes/Objects/tv_models/crt_monitor.tscn",
	"crt_plain":   "res://Scenes/Objects/tv_models/crt_plain.tscn",
}

var _shell: RetroTVShell = null

# Whether the worn shell named speaker seats. False means the markers still hold
# the stock body's positions and _ready recomputes them for the fitted tube.
var _speakers_seated: bool = false

@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
## Composite 1's video socket. Kept as a named handle because that one socket is
## named from outside this script — a console's captive lead restores into it
## (system.gd::_snap_cable_to_tv), netplay names it, and the save file names it.
@onready var _composite_port: XRToolsSnapZone = $CompositePort
## Every A/V input socket, [input][VIDEO, L, R]. Filled by _collect_av_ports from
## the scene's fixed names, and seated as whole GROUPS rather than left where
## tv.tscn put them — see _seat_av_row.
var _av_ports: Array = []
## Off unless the fitted shell carries a VgaPortSeat — see _seat_vga_port.
@onready var _vga_port: XRToolsSnapZone = $VgaPort
## The aerial socket, Source.RF's one hole. Always fitted: every television has one,
## and unlike the VGA socket there is no cabinet in the project that would not.
@onready var _rf_port: XRToolsSnapZone = $RfPort
@onready var _ambilight: SpotLight3D = $Ambilight
@onready var _mute_btn: VRButton = $MuteButton
@onready var _audio_mode_btn: VRButton = $AudioModeButton
@onready var _vol_down_btn: VRButton = $VolumeDownButton
@onready var _vol_up_btn: VRButton = $VolumeUpButton
@onready var _tv_toggle_btn: VRButton = $TVToggleButton
@onready var _crt_btn: VRButton = $CRTButton
@onready var _source_btn: VRButton = $SourceButton
@onready var _ch_down_btn: VRButton = $ChannelDownButton
@onready var _ch_up_btn: VRButton = $ChannelUpButton
@onready var _stereo_btn: VRButton = $StereoButton
@onready var _aspect_btn: VRButton = $AspectButton
@onready var _speaker_l: Marker3D = get_node_or_null("SpeakerL")
@onready var _speaker_r: Marker3D = get_node_or_null("SpeakerR")
@onready var _osd_label: Label3D = $ScreenMesh/OSDLabel
@onready var _vol_osd_label: Label3D = $ScreenMesh/VolumeOSDLabel
@onready var _osd_viewport: SubViewport = $OSDViewport
@onready var _osd_text_2d: Label = $OSDViewport/OSDText
@onready var _vol_osd_text_2d: Label = $OSDViewport/VolOSDText
@onready var _options_panel: TVOptionsPanel = $TVOptionsPanel

# CRT wrap state: the ShaderMaterial we install over the source material, and
# the source material we replaced (restored when the filter turns off).
var _crt_material: ShaderMaterial = null
var _crt_wrapped: Material = null

# Stereo wrapper for full-frame side-by-side sources (Virtual Boy): a
# screen_window material (left-eye window + eye_shift, CRT chained inside) that
# stays installed regardless of the CRT toggle, so the per-eye split never
# depends on the tube filter.
var _stereo_material: ShaderMaterial = null

# Stereo presentation for stereo sources (the 3D bezel button, visible only
# while one is connected): 0 = per-eye stereo, 1 = left eye, 2 = right eye.
var stereo_mode: int = 0

## Picture shape. A CRT is a 4:3 tube, so that is the resting state and the one
## every source used to get by default — the frame was simply stretched to the
## glass, which squashed anything widescreen. Pressing the button shows the
## picture at 16:9 instead, letterboxed into the same tube.
##
## Deliberately a toggle between two fixed shapes rather than a mode cycle
## following what the core reports: which of the two a game wants is a thing the
## player can see, and a set of this era had exactly this button.
var widescreen: bool = false

const ASPECT_4_3 := 4.0 / 3.0
const ASPECT_16_9 := 16.0 / 9.0
const STEREO_MODE_NAMES := ["3D: STEREO", "3D: LEFT EYE", "3D: RIGHT EYE"]

## The set's speaker switch, in the OSD's own voice (it shouts).
const AUDIO_MODE_NAMES := ["STEREO", "MONO LEFT", "MONO RIGHT"]
## 0 stereo, 1 the left channel from both speakers, 2 the right from both.
var audio_mode: int = 0

# Tunable CRT display-stage uniforms (crt_filter.gdshaderinc). Adjustable from
# the TV options panel; applied to whichever material carries the CRT stage (our
# wrapper or the chained VCR shader). Defaults mirror the shader's own defaults.
#
# crt_mask_pitch_mm and crt_persistence are NOT shader uniforms — they're the
# authoring values behind ones that are (see _apply_derived_crt_params and
# _update_phosphor).
var _crt_params := {
	"crt_curvature": 0.0,          # geometry now — see Tools/gen_curved_screen.gd
	"crt_corner_radius": 0.04,
	"crt_mask_mode": 1,
	"crt_mask_strength": 0.55,
	"crt_mask_pitch_mm": 2.0,
	"crt_scanline_strength": 0.6,
	"crt_beam_min": 0.18,
	"crt_beam_max": 0.35,
	"crt_gamma": 1.09,
	"crt_halation": 0.08,
	"crt_glow_radius": 6.0,
	"crt_notch": 0.0,
	"crt_persistence": 0.3,
	"crt_grain": 0.1,
	"crt_smear": 0.0,
	"crt_wiggle": 0.0,
	"crt_vignette": 0.18,
	"crt_brightness": 1.0,
}

# Phosphor persistence ping-pong (Shaders/phosphor_decay.gdshader). A viewport
# can't sample itself, so one renders while the other is read as "last frame".
@onready var _phosphor_a: SubViewport = $PhosphorA
@onready var _phosphor_b: SubViewport = $PhosphorB
var _phosphor_write_a: bool = true
# The raw picture texture we wrapped, kept because _crt_material's source_tex is
# replaced by the accumulator once persistence is running.
var _crt_source_tex: Texture2D = null
# Signature of the inputs to _apply_derived_crt_params, so the per-frame refresh
# only touches the material when one of them actually moved.
var _crt_derived_key: String = ""

# Tube face size in metres, read off the mesh in _ready. The phosphor pitch is a
# physical property of the glass, so the triad count is derived from this times
# scale_factor rather than being a fixed number of triads per UV.
var _screen_size_m := Vector2(0.35, 0.25)

# TV-owned screen states: blue "no signal" (ON with no live input) and the
# original dark bezel material (OFF).
var _blue_material: StandardMaterial3D = null
var _dark_material: Material = null

# CRT power-on animation (thin horizontal line expanding to full height).
var _poweron_tween: Tween = null

# Bumped each time an OSD message is shown or hidden so a stale auto-hide timer
# from a previous message can't clear a newer one.
var _osd_token: int = 0
# Same, for the independent volume-bars OSD at the bottom of the screen.
var _vol_osd_token: int = 0

# The captive lead seated in each input's video socket, so a disconnect knows
# which host to tell. One entry per composite input, indexed by it.
var _snapped_plugs: Array = []

# What is feeding each composite input, indexed by it. A host is any node
# implementing the TV contract (on_tv_connected/on_tv_disconnected/
# set_audio_volume/set_screen_enabled) — a RetroSystem or a VCRPlayer — so the
# entries are typed loosely.
#
# Four of them because the set has four sockets and a player can leave a console on
# one while watching another: everything that used to be "the connected system" is
# now "the system on the input SOURCE has selected" (_selected_system) or "every
# system, told whether it is the one showing" (_apply_screen_enable).
var _connected_systems: Array = []
var _volume: float = 1.0       # 0.0–1.0, default 100%
var _tv_enabled: bool = true

# Selected input and the built-in tuner behind Source.TV. The tuner is created on
# first use rather than in _ready: most sets in a scene never leave the composite
# inputs, and an idle one should cost nothing (no VlcPlayer, no discovery traffic).
var current_source: int = Source.COMPOSITE_1
var _tuner: TVTuner = null

## Which channel the set is tuned to while Source.RF is showing — 3 or 4, stepped by
## the CH keys. A console fed through an RF switch only appears when this matches the
## channel its own switch is set to; anything else is static, as it would be.
var rf_channel: int = RF_CHANNELS[0]
# Snow for an untuned aerial channel; see _rf_static.
var _rf_static_material: ShaderMaterial = null

# Mute: silences the connected device's audio without changing _volume. A sticky
# "MUTE" OSD stays up until mute is toggled off or a volume key is pressed.
var _muted: bool = false

# Uniform display scale of the whole TV (1.0 = default set size). Adjusted from
# the TV options panel and persisted per-scene. Applied to the RigidBody root so
# the screen, bezel, buttons and cable port all scale together.
const MIN_SCALE := 0.2
const MAX_SCALE := 5.0
var scale_factor: float = 1.0

# Frame counter for ambilight sampling
var _ambilight_frame: int = 0
# The light's authored energy, so we can restore it after blanking (TV off).
var _ambilight_energy: float = 0.6

# The "no signal" blue — shared by the screen texture and the ambilight tint.
const BLUE_SCREEN_COLOR := Color(0.0, 0.05, 0.65)


func _ready() -> void:
	super._ready()
	# Before _load_shell, which re-seats every one of them.
	_collect_av_ports()
	# Before anything reads the screen mesh or the buttons — _screen_size_m below
	# is derived from ScreenMesh, and a shell may have moved and rescaled it.
	_load_shell()
	# After the shell, so each legend is printed round wherever its group ended up,
	# and so a cabinet that carries fewer than four has already said so.
	_disable_absent_inputs()
	_print_av_legends()
	# The set defaults to Composite 1 and a cabinet need not have it, so land on one
	# it does before anything reads current_source. _seat_vga_port has already run
	# inside _load_shell, which is what decides whether Composite 1 counts here.
	if not _source_available(current_source):
		current_source = _first_available_source()
	# TV = power: it runs the power-on animation and flashes POWER on the OSD.
	TransportGlyphs.label_buttons(self, {
		"MuteButton": "mute", "AudioModeButton": "audio_stereo",
		"VolumeDownButton": "vol_down", "VolumeUpButton": "vol_up",
		"TVToggleButton": "power", "CRTButton": "crt", "StereoButton": "stereo",
		"SourceButton": "source",
		"ChannelDownButton": "ch_down", "ChannelUpButton": "ch_up",
	}, TransportGlyphs.TV_SIZE)
	for i in COMPOSITE_INPUTS:
		var video := _video_port(i)
		if video == null:
			continue
		video.has_picked_up.connect(_on_plug_snapped.bind(i))
		video.has_dropped.connect(_on_plug_released.bind(i))
	# The VGA socket announces the same way, and answers for Composite 1: it is an
	# alternative to that socket rather than a fifth input, and only the computer
	# monitor carries one at all. Connected whether or not this shell uses it — a
	# disabled zone never fires, so there is nothing to gate.
	_vga_port.has_picked_up.connect(_on_plug_snapped.bind(Source.COMPOSITE_1))
	_vga_port.has_dropped.connect(_on_plug_released.bind(Source.COMPOSITE_1))
	_mute_btn.button_pressed.connect(_on_mute_toggle)
	_audio_mode_btn.button_pressed.connect(_on_audio_mode_toggle)
	_vol_down_btn.button_pressed.connect(_on_volume_down)
	_vol_up_btn.button_pressed.connect(_on_volume_up)
	_tv_toggle_btn.button_pressed.connect(_on_tv_toggle)
	_crt_btn.button_pressed.connect(_on_crt_toggle)
	_stereo_btn.button_pressed.connect(_on_stereo_toggle)
	_aspect_btn.button_pressed.connect(toggle_aspect)
	_source_btn.button_pressed.connect(cycle_source)
	_ch_down_btn.button_pressed.connect(_on_channel_down)
	_ch_up_btn.button_pressed.connect(_on_channel_up)
	_vol_down_btn.set_color(Color(0.1, 0.3, 0.9))   # blue
	_vol_up_btn.set_color(Color(0.0, 0.9, 0.9))     # cyan
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0))  # green = on
	_update_mute_button_color()
	_update_audio_mode_button()
	# Hidden until a stereo source is connected (see _update_stereo_button).
	# VRButton._ready adds the pointable layer — strip it while hidden so the
	# invisible button can't eat pokes or laser clicks (deferred: our _ready
	# runs before the child button's).
	_stereo_btn.set_process(false)
	_stereo_btn.set_deferred("collision_layer", 0)
	_update_crt_button_color()
	_update_stereo_button_color()
	# The aspect cap prints its own state and tv.tscn authors it blank, so without
	# this the picture-shape key on the bezel is an unlabelled button until the
	# first press.
	_update_aspect_button()

	# Keep the chosen display size across pickups: xr-tools' grab driver is a
	# RemoteTransform3D that copies scale (forcing us back to 1x while held), so
	# disable its scale copy on grab and reassert our scale on drop.
	grabbed.connect(_on_tv_grabbed)
	dropped.connect(_on_tv_dropped)
	_apply_scale()
	_float_lock = FloatLock.attach(self, ignore_gravity)

	if _ambilight:
		_ambilight_energy = _ambilight.light_energy
		# Random phase so multiple TVs don't all sample (GPU readback) on the
		# same frame.
		_ambilight_frame = randi() % 16

	# The tscn's dark bezel material is the OFF look; blue is the ON-with-no-
	# signal look. Blue carries a tiny texture so the CRT watcher can wrap it
	# (curvature/scanlines apply to the blue screen too) and ambilight samples it.
	_dark_material = _screen_mesh.get_surface_override_material(0)
	if _screen_mesh.mesh != null:
		var aabb := _screen_mesh.mesh.get_aabb()
		# get_aabb() is the MESH's own extent and ignores the node scale, which a
		# shell uses to size its tube (ScreenSeat carries the scale). Without this
		# a 90s cabinet reports the stock 0.35 x 0.25 screen and every consumer of
		# _screen_size_m — aspect fitting, OSD sizing — is wrong by that factor.
		var screen_scale := _screen_mesh.scale
		if aabb.size.x > 0.0 and aabb.size.y > 0.0:
			_screen_size_m = Vector2(aabb.size.x * screen_scale.x, aabb.size.y * screen_scale.y)

	# Now the fitted tube's size is known. A shell that moved it without saying
	# where its speakers went gets them computed; everything else keeps the
	# markers exactly as authored.
	if _shell != null and not _speakers_seated:
		_place_default_speakers()

	var blue_img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	blue_img.fill(BLUE_SCREEN_COLOR)
	_blue_material = StandardMaterial3D.new()
	_blue_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_blue_material.albedo_texture = ImageTexture.create_from_image(blue_img)


## Wear a cabinet variant. Strict no-op when tv_model is empty — that is the
## acceptance test for this whole mechanism, since the arcade and den TVs must
## look and behave exactly as they did before.
##
## Only nodes the shell actually names a seat for are moved; everything else keeps
## its tv.tscn pose, so a shell describes differences rather than the whole layout.
func _load_shell() -> void:
	if tv_model.is_empty():
		return
	var path: String = _SHELL_SCENES.get(tv_model, "")
	if path.is_empty():
		push_warning("RetroTV: unknown tv_model '%s' — falling back to the stock body" % tv_model)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("RetroTV: failed to load shell scene: %s" % path)
		return
	_shell = packed.instantiate() as RetroTVShell
	if _shell == null:
		push_warning("RetroTV: shell scene root is not a RetroTVShell: %s" % path)
		return
	add_child(_shell)
	$TVBody.hide()

	_seat_node(_screen_mesh, _shell.screen_seat())
	_seat_av_row(_shell.port_seat())
	_seat_vga_port(_shell.vga_port_seat())
	_seat_node(_ambilight, _shell.ambilight_seat())

	# Both or neither: one seated speaker and one still on the stock tube's edge
	# would be a lopsided stereo image nobody authored. _ready falls back to the
	# computed pair when this stays false.
	var spk_l: Variant = _shell.speaker_l_seat()
	var spk_r: Variant = _shell.speaker_r_seat()
	_speakers_seated = spk_l is Transform3D and spk_r is Transform3D
	if _speakers_seated:
		_seat_node(_speaker_l, spk_l)
		_seat_node(_speaker_r, spk_r)

	# Bezel buttons march along the row marker's local +X from the first cap, and
	# wrap onto a second row below it. Same order the stock cabinet authors, so a
	# shelled set and the plain box read alike.
	var row: Variant = _shell.button_row_seat()
	var buttons: Array[Node3D] = _bezel_buttons()
	if not _shell.show_button_row:
		for btn in buttons:
			(btn as VRButton).set_active(false)
	elif row is Transform3D:
		var base: Transform3D = row
		var per_row: int = maxi(1, _shell.buttons_per_row)
		for i in buttons.size():
			var b: Node3D = buttons[i]
			# Keep each cap's authored basis (they are rotated to face outward);
			# only the origin walks the row.
			@warning_ignore("integer_division")
			b.transform = Transform3D(b.transform.basis, base * Vector3(
				float(i % per_row) * _shell.button_pitch,
				float(i / per_row) * -_shell.button_row_drop,
				0.0))

	_resize_body_collision(_shell.body_size)


## The bezel caps in the order they are laid out, reading left to right and then
## down. The everyday controls of the set fill the first row; the picture and
## sound MODES — the ones you set once and leave — go on the second.
##
## 3D comes LAST on purpose. It is the one cap that comes and goes (only a
## stereo source has anything for it to switch), and a hidden button still owns
## its slot — anywhere else in the order it leaves a hole in the middle of the
## row that reads as a missing control. At the end it simply is not there.
##
## Mute and the speaker switch used to sit outside this list, so a shell moved
## nine caps onto its marker and left those two wherever the stock cabinet had
## put them. One list now, and both paths read it.
func _bezel_buttons() -> Array[Node3D]:
	return [
		_tv_toggle_btn, _source_btn, _ch_down_btn, _ch_up_btn,
		_vol_down_btn, _vol_up_btn, _mute_btn,
		_audio_mode_btn, _crt_btn, _aspect_btn, _stereo_btn,
	]


func _seat_node(node: Node3D, seat: Variant) -> void:
	if node != null and seat is Transform3D:
		node.transform = seat


## Centre-to-centre along the A/V row. The pitch the primitive console, the NES, the
## PC tower and both decks already use, so a lead reaches a set's sockets exactly as
## it reaches a deck's.
const AV_ROW_PITCH := 0.018

## Centre-to-centre between one input group and the next. Wider than AV_ROW_PITCH by
## more than the printed legend is wide (57.6 mm at the authored text sizes), so the
## four plates stand clear of each other instead of overlapping — and wide enough
## that no socket sits closer to its neighbour in the next group than to the ones in
## its own, which is what makes the grouping readable at arm's length.
const AV_GROUP_PITCH := 0.06


## The A/V sockets, gathered from the scene's fixed names into [input][VIDEO, L, R].
##
## Composite 1 keeps the unsuffixed names it has always had — a console's captive
## lead, netplay and the save file all name "CompositePort" — and the rest count up
## from 2, so the numbering on the wire matches the numbering printed on the panel.
func _collect_av_ports() -> void:
	_av_ports = []
	_connected_systems = []
	_snapped_plugs = []
	for i in COMPOSITE_INPUTS:
		var suffix := "" if i == 0 else str(i + 1)
		var trio: Array[RcaPort] = []
		for base in ["CompositePort", "AudioLIn", "AudioRIn"]:
			var port := get_node_or_null(base + suffix) as RcaPort
			if port == null:
				push_warning("[RetroTV] missing A/V socket %s%s" % [base, suffix])
				continue
			trio.append(port)
		_av_ports.append(trio)
		_connected_systems.append(null)
		_snapped_plugs.append(null)
	# Two more slots so all three arrays stay indexable by Source over their WHOLE
	# range and not just the composite part of it — _input_for_device returns a
	# Source and everything downstream indexes with it.
	#
	# TV owns no sockets, so its entry is an empty trio; _video_port already guards
	# for that, and its connected-system slot stays null because a tuner is not a
	# connected system. RF owns exactly one, and it is a VIDEO socket, so it sits at
	# index 0 of its trio where _video_port looks.
	_av_ports.append([] as Array[RcaPort])
	_connected_systems.append(null)
	_snapped_plugs.append(null)
	var rf := _rf_port as RcaPort
	var rf_trio: Array[RcaPort] = []
	if rf != null:
		rf_trio.append(rf)
	else:
		push_warning("[RetroTV] missing aerial socket RfPort")
	_av_ports.append(rf_trio)
	_connected_systems.append(null)
	_snapped_plugs.append(null)


## How many composite inputs this cabinet actually carries sockets for. The stock
## body and both televisions take all four; a shell with a smaller back panel says so.
func _panel_inputs() -> int:
	if _shell == null:
		return COMPOSITE_INPUTS
	# Floored at ZERO, not at one: a cabinet is allowed to carry no phono sockets at
	# all, and the computer monitor is one. See TVShell.av_inputs.
	return clampi(_shell.av_inputs, 0, COMPOSITE_INPUTS)


## Whether this cabinet carries the aerial socket. The stock body does; a fitted
## shell says so itself.
func _has_aerial() -> bool:
	return _shell == null or _shell.has_aerial


## Turn off the inputs this cabinet has no room for: no socket, and nothing printed.
##
## `enabled` as well as `visible`, for the reason _seat_vga_port gives — hiding a
## snap zone stops it drawing and nothing else, so an invisible socket left enabled
## goes on catching plugs out of the air.
func _disable_absent_inputs() -> void:
	for i in range(_panel_inputs(), COMPOSITE_INPUTS):
		for port: RcaPort in _av_ports[i]:
			port.visible = false
			port.enabled = false
	if not _has_aerial():
		for port: RcaPort in _av_ports[Source.RF]:
			port.visible = false
			port.enabled = false


## The VIDEO socket of one input — the one that decides what is on the glass, and
## the one a captive lead goes into.
func _video_port(input: int) -> RcaPort:
	if input < 0 or input >= _av_ports.size() or (_av_ports[input] as Array).is_empty():
		return null
	return _av_ports[input][0]


## Print the back-panel legends: one per composite input group, plus the aerial
## socket's own.
##
## A set is a sink, so every A/V one reads AV IN; what tells them apart is the title
## above the jacks. The plate is the cabinet's call — a moulded CRT back is curved,
## and a flat rectangle across it either floats off the curve or cuts in.
func _print_av_legends() -> void:
	var plate: bool = _shell == null or _shell.av_legend_plate
	for i in _panel_inputs():
		var legend := AvLegend.attach(self, _av_ports[i])
		if legend == null:
			continue
		legend.name = "AvLegend%d" % (i + 1)
		legend.title = AV_INPUT_NAMES[i]
		legend.show_plate = plate
		# Every group but the first rules off the one to its left, so four inputs get
		# three lines and neither end of the bank carries a stray one.
		legend.divider_left = i > 0
		legend.rebuild()
	if _has_aerial():
		_print_rf_legend(plate)


## The aerial socket's legend — the same printing as a composite group so the one
## hole on the panel that is not phono is not also the one standing on bare cabinet.
##
## Wordless: CoaxPort reports Channel.VIDEO because the routing needs somewhere to
## send the picture, and printing VIDEO under an aerial hole would name the wrong
## connector. The row that word would have occupied still takes its space, so this
## plate comes out the same height as the four beside it.
##
## No divider, and that is the point of the gap it stands in: an aerial feed is not
## one of the composite inputs, and a rule would file it as a fifth.
func _print_rf_legend(plate: bool) -> void:
	var legend := AvLegend.attach(self, _av_ports[Source.RF])
	if legend == null:
		return
	legend.name = "AvLegendRf"
	legend.title = "Antenna"
	legend.heading_override = "RF IN"
	legend.show_words = false
	legend.show_plate = plate
	legend.rebuild()


## Seat all TWELVE input sockets off the shell's PortSeat, not just the video one.
##
## PortSeat names one point — Composite 1's VIDEO socket — and everything else steps
## off it: the audio pair by av_socket_step, the next input group by av_group_step,
## both in the seat's own frame. A shell that named only the video socket used to
## leave the rest at tv.tscn's own coordinates while the body they were mounted in
## was hidden, which put live sockets in mid-air beside the cabinet.
##
## The two steps are the SHELL's because the room to lay them out is the cabinet's:
## the stock box and the 90s set measure flat across the whole 240 mm row, while the
## computer monitor runs out at 180 and stands its groups on end instead.
func _seat_av_row(seat: Variant) -> void:
	if not seat is Transform3D:
		return
	var base: Transform3D = seat
	var socket_step := Vector3(-AV_ROW_PITCH, 0.0, 0.0)
	var group_step := Vector3(-AV_GROUP_PITCH, 0.0, 0.0)
	if _shell != null:
		socket_step = _shell.av_socket_step
		group_step = _shell.av_group_step
	for i in COMPOSITE_INPUTS:
		for j in (_av_ports[i] as Array).size():
			var offset: Vector3 = group_step * float(i) + socket_step * float(j)
			_seat_node(_av_ports[i][j], Transform3D(base.basis, base * offset))
	# The aerial socket takes the next group slot along, so it travels with the row
	# onto a fitted cabinet instead of being left at tv.tscn's own coordinates —
	# which, with the stock body hidden, is a live socket floating beside the set.
	# One group clear of Composite 4 whether or not this cabinet fits four, since a
	# shell with fewer still has the room the others use.
	#
	# Plus ONE socket step, which lands it on that slot's CENTRE rather than on the
	# slot's first socket. A composite group centres its printing on the middle of
	# its trio, so a lone socket sitting where a trio's VIDEO jack goes puts its plate
	# 18 mm right of where the pattern wants it — close enough to overlap Composite
	# 4's and z-fight with it, the two being coplanar and the same colour.
	if _rf_port != null:
		_seat_node(_rf_port, Transform3D(base.basis,
			base * (group_step * float(COMPOSITE_INPUTS) + socket_step)))


## Turn the VGA input on, but only for a shell that asked for it.
##
## Opt-IN rather than opt-out: the socket is authored off in tv.tscn and a shell
## claims it by carrying a VgaPortSeat marker. Only the computer monitor does — a
## DE-15 on a wood-cabinet 70s set would be an anachronism, and the stock body has
## nowhere sensible to put one.
##
## `enabled` as well as `visible`, and that is not belt and braces: hiding a snap
## zone stops it drawing and nothing else, so an invisible socket left enabled goes
## on catching plugs.
func _seat_vga_port(seat: Variant) -> void:
	if _vga_port == null:
		return
	var on: bool = seat is Transform3D
	if on:
		_vga_port.transform = seat
	_vga_port.visible = on
	_vga_port.enabled = on


## Resize the pickup collider and the pointer box to the cabinet.
##
## BoxShape3D_body and BoxShape3D_pointer are plain sub_resources in tv.tscn, i.e.
## SHARED between every TV in the scene — writing a size straight onto them would
## resize the den's TV too. Duplicate first. (Same trap the resource_local_to_scene
## note on Mat_phosphor_a already documents for the phosphor materials.)
func _resize_body_collision(size: Vector3) -> void:
	var body_col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if body_col and body_col.shape is BoxShape3D:
		var s := (body_col.shape as BoxShape3D).duplicate() as BoxShape3D
		s.size = size
		body_col.shape = s
	var ptr_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if ptr_col and ptr_col.shape is BoxShape3D:
		var p := (ptr_col.shape as BoxShape3D).duplicate() as BoxShape3D
		# The stock pointer box is 20 mm proud of the body on each axis.
		p.size = size + Vector3(0.02, 0.02, 0.02)
		ptr_col.shape = p


func _process(_delta: float) -> void:
	_update_screen_source()
	_update_crt()
	_refresh_crt_derived()
	_update_phosphor()
	_update_stereo_button()
	_route_osd()
	_release_park_if_unsupported()

	# The tuner's sound comes out of this cabinet's own speakers, aimed the way
	# the tube points — a set heard from behind is muted by its own box.
	if _tuner != null and _tuner.is_active():
		_tuner.emit_through(self)

	# Grab-driver churn (second-hand grab, hand swap, desktop re-hold) recreates
	# the RemoteTransform3D with scale copying re-enabled, which stomps the TV
	# back to 1x — e.g. rotating a held TV with the other hand. Keep our chosen
	# size authoritative for the whole hold.
	if is_picked_up():
		_lock_grab_scale()
		if not scale.is_equal_approx(Vector3.ONE * scale_factor):
			scale = Vector3.ONE * scale_factor

	if not _ambilight or not _ambilight.visible:
		return

	# Static screen states never touch the texture: get_image() is a GPU→CPU
	# readback that stalls the whole pipeline on Quest, and an idle TV (off /
	# blue "no signal") has nothing new to sample anyway.
	var override := _screen_mesh.get_surface_override_material(0)
	var effective := _crt_wrapped \
		if (override == _crt_material or override == _stereo_material) else override
	if not _tv_enabled or effective == _dark_material or effective == null:
		_ambilight.light_energy = 0.0
		return
	_ambilight.light_energy = _ambilight_energy
	if effective == _blue_material:
		_ambilight.light_color = BLUE_SCREEN_COLOR
		return

	_ambilight_frame += 1
	var interval: int = QualityManager.ambilight_interval if QualityManager else 10
	if _ambilight_frame < interval:
		return
	_ambilight_frame = 0

	# Live source (emulator / tape / disc): sample the average screen color from
	# the current texture (works for system emission materials, VCR materials
	# and the CRT wrapper alike).
	var tex := _current_source_texture()
	if not tex:
		return
	var img := tex.get_image()
	if not img:
		return

	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var avg := img.get_pixel(0, 0)
	_ambilight.light_color = Color(avg.r, avg.g, avg.b)


# ── Screen source (blue / dark states) ─────────────────────────────────────────

## Own the "no signal" presentation like a retro TV: ON with no live input →
## blue screen; OFF → the original dark bezel material. Live sources (the C++
## video handler, the VCR) install their own materials over ours and this
## backs off automatically; when they blank/restore a textureless material we
## take over again next frame.
func _update_screen_source() -> void:
	# On the TV input the tuner owns the glass outright: it always has something
	# to show (a picture, or static carrying the reason there isn't one), so the
	# blue screen below must not get a look in. Nothing else is driving the mesh
	# either -- the connected host was muted with set_screen_enabled(false) when
	# the input changed.
	if _tv_enabled and current_source == Source.TV and _tuner != null:
		var wanted := _tuner.screen_material()
		var current := _screen_mesh.get_surface_override_material(0)
		var showing_ours := current == wanted
		if current == _crt_material and _crt_wrapped == wanted:
			showing_ours = true
		if not showing_ours:
			_unwrap_crt()
			_screen_mesh.set_surface_override_material(0, wanted)
		return

	# The aerial input paints its own no-signal. A set tuned to a channel nothing is
	# broadcasting on shows SNOW, not a blue screen — and here "nothing" is the
	# ordinary state of whichever of the two channels the switch is not using, so the
	# blue no-signal screen would read as a fault every time you stepped past it.
	# When the channel does match, the host owns the glass and this falls through.
	if _tv_enabled and current_source == Source.RF and not _rf_tuned():
		var snow := _rf_static()
		if _screen_mesh.get_surface_override_material(0) != snow:
			_unwrap_crt()
			_screen_mesh.set_surface_override_material(0, snow)
		return

	var override := _screen_mesh.get_surface_override_material(0)
	var effective := _crt_wrapped \
		if (override == _crt_material or override == _stereo_material) else override

	if _tv_enabled:
		var has_picture := false
		if effective != null and effective != _blue_material and effective != _dark_material:
			# VHS shader = live VCR; standard materials are live once they
			# carry a picture texture.
			has_picture = effective is ShaderMaterial or _extract_texture(effective) != null
		if not has_picture and effective != _blue_material:
			_unwrap_crt()
			_screen_mesh.set_surface_override_material(0, _blue_material)
	else:
		# Off. The blank states are ours to paint over; a live source's material is
		# not, and is left until its host hands the glass back.
		#
		# The tuner's material is ours too, and neither of its two looks reads as
		# blank: set_active(false) leaves the last decoded frame frozen on the
		# picture material, and the static shader carries on animating whether or
		# not anything is driving it. Nothing else is on the mesh by then — the
		# tuner is inactive and the connected host was muted when the input
		# changed — so on the TV input the screen goes dark whatever is left on it.
		# Our own snow is reclaimable for the same reason the tuner's is: the static
		# shader animates whether or not anything drives it, so an untuned aerial
		# input left on it would go on hissing with the set switched off.
		var reclaimable := effective == _blue_material or effective == null \
			or (current_source == Source.TV and _tuner != null) \
			or effective == _rf_static_material
		if reclaimable and effective != _dark_material:
			_unwrap_crt()
			_screen_mesh.set_surface_override_material(0, _dark_material)


## Retro CRT turn-on: the picture starts as a thin horizontal line and expands
## to full height. Scaling the screen mesh squashes everything (picture, OSD).
func _play_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
	_screen_mesh.scale = Vector3(1.0, 0.02, 1.0)
	# Snap to the thin line instantly — don't let physics interpolation smooth
	# the collapse (the expansion itself is tweened below).
	_screen_mesh.reset_physics_interpolation()
	_poweron_tween = create_tween()
	_poweron_tween.tween_interval(0.07)
	_poweron_tween.tween_property(_screen_mesh, "scale", Vector3.ONE, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _stop_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
		_poweron_tween = null
	_screen_mesh.scale = Vector3.ONE


# ── CRT filter ─────────────────────────────────────────────────────────────────

## Keep the CRT filter applied to whatever is currently on the screen. The
## sources own the screen material (the C++ video handler re-asserts its own
## material whenever the core's texture changes; the VCR swaps materials on
## play/stop/effect-toggle), so instead of fighting them we watch the override
## each frame and re-wrap when it changes — identity checks only, so the steady
## state costs nothing.
func _update_crt() -> void:
	var override := _screen_mesh.get_surface_override_material(0)
	if override == null:
		_crt_wrapped = null
		return

	# VHS / a system's screen-window shader on the screen: chain the CRT stage
	# inside it via its crt_enabled uniform rather than replacing the material.
	# Window shaders additionally take this TV's stereo presentation mode.
	if override is ShaderMaterial and override != _crt_material \
			and override != _stereo_material:
		var sm := override as ShaderMaterial
		if sm.shader == VCR_SHADER or sm.shader == WINDOW_SHADER \
				or sm.shader == STATIC_SHADER:
			# Note: an unset uniform reads back as null, never bool — compare
			# against the Variant directly.
			var cur: Variant = sm.get_shader_parameter("crt_enabled")
			if (cur == true) != crt_enabled:
				sm.set_shader_parameter("crt_enabled", crt_enabled)
				if crt_enabled:
					_apply_crt_params(sm)   # sync tube tuning onto the source shader
			if sm.shader == WINDOW_SHADER:
				var cur_mode: Variant = sm.get_shader_parameter("stereo_mode")
				if cur_mode != stereo_mode:
					sm.set_shader_parameter("stereo_mode", stereo_mode)
		_crt_wrapped = null
		return

	# Our stereo wrapper is installed (full-frame SBS source): it stays on
	# regardless of the CRT toggle — only its uniforms follow the buttons.
	if override == _stereo_material:
		var cur_crt: Variant = _stereo_material.get_shader_parameter("crt_enabled")
		if (cur_crt == true) != crt_enabled:
			_stereo_material.set_shader_parameter("crt_enabled", crt_enabled)
			if crt_enabled:
				_apply_crt_params(_stereo_material)
		var cur_mode: Variant = _stereo_material.get_shader_parameter("stereo_mode")
		if cur_mode != stereo_mode:
			_stereo_material.set_shader_parameter("stereo_mode", stereo_mode)
		return

	# The wrapper also carries the aspect fit, and the raw source material has no
	# fit of its own — so a picture that needs shrinking keeps the wrapper on with
	# the tube stage merely switched off. Without this, turning CRT off would
	# quietly stretch a letterboxed picture back over the whole glass.
	if not crt_enabled and not _source_is_sbs() and not _aspect_needs_fit():
		if override == _crt_material and _crt_wrapped != null:
			_screen_mesh.set_surface_override_material(0, _crt_wrapped)
		_crt_wrapped = null
		return

	if override == _crt_material:
		return

	# A new source material appeared — wrap it if it carries a picture.
	var tex := _extract_texture(override)
	if tex == null:
		return
	if _source_is_sbs():
		# Full-frame side-by-side source (Virtual Boy): wrap with the windowing
		# shader — left-eye window + eye_shift 0.5 gives the per-eye split (or
		# LEFT/RIGHT via the 3D button) with the CRT stage chained inside, so
		# stereo no longer depends on the CRT toggle.
		if _stereo_material == null:
			_stereo_material = ShaderMaterial.new()
			_stereo_material.shader = WINDOW_SHADER
			_stereo_material.set_shader_parameter("source_rect", Vector4(0.0, 0.0, 0.5, 1.0))
			_stereo_material.set_shader_parameter("eye_shift", 0.5)
		_stereo_material.set_shader_parameter("source_tex", tex)
		_stereo_material.set_shader_parameter("stereo_mode", stereo_mode)
		_stereo_material.set_shader_parameter("crt_enabled", crt_enabled)
		if crt_enabled:
			_apply_crt_params(_stereo_material)
		_crt_wrapped = override
		_screen_mesh.set_surface_override_material(0, _stereo_material)
		return
	if _crt_material == null:
		_crt_material = ShaderMaterial.new()
		_crt_material.shader = CRT_SHADER
	# source_tex before the params: _apply_derived_crt_params reads the source's
	# resolution back off the material to get the scanline count.
	_crt_material.set_shader_parameter("source_tex", tex)
	_crt_source_tex = tex
	_apply_crt_params(_crt_material)
	# The wrapper is new or its source changed; the fit does not survive that.
	_apply_aspect()
	_crt_wrapped = override
	_screen_mesh.set_surface_override_material(0, _crt_material)


## Phosphor persistence: run the live frame through the decay accumulator and feed
## the CRT stage the result instead of the raw texture.
##
## Rides the crt_effect wrapper only. The chained VCR and dual-screen window
## shaders keep sampling their source directly — three more ping-pong pairs isn't
## worth it for a tape deck that has its own artefacts and for a handheld panel
## that isn't a tube in the first place.
func _update_phosphor() -> void:
	if _crt_material == null or _crt_source_tex == null:
		return
	if _screen_mesh.get_surface_override_material(0) != _crt_material:
		return

	var amount: float = float(_crt_params.get("crt_persistence", 0.0))
	if not crt_enabled or amount <= 0.001:
		# Hand the raw picture back so turning persistence off is a true bypass.
		if _crt_material.get_shader_parameter("source_tex") != _crt_source_tex:
			_crt_material.set_shader_parameter("source_tex", _crt_source_tex)
		return

	var sz := Vector2i(_crt_source_tex.get_size())
	if sz.x < 2 or sz.y < 2:
		return

	var write: SubViewport = _phosphor_a if _phosphor_write_a else _phosphor_b
	var read: SubViewport = _phosphor_b if _phosphor_write_a else _phosphor_a
	if write.size != sz:
		write.size = sz
		read.size = sz

	var rect := write.get_child(0) as ColorRect
	var pm := rect.material as ShaderMaterial
	pm.set_shader_parameter("src", _crt_source_tex)
	pm.set_shader_parameter("prev", read.get_texture())
	# Red decays slowest, blue fastest, so the afterglow goes warm as it fades.
	pm.set_shader_parameter("decay", Vector3(amount, amount * 0.85, amount * 0.7))
	# UPDATE_ONCE re-armed every frame, never UPDATE_ALWAYS — an ALWAYS render
	# target hangs headless runs.
	write.render_target_update_mode = SubViewport.UPDATE_ONCE

	_crt_material.set_shader_parameter("source_tex", write.get_texture())
	_phosphor_write_a = not _phosphor_write_a


## True when the source ON SCREEN outputs a side-by-side stereo frame (Virtual Boy).
## The one showing, not merely one connected: a VB left plugged into an input nobody
## has selected must not put the other input's picture through a per-eye split.
func _source_is_sbs() -> bool:
	var system := _selected_system()
	return system != null \
		and system.has_method("is_stereo_output") \
		and system.is_stereo_output()


## True while what's showing is a stereo source: a full-frame SBS system (VB)
## or a dual-screen system's window channel with a per-eye shift (3DS top).
## True while something 3D is playing — what both the bezel's 3D key and the
## remote's hide themselves on.
func has_stereo_source() -> bool:
	return _stereo_source_active()


func _stereo_source_active() -> bool:
	if _source_is_sbs():
		return true
	var override := _screen_mesh.get_surface_override_material(0)
	if override is ShaderMaterial and override != _stereo_material \
			and (override as ShaderMaterial).shader == WINDOW_SHADER:
		var es: Variant = (override as ShaderMaterial).get_shader_parameter("eye_shift")
		return es != null and float(es) != 0.0
	return false


## Show the 3D button only while a stereo source is connected. Hidden buttons
## also stop processing and drop off the pointable layer so an invisible
## button can't eat pokes or laser clicks.
func _update_stereo_button() -> void:
	if _stereo_btn == null:
		return
	var active := _stereo_source_active()
	if _stereo_btn.visible != active:
		_stereo_btn.set_active(active)


## Push every tunable CRT uniform onto a material carrying the CRT display stage
## (our wrapper or the chained VCR shader).
func _apply_crt_params(mat: ShaderMaterial) -> void:
	for key: String in _crt_params:
		mat.set_shader_parameter(key, _crt_params[key])
	_apply_derived_crt_params(mat)


## The two uniforms that aren't slider values. Both describe the tube and the
## signal on it rather than a preference, so they're derived rather than authored
## — and both have to be right for the mask and raster to stay glued to the glass
## as you move, which is the whole point of the rewritten filter.
func _apply_derived_crt_params(mat: ShaderMaterial) -> void:
	# Phosphor pitch is a property of the glass, so the triad count follows the
	# screen's WORLD width: scaling the TV up adds triads instead of stretching
	# them, exactly as a physically bigger tube would.
	var pitch_m: float = maxf(float(_crt_params.get("crt_mask_pitch_mm", 2.0)), 0.05) * 0.001
	var triads: float = (_screen_size_m.x * scale_factor) / pitch_m
	mat.set_shader_parameter("crt_mask_triads", triads)
	# Slot/shadow phosphor cells run about 1.5x taller than they are wide.
	mat.set_shader_parameter("crt_mask_rows",
		triads * (_screen_size_m.y / _screen_size_m.x) / 1.5)

	# Active lines in the signal, taken from the source itself. A fixed count is
	# the point: the raster belongs to the signal, so walking backwards must not
	# change how many scanlines are on the tube.
	var lines := 240.0
	var tex: Texture2D = _extract_texture(mat)
	if tex != null:
		var h: float = tex.get_size().y
		# A window shader shows one sub-rect of a composite framebuffer, so a DS
		# panel has half the lines the texture does.
		var rect: Variant = mat.get_shader_parameter("source_rect")
		if rect is Vector4:
			h *= maxf((rect as Vector4).w, 0.01)
		if h >= 16.0:
			lines = h
	mat.set_shader_parameter("crt_scanline_count", lines)


## The installed material carrying the CRT display stage, if any.
func _active_crt_material() -> ShaderMaterial:
	var override := _screen_mesh.get_surface_override_material(0)
	if override == _crt_material or override == _stereo_material:
		return override as ShaderMaterial
	if override is ShaderMaterial:
		var sh := (override as ShaderMaterial).shader
		if sh == VCR_SHADER or sh == WINDOW_SHADER:
			return override as ShaderMaterial
	return null


## Recompute the derived uniforms when what they depend on moves — the TV's
## display scale, the mask pitch, or the source's resolution. Cheap signature
## check so the steady state costs nothing.
func _refresh_crt_derived() -> void:
	var mat := _active_crt_material()
	if mat == null:
		return
	var tex := _extract_texture(mat)
	var key := "%s|%.4f|%.4f|%s" % [
		mat.get_instance_id(), scale_factor,
		float(_crt_params.get("crt_mask_pitch_mm", 2.0)),
		"null" if tex == null else str(tex.get_size()),
	]
	if key == _crt_derived_key:
		return
	_crt_derived_key = key
	_apply_derived_crt_params(mat)


## Set one CRT display-stage uniform live (from the TV options panel) and apply
## it to whichever material currently shows the CRT stage.
func set_crt_param(pname: String, value: Variant) -> void:
	if not _crt_params.has(pname):
		return
	_crt_params[pname] = value
	if _crt_material != null:
		_crt_material.set_shader_parameter(pname, value)
	var override := _screen_mesh.get_surface_override_material(0)
	if override is ShaderMaterial:
		var sh := (override as ShaderMaterial).shader
		if sh == VCR_SHADER or sh == WINDOW_SHADER:
			(override as ShaderMaterial).set_shader_parameter(pname, value)
	# crt_mask_pitch_mm isn't a uniform — it feeds the derived triad count.
	_crt_derived_key = ""


## Current CRT tuning values, for the options panel to populate its controls.
func get_crt_params() -> Dictionary:
	return _crt_params.duplicate()


## Seed the CRT tuning from a save. Merges only keys we already know, so a save
## written by a build with a different set of uniforms can't inject stray shader
## parameters, and coerces through the current value's type — JSON gives every
## number back as a float, but crt_mask_mode is an int uniform.
func set_crt_params(values: Dictionary) -> void:
	for key: String in values:
		if not _crt_params.has(key):
			continue
		if typeof(_crt_params[key]) == TYPE_INT:
			_crt_params[key] = int(values[key])
		else:
			_crt_params[key] = float(values[key])
	_crt_derived_key = ""
	# Seeded before _ready (scene restore instantiates then sets): the values are
	# in place and get pushed when the filter first wraps a source.
	if _screen_mesh == null:
		return
	if _crt_material != null:
		_apply_crt_params(_crt_material)
	var mat := _active_crt_material()
	if mat != null:
		_apply_crt_params(mat)


## Pull the picture texture out of a screen material, whichever shape it has:
## the C++ video handler uses emission, the VCR uses albedo or a video_tex
## uniform, and our own CRT wrapper uses source_tex.
func _extract_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		if std.emission_texture != null:
			return std.emission_texture
		return std.albedo_texture
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var tex: Variant = sm.get_shader_parameter("video_tex")
		if tex == null:
			tex = sm.get_shader_parameter("source_tex")
		return tex as Texture2D
	return null


## The texture currently being shown, regardless of which material owns it.
func _current_source_texture() -> Texture2D:
	var mat := _screen_mesh.get_surface_override_material(0)
	if mat == null:
		return null
	return _extract_texture(mat)


## Restore the wrapped source material. Called before hosts (re)take the
## screen so the C++ video handler captures/restores a clean original instead
## of our wrapper.
func _unwrap_crt() -> void:
	var override := _screen_mesh.get_surface_override_material(0)
	if _crt_wrapped != null and (override == _crt_material or override == _stereo_material):
		_screen_mesh.set_surface_override_material(0, _crt_wrapped)
	_crt_wrapped = null
	_crt_source_tex = null
	_crt_derived_key = ""


func set_crt_enabled(on: bool) -> void:
	crt_enabled = on
	_update_crt_button_color()
	NetworkManager.report_event(NetObjectSync.EV_TV_CRT, {"tv": self, "on": on})


func _on_crt_toggle() -> void:
	set_crt_enabled(not crt_enabled)


func _update_crt_button_color() -> void:
	if _crt_btn:
		_crt_btn.set_color(Color(1.0, 0.6, 0.1) if crt_enabled else Color(0.35, 0.35, 0.35))


## Cycle the stereo presentation: STEREO → LEFT → RIGHT → … (3D bezel button).
## _update_crt pushes the mode onto whichever shader is showing the source.
func set_stereo_mode(mode: int) -> void:
	stereo_mode = clampi(mode, 0, 2)
	_update_stereo_button_color()
	show_osd_timed(STEREO_MODE_NAMES[stereo_mode], 2.0)
	NetworkManager.report_event(NetObjectSync.EV_TV_STEREO,
		{"tv": self, "mode": stereo_mode})


func _on_stereo_toggle() -> void:
	set_stereo_mode((stereo_mode + 1) % 3)


# ── Picture shape (4:3 / 16:9) ────────────────────────────────────────────────

## The bezel button and the remote's, and what a save restores through.
func toggle_aspect() -> void:
	set_widescreen(not widescreen)


func set_widescreen(on: bool) -> void:
	widescreen = on
	_apply_aspect()
	_update_aspect_button()
	show_osd_timed("16:9" if widescreen else "4:3", 1.5)


## How much of the glass the picture should cover, as a fraction per axis.
##
## The tube is whatever shape the shell gave it — not necessarily 4:3 — so the
## fit is computed against the real glass rather than assumed. Whichever axis is
## too generous gets shrunk about the centre and the rest becomes bar.
func _aspect_fit() -> Vector2:
	if _screen_size_m.x <= 0.0 or _screen_size_m.y <= 0.0:
		return Vector2.ONE
	var glass := _screen_size_m.x / _screen_size_m.y
	var want := ASPECT_16_9 if widescreen else ASPECT_4_3
	if is_equal_approx(glass, want):
		return Vector2.ONE
	if want > glass:
		return Vector2(1.0, glass / want)   # wider than the glass -> bars above/below
	return Vector2(want / glass, 1.0)       # taller -> bars either side


## Push the fit onto whichever material is currently showing the picture. Called
## on every material change as well as on the button, because the display path
## swaps materials underneath us (raw source, CRT wrapper, window shader).
func _apply_aspect() -> void:
	var fit := _aspect_fit()
	for mat in [_crt_material, _stereo_material]:
		if mat != null:
			(mat as ShaderMaterial).set_shader_parameter("fit_scale", fit)
	var override := _screen_mesh.get_surface_override_material(0) as ShaderMaterial
	if override != null and override.shader == CRT_SHADER:
		override.set_shader_parameter("fit_scale", fit)


## True when the picture needs shrinking to fit. The raw source material has no
## fit of its own, so this is what decides the CRT wrapper has to go on even
## with the tube effect switched off — otherwise turning CRT off would silently
## stretch the picture back out again.
func _aspect_needs_fit() -> bool:
	return not _aspect_fit().is_equal_approx(Vector2.ONE)


func _update_aspect_button() -> void:
	if _aspect_btn == null:
		return
	var lbl := _aspect_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.text = "16:9" if widescreen else "4:3"


func _update_stereo_button_color() -> void:
	if _stereo_btn:
		# Magenta = per-eye stereo; dimmer purple flavors for single-eye modes.
		match stereo_mode:
			0: _stereo_btn.set_color(Color(1.0, 0.2, 1.0))
			1: _stereo_btn.set_color(Color(0.55, 0.35, 0.75))
			2: _stereo_btn.set_color(Color(0.35, 0.35, 0.75))
	_update_stereo_button_glyph()


## Cycle the speaker switch: stereo -> the left channel from both speakers -> the
## right from both. Called by the front-panel key and by the remote.
func set_audio_mode(mode: int) -> void:
	audio_mode = clampi(mode, 0, 2)
	_apply_audio_channel_mode()
	_update_audio_mode_button()
	show_osd_timed(AUDIO_MODE_NAMES[audio_mode], 2.0)
	NetworkManager.report_event(NetObjectSync.EV_TV_AUDIO_MODE,
		{"tv": self, "mode": audio_mode})


func _on_audio_mode_toggle() -> void:
	set_audio_mode((audio_mode + 1) % 3)


## The routing itself belongs to whoever owns the samples, so it is handed to the
## connected deck rather than done here — the set has no emitter of its own.
func _apply_audio_channel_mode() -> void:
	# Every connected host, not just the one showing: the speaker switch is a
	# property of the SET, so an input switched to later has to already be routed
	# the way the switch says rather than reverting to stereo for one press.
	for system in _connected_systems:
		if system != null and is_instance_valid(system) \
				and system.has_method("set_audio_channel_mode"):
			system.set_audio_channel_mode(audio_mode)
	# The tuner is the one source the set does own an emitter for, so it takes the
	# same routing directly rather than being asked to do it.
	if _tuner:
		_tuner.set_channel_mode(audio_mode)


## Stereo gets the two-speaker symbol; a mono mode gets a single speaker leaning
## to the channel it is carrying, matching how the 3D key shows its eye.
func _update_audio_mode_button() -> void:
	match audio_mode:
		0:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_stereo",
				TransportGlyphs.TV_SIZE)
		1:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, -1.0)
		2:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, 1.0)
	if _audio_mode_btn:
		_audio_mode_btn.set_color(Color(0.35, 0.55, 0.9) if audio_mode == 0
			else Color(0.9, 0.65, 0.25))


## Both eyes gets the 3D symbol; a single eye gets an eye leaning to the side it
## is showing, so the cap says which one without a word on it.
func _update_stereo_button_glyph() -> void:
	match stereo_mode:
		0: TransportGlyphs.set_glyph(self, "StereoButton", "stereo", TransportGlyphs.TV_SIZE)
		1: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, -1.0)
		2: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, 1.0)


## Returns the screen MeshInstance3D so Libretro can render onto it
func get_screen_mesh() -> MeshInstance3D:
	return _screen_mesh


## World positions of the set's left and right speakers, in that order.
##
## Read straight off the SpeakerL / SpeakerR markers, so where a set radiates
## from is authored in the scene and can be dragged in the editor like any other
## node. Being children of the root they ride scale_factor and any parent's
## transform for free.
##
## Left and right are the LISTENER's. The set faces +Z (the screen sits proud of
## the front face, the composite port is on the back at -Z), so someone watching
## it has its +X on their right, and SpeakerR is the one at +X.
##
## Emitting from the cabinet centre instead makes the sound appear to come from
## inside the box -- inaudible with amplitude panning, obvious with HRTF.
func get_speaker_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	if _speaker_l != null and _speaker_r != null:
		out.push_back(_speaker_l.global_position)
		out.push_back(_speaker_r.global_position)
		return out
	# No markers (a scene predating them): the defaults, computed in place.
	var frame := global_transform.basis
	var face: Vector3 = _screen_mesh.global_position + frame.z * 0.005
	var right: Vector3 = frame.x * (_screen_size_m.x * 0.5 + 0.055)
	var down: Vector3 = -frame.y * (_screen_size_m.y * 0.35)
	out.push_back(face - right + down)
	out.push_back(face + right + down)
	return out


## Put the speaker markers where a set of this size wears them: flanking the tube
## 5.5 cm outboard of its edges, a little below its centre, and just proud of the
## glass -- which is where a CRT of this vintage puts them.
##
## Only for a shell that names no speaker seats. tv.tscn's own markers are already
## these numbers for the stock 0.35 x 0.25 tube, so this exists for a cabinet that
## moves and rescales the screen without saying where its speakers went; leaving
## the stock markers there would strand them on the old tube's edges.
##
## Local metres throughout, since the markers are children of the root: no basis
## juggling, and the scale that ScreenSeat gave the tube is already inside
## _screen_size_m.
func _place_default_speakers() -> void:
	if _speaker_l == null or _speaker_r == null:
		return
	var half_w: float = _screen_size_m.x * 0.5 + 0.055
	var drop_m: float = _screen_size_m.y * 0.35
	var face: Vector3 = _screen_mesh.position + Vector3(0.0, 0.0, 0.005)
	_speaker_l.position = face + Vector3(-half_w, -drop_m, 0.0)
	_speaker_r.position = face + Vector3(half_w, -drop_m, 0.0)


## Which way the picture faces. Sound leaves a set the same way it does, so
## anything giving these speakers a directivity aims them along this. Normalised,
## unlike the offsets above, because it is a direction rather than a distance.
func get_screen_normal() -> Vector3:
	return global_transform.basis.z.normalized()


## The set's own up, to go with get_screen_normal when a pose is wanted.
func get_screen_up() -> Vector3:
	return global_transform.basis.y.normalized()


# ── On-screen display (top-right corner) ────────────────────────────────────────
# The text lives in two places: a 2D Label rendered into OSDViewport (composited
# INSIDE the CRT/VHS shaders so the OSD curves and scanlines with the picture)
# and the legacy OSDLabel Label3D used as a fallback when no shader owns the
# screen. _route_osd() picks the right one every frame.

## Show a persistent OSD message (stays until replaced or hidden).
func show_osd(text: String) -> void:
	_osd_token += 1
	_set_osd_text(text)


## Show an OSD message that auto-hides after `seconds` (unless superseded).
func show_osd_timed(text: String, seconds: float) -> void:
	_osd_token += 1
	var tok := _osd_token
	_set_osd_text(text)
	get_tree().create_timer(seconds).timeout.connect(func():
		if tok == _osd_token:
			hide_osd()
	)


## Clear the OSD.
func hide_osd() -> void:
	_osd_token += 1
	_set_osd_text("")


# Long OSD messages (e.g. "AUDIO: English (Dolby Digital 5.1)" from the DVD/VHS
# track cycling) would otherwise overflow past the edge of the screen at the
# base font size. Short messages ("PLAY", "MUTE", "POWER"...) stay full-size;
# anything past OSD_FIT_CHARS scales down (never below the min) to fit.
const OSD_FIT_CHARS := 10
const OSD_BASE_FONT_SIZE_3D := 64
const OSD_MIN_FONT_SIZE_3D := 24
const OSD_BASE_FONT_SIZE_2D := 44
const OSD_MIN_FONT_SIZE_2D := 18


func _fit_osd_font_size(text: String, base_size: int, min_size: int) -> int:
	var length := text.length()
	if length <= OSD_FIT_CHARS:
		return base_size
	return maxi(min_size, int(base_size * OSD_FIT_CHARS / float(length)))


func _set_osd_text(text: String) -> void:
	_osd_label.text = text
	_osd_label.font_size = _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_3D, OSD_MIN_FONT_SIZE_3D)
	_osd_text_2d.text = text
	_osd_text_2d.add_theme_font_size_override(
			"font_size", _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_2D, OSD_MIN_FONT_SIZE_2D))
	_refresh_osd_texture(text)


## Volume-bars OSD (bottom of screen, like an old set): VOL |||||||---
## Independent of the corner OSD; auto-hides after 2 s.
func show_volume_osd() -> void:
	_vol_osd_token += 1
	var tok := _vol_osd_token
	var filled := roundi(_volume * VOL_OSD_SEGMENTS)
	var text := "VOL " + "|".repeat(filled) + "-".repeat(VOL_OSD_SEGMENTS - filled)
	_set_vol_osd_text(text)
	get_tree().create_timer(2.0).timeout.connect(func():
		if tok == _vol_osd_token:
			_vol_osd_token += 1
			_set_vol_osd_text("")
	)


# One segment per volume step, so the bar has exactly the granularity the keys do.
const VOL_OSD_SEGMENTS := 10
# The margin the bar keeps at each end, as a fraction of the picture width. The
# CRT stage samples the OSD through crt_warp, which pulls the outer few percent
# of the texture off past the curved glass.
const VOL_OSD_SIDE_MARGIN := 0.055
# A ceiling only. The bar is a fixed cell count, so on a normal 4:3 picture the
# solved size lands well under this; the clamp is there so a freak narrow
# viewport can't ask for a 300 px font.
const VOL_OSD_MAX_FONT_SIZE := 128


## Solve the font size that makes `text` span `avail` units wide, measuring the
## real font rather than assuming a cell width (the mono family resolves
## differently per platform — Consolas on Windows, Droid Sans Mono on Quest).
## `unit` is the world size of one font pixel (1.0 for a 2D label). Returns 0
## when there is nothing to measure, meaning "leave the size as it is".
func _fit_font_size_to_width(font: Font, text: String, avail: float, unit: float) -> int:
	if font == null or text.is_empty() or avail <= 0.0 or unit <= 0.0:
		return 0
	const PROBE := 64
	var probe_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, PROBE).x
	if probe_w <= 0.0:
		return 0
	return clampi(int(PROBE * (avail / unit) / probe_w), 8, VOL_OSD_MAX_FONT_SIZE)


# The bar is as wide as the picture, the way a real set draws it. Both copies
# size themselves from the space they actually have — the viewport's width for
# the composited one, the screen quad's own extent for the Label3D fallback —
# so a shell with a different tube gets a bar that still spans it.
func _set_vol_osd_text(text: String) -> void:
	_vol_osd_label.text = text
	var size_3d := _fit_font_size_to_width(_vol_osd_label.font,
			text, _vol_osd_label_width(), _vol_osd_label.pixel_size)
	if size_3d > 0:
		_vol_osd_label.font_size = size_3d
	_vol_osd_text_2d.text = text
	var size_2d := _fit_font_size_to_width(_vol_osd_text_2d.get_theme_font("font"),
			text, _vol_osd_text_2d_width(), 1.0)
	if size_2d > 0:
		_vol_osd_text_2d.add_theme_font_size_override("font_size", size_2d)
	_refresh_osd_texture(text)


## The composited copy fills its own rect, which the tscn insets from the
## viewport edge. Before the first layout pass that rect is still empty, so fall
## back to the inset the constant describes.
func _vol_osd_text_2d_width() -> float:
	var w := _vol_osd_text_2d.size.x
	if w > 0.0:
		return w
	return _osd_viewport.size.x * (1.0 - 2.0 * VOL_OSD_SIDE_MARGIN)


## The Label3D runs rightward from its own origin, so its room is whatever lies
## between that origin and the far margin of the screen quad it hangs on.
func _vol_osd_label_width() -> float:
	if _screen_mesh.mesh == null:
		return 0.0
	var quad_w := _screen_mesh.mesh.get_aabb().size.x
	return quad_w * (0.5 - VOL_OSD_SIDE_MARGIN) - _vol_osd_label.position.x


func _refresh_osd_texture(text: String) -> void:
	# One-shot re-render of the OSD texture (skipped headless — no GPU).
	if text != "" and DisplayServer.get_name() != "headless":
		_osd_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_route_osd()


## Route the OSD to the screen shader when one is active (our CRT wrapper or
## the VCR's VHS material), else to the fallback Label3Ds. Both the corner OSD
## and the volume bars share the same OSD viewport texture.
func _route_osd() -> void:
	var main_active := _osd_label.text != ""
	var vol_active := _vol_osd_label.text != ""
	var mat := _screen_mesh.get_surface_override_material(0)
	var sm: ShaderMaterial = null
	if mat is ShaderMaterial:
		var candidate := mat as ShaderMaterial
		if candidate == _crt_material or candidate.shader == VCR_SHADER \
				or candidate.shader == WINDOW_SHADER \
				or candidate.shader == STATIC_SHADER:
			sm = candidate
	if sm != null:
		sm.set_shader_parameter("osd_tex", _osd_viewport.get_texture())
		sm.set_shader_parameter("osd_enabled", main_active or vol_active)
		_osd_label.visible = false
		_vol_osd_label.visible = false
	else:
		_osd_label.visible = main_active
		_vol_osd_label.visible = vol_active


## Snaps a captive cable plug into one of this TV's video sockets (used by save/load
## and netplay to restore connections). Defaults to Composite 1, which is where a
## caller that has no opinion — and every save written before there were four — means.
func accept_plug_restore(plug: CablePlug, input: int = Source.COMPOSITE_1) -> void:
	var port := _video_port(input)
	if port == null:
		port = _composite_port as RcaPort
	print("[RetroTV] accept_plug_restore: plug=%s port=%s" % [plug, port])
	port.pick_up_object(plug)
	print("[RetroTV] accept_plug_restore: done, port.picked_up=%s" % port.picked_up_object)


## Drop whatever captive lead is in one input's video socket. Used by netplay when
## another player unplugs one; the input defaults to Composite 1 for an event from a
## peer that predates there being four.
func release_input(input: int = Source.COMPOSITE_1) -> void:
	var port := _video_port(input)
	if port != null:
		port.drop_object()


## Which video socket is holding `plug`, or null. Lets a host that seated a captive
## lead find its way back to the right socket without knowing the numbering.
func port_holding(plug: Node3D) -> XRToolsSnapZone:
	for i in COMPOSITE_INPUTS:
		var port := _video_port(i)
		if port != null and port.picked_up_object == plug:
			return port
	if _vga_port != null and _vga_port.picked_up_object == plug:
		return _vga_port
	return null


## Which INPUT is holding `plug`, for a host writing itself to a save file. Falls
## back to Composite 1 for anything it cannot find, which is where a restore with no
## opinion puts a lead anyway — including the VGA socket, that input's alternative.
func input_holding(plug: Node3D) -> int:
	for i in COMPOSITE_INPUTS:
		var port := _video_port(i)
		if port != null and port.picked_up_object == plug:
			return i
	return Source.COMPOSITE_1


## Called when a cable plug snaps into one of the video sockets. `input` is bound
## per socket at connect time, so the handler knows which one without asking.
func _on_plug_snapped(plug: Node3D, input: int) -> void:
	# Hand the incoming host a clean screen so the C++ video handler doesn't
	# capture our CRT wrapper as the "original" material to restore later.
	_unwrap_crt()
	cable_connected.emit(plug)
	if plug is CablePlug:
		var plugged := plug as CablePlug
		_snapped_plugs[input] = plugged
		# Prevent the frozen kinematic plug from physically pushing the TV
		add_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			_connected_systems[input] = system
			# Multi-output systems need to know WHICH cable landed; other
			# hosts (VCR/DVD) keep the plain single-arg contract.
			if system is RetroSystem:
				(system as RetroSystem).on_tv_connected(self, plugged)
			elif system.has_method("on_tv_connected"):
				# Guarded: only a host with a captive lead implements this. The decks
				# dropped it when they moved to sockets and a spawned cable, and an
				# unguarded call errors on any plug that names one as its system.
				system.on_tv_connected(self)
			# A console plugged in while the set is showing something else must stay
			# off the glass until SOURCE selects it, or it repaints the screen from
			# under whatever is playing.
			if current_source != input and system.has_method("set_screen_enabled"):
				system.set_screen_enabled(false)
			# …and it must be silent too until SOURCE picks it, for the same reason.
			_apply_audio_volume()
			NetworkManager.report_event(NetObjectSync.EV_TV_PLUG,
				{"owner": system, "tv": self, "ch": plugged.channel, "in": input})


## Called by a deck that has worked out it is feeding this set through a composite
## lead. Takes the place of _on_plug_snapped's host lookup, which only works for a
## captive lead whose plug carries a back-reference to its owner; a composite
## cable's plugs belong to no device, so the deck tells the set instead.
func on_av_source_found(source: Node3D) -> void:
	var input := _input_for_device(source)
	if input < 0:
		return                  # nothing of ours is actually joined to it
	# Hand the incoming host a clean screen, exactly as the plug path does, so the
	# video handler doesn't capture our CRT wrapper as the material to restore.
	_unwrap_crt()
	_connected_systems[input] = source
	source.set_audio_volume(_volume_for(input))
	_apply_audio_channel_mode()
	# Same rule as the captive-lead path: a deck cabled up to an input nobody is
	# watching waits its turn rather than painting over the one they are.
	if current_source != input and source.has_method("set_screen_enabled"):
		source.set_screen_enabled(false)


## Called by that deck when the last cord between the two is pulled.
func on_av_source_lost(source: Node3D) -> void:
	var found := false
	for i in _connected_systems.size():
		if _connected_systems[i] == source:
			_connected_systems[i] = null
			found = true
	if not found:
		return                  # already replaced by something else
	_unwrap_crt()


## Which input a device's signal is arriving on, or -1 if none of ours reaches it.
##
## Worked out from the cable rather than passed in, because the caller does not know
## it: a deck announces itself through on_av_source_found having resolved only that
## this television is its sink, and CompositeCable._resolve tells the SOURCE end
## first — so the set is told before its own on_av_topology_changed runs, and reading
## the answer off a stored link list would be both a frame late and one ordering
## assumption deep.
##
## VIDEO wins over audio when a device reaches more than one input, because the
## picture is what the input is named for. But audio alone still counts: a deck with
## its sound in Composite 2 and its video cord out is on Composite 2, and used to be
## heard there — which is the whole reason the L/R sockets are separate.
func _input_for_device(dev: Node3D) -> int:
	if dev == null or not is_instance_valid(dev):
		return -1
	var audio_match := -1
	# Over every input the set has sockets for, which now includes the aerial one:
	# a console reached through an RF switch is found here exactly as one on a
	# composite lead is, because the switch answers links() like any other cable.
	for i in _av_ports.size():
		# A captive lead names its own host and carries no CompositeCable at all.
		var captive: CablePlug = _snapped_plugs[i]
		if captive != null and is_instance_valid(captive) and captive.get_system() == dev:
			return i
		for port: RcaPort in _av_ports[i]:
			var plug := port.seated_plug() as RcaPlug
			if plug == null or plug.cable == null or not is_instance_valid(plug.cable):
				continue
			for link: Dictionary in plug.cable.links():
				if link["in"] != port:
					continue
				if (link["out"] as RcaPort).get_device() != dev:
					continue
				if port.channel == RcaPort.Channel.VIDEO:
					return i
				if audio_match < 0:
					audio_match = i
	return audio_match


## Nothing to do here: a set is a sink, and every routing decision is the source's.
## It exists so RcaPort.get_device() recognises a television as a device at all —
## that is the whole of the interface.
func on_av_topology_changed(_links: Array) -> void:
	pass


## Called when a cable plug leaves one of the video sockets.
func _on_plug_released(input: int) -> void:
	# Unwrap before the host tears down so it restores over its own material,
	# not our CRT wrapper.
	_unwrap_crt()
	cable_disconnected.emit()
	var plugged: CablePlug = _snapped_plugs[input]
	if plugged:
		remove_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			if system is RetroSystem:
				(system as RetroSystem).on_tv_disconnected(plugged)
			elif system.has_method("on_tv_disconnected"):
				system.on_tv_disconnected()
		_connected_systems[input] = null
		_snapped_plugs[input] = null
		NetworkManager.report_event(NetObjectSync.EV_TV_UNPLUG, {"tv": self, "in": input})


# Remote-control entry points (TVRemote): identical to pressing the bezel
# buttons, so the volume label / power button color stay in sync.

func remote_power_toggle() -> void:
	_on_tv_toggle()


func remote_volume_up() -> void:
	_on_volume_up()


func remote_volume_down() -> void:
	_on_volume_down()


func remote_mute_toggle() -> void:
	_on_mute_toggle()


func remote_source_cycle() -> void:
	cycle_source()


func remote_channel_up() -> void:
	if _tuner and current_source == Source.TV:
		_tuner.channel_up()


func remote_channel_down() -> void:
	if _tuner and current_source == Source.TV:
		_tuner.channel_down()


# Bezel channel keys. Unlike the remote's — which only appear once the tuner is
# the selected input, because the SOURCE key is right beside them — these are
# moulded into the cabinet and are always there. A physical CH key that does
# nothing on the wrong input would just read as broken, so pressing one selects
# the tuner first, exactly as a real set does.

func _on_channel_up() -> void:
	_select_tv_then(true)


func _on_channel_down() -> void:
	_select_tv_then(false)


func _select_tv_then(up: bool) -> void:
	if not _tv_enabled:
		return
	# On the aerial input the CH keys do what they would on a real set fed by an RF
	# switch: step between the two channels the switch can occupy, rather than
	# abandoning the input the viewer just chose to go and find the tuner.
	if current_source == Source.RF:
		var i := RF_CHANNELS.find(rf_channel)
		var n := RF_CHANNELS.size()
		rf_channel = RF_CHANNELS[((i if i >= 0 else 0) + (1 if up else n - 1)) % n]
		_apply_screen_enable()
		_apply_audio_volume()
		show_osd_timed(_source_banner(), 2.0)
		return
	if current_source != Source.TV:
		set_source(Source.TV)
		# set_source already tuned whatever channel was last on, so the press that
		# switched inputs is not also a channel step -- pressing CH+ from the
		# component input lands you on the tuner, not one past it.
		return
	if up:
		_ensure_tuner().channel_up()
	else:
		_ensure_tuner().channel_down()


# ── Input selection (SOURCE) ──────────────────────────────────────────────────

## Step to the next input, wrapping. The SOURCE key on the bezel and the remote.
##
## Composite inputs this cabinet has no sockets for are stepped straight past: the
## cycle is a tour of what you can actually plug something into, and stopping on an
## input with no socket would read as the key being broken.
func cycle_source() -> void:
	var next := current_source
	# Step until something this cabinet actually has turns up. Bounded by the number
	# of inputs, so a set that somehow had none cannot spin here.
	for i in SOURCE_NAMES.size():
		next = (next + 1) % SOURCE_NAMES.size()
		if _source_available(next):
			break
	set_source(next)


## Whether this cabinet can show a given input at all.
##
## A composite input needs a socket on the back panel; the aerial input needs the
## coax hole. The tuner needs neither and is always there, which is what makes it
## the safe fallback in set_source.
func _source_available(source: int) -> bool:
	if source < COMPOSITE_INPUTS:
		if source < _panel_inputs():
			return true
		# Composite 1 is ALSO where the VGA socket reports (see the bind in _ready),
		# so a cabinet carrying a DE-15 can show that input with no phono row behind
		# it at all. The computer monitor is exactly that, and gating this on the
		# phono count alone would have taken the tower's picture away with the
		# sockets it does not use.
		return source == Source.COMPOSITE_1 			and _vga_port != null and _vga_port.enabled
	if source == Source.RF:
		return _has_aerial()
	return true


## The first input this cabinet has, for a set asked to show one it does not.
func _first_available_source() -> int:
	for i in SOURCE_NAMES.size():
		if _source_available(i):
			return i
	return Source.TV


## Select an input. Idempotent, so panels can call it freely.
func set_source(source: int) -> void:
	source = clampi(source, 0, SOURCE_NAMES.size() - 1)
	# A cabinet without the socket cannot show that input. Fall back to the first it
	# DOES have rather than to Composite 1 — that used to be safe because every
	# cabinet carried at least one phono input, and the computer monitor carries
	# none, so the old fallback sent it to an input that is not there.
	if not _source_available(source):
		source = _first_available_source()
	if source == current_source:
		return
	current_source = source

	# Mute every source that is not selected. set_screen_enabled is the contract
	# every host already implements (RetroSystem, VCRPlayer, DVDPlayer) and the
	# set already uses it for power -- without it a console keeps writing its
	# own material onto the screen every frame and the two fight.
	_apply_screen_enable()
	# Sound follows the same selection as the picture. Both halves, or the input
	# you just left goes on being heard.
	_apply_audio_volume()

	if current_source == Source.TV:
		_ensure_tuner()
		_tuner.set_active(_tv_enabled)
	else:
		if _tuner:
			_tuner.set_active(false)
		# Hand the screen back: whichever host now owns it repaints, and until one
		# does _update_screen_source restores the blue no-signal state.
		#
		# Unconditional, and that matters between two composite inputs as much as it
		# does leaving the tuner: the input just left has its material still
		# installed and still carrying its last frame, so the no-signal check would
		# go on seeing a picture that nothing is driving any more, and switching to
		# an empty socket would show the previous input frozen instead of blue.
		_unwrap_crt()
		_screen_mesh.set_surface_override_material(0, _blue_material)

	show_osd_timed(_source_banner(), 2.0)
	source_changed.emit(current_source)


func _source_banner() -> String:
	if current_source == Source.TV and _tuner:
		var banner := _tuner.status_banner()
		if not banner.is_empty():
			return "TV  %s" % banner
	if current_source == Source.RF:
		# The channel is half the state on this input, so it belongs in the banner —
		# and NO SIGNAL is the difference between "nothing is plugged in" and "you
		# are on the wrong one of two channels", which the static alone cannot say.
		return "RF  CH %d%s" % [rf_channel, "" if _rf_tuned() else "  NO SIGNAL"]
	return SOURCE_NAMES[current_source]


## The tuner is built on first use — a set that never leaves COMPONENT should not
## pay for a VlcPlayer instance or send discovery traffic.
func _ensure_tuner() -> TVTuner:
	if _tuner == null:
		_tuner = TVTuner.new()
		_tuner.name = "TVTuner"
		_tuner.status_changed.connect(_on_tuner_status)
		add_child(_tuner)
		_tuner.reload_channels()
		_tuner.set_volume(_volume_for(Source.TV))
		_tuner.set_channel_mode(audio_mode)
	return _tuner


func _on_tuner_status(banner: String) -> void:
	if current_source != Source.TV:
		return
	if banner.is_empty():
		hide_osd()
	elif _tuner and not _tuner.error_text().is_empty():
		# A fault stays up: it is the only explanation for what is on the glass.
		show_osd(banner)
	else:
		show_osd_timed(banner, 3.0)


## The tuner, built if this is the first ask. Used by the options panel.
func get_tuner() -> TVTuner:
	return _ensure_tuner()


## Whether the tuner exists AND has a channel list — without building one.
## Callers that merely want to know (the remote, greying its channel keys) must
## use this: get_tuner() would spin up a VlcPlayer and start discovery just
## because somebody pointed a remote at the set.
func has_channels() -> bool:
	return _tuner != null and not _tuner.channels.is_empty()


func get_source() -> int:
	return current_source


# ── Options panel / display scale ────────────────────────────────────────────────

## Toggle the floating TV settings panel. Called by SpawnMenuController when the
## menu button is pressed while pointing at this TV (mirrors PDFBook/VCRPlayer).
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


## Current display scale (1.0 = default). Read by the TV options panel.
func get_scale_factor() -> float:
	return scale_factor


## Set the TV's uniform display scale, clamped to [MIN_SCALE, MAX_SCALE].
func set_tv_scale(factor: float) -> void:
	scale_factor = clampf(factor, MIN_SCALE, MAX_SCALE)
	_apply_scale()


func _apply_scale() -> void:
	# A set grows in place: same spot on the floor, same footprint centre, the
	# extra size going straight up. Two things have to be true for that to hold.
	#
	# One, the bottom is pinned rather than the origin. Scaling about the centre
	# drives the base into whatever the set is standing on, and the solver answers
	# a penetration by ejecting the body downward — the TV sinks through the
	# surface. Holding the lowest point fixed keeps the contact intact.
	#
	# Two, nothing may push it sideways. Nothing here does, and the freeze below
	# stops the solver doing it: enlarging a set against a wall, or over the edge of
	# the table it stands on, leaves an overlap the solver evicts, which walks the
	# set across the room. Resizing something that is standing somewhere is a
	# placement, not a collision, so the body is parked and the overlap is simply
	# allowed. A big set can clip the wall behind it; that beats it walking away.
	#
	# Parked means frozen, not asleep. Sleeping looks like it works and does not
	# last: anything that disturbs the body's island wakes it — a footstep away,
	# an object landing nearby — and it is evicted then instead, so the set sits
	# still through the whole drag and lurches half a metre once you let go.
	#
	# The offset is an unscaled local constant rather than a world measurement taken
	# after the write: a child's global_transform is still stale in the frame its
	# parent's scale changes, so re-measuring reads back pre-scale values and the
	# correction cancels to nothing.
	#
	# previous is tracked here, not read back off scale.y, because the authored or
	# restored position already sits where the anchoring puts it. Correcting a
	# scale the node has never actually worn would lift a persisted 2.1x set again
	# on every load.
	var previous := _anchored_scale
	_anchored_scale = scale_factor
	# Measured before the scale write, which is what leaves the children stale —
	# and unconditionally, so the very first call, from _ready, is the one that
	# fills the cache while every transform is still coherent.
	var bottom := _local_bottom_y()
	# bottom_world = origin_y + s * local_bottom, so holding it fixed means
	# shifting the origin by (old_s - new_s) * local_bottom.
	var delta := previous - scale_factor
	# Whatever is standing on the set, found while the cabinet is still its old
	# size — see _carry_riders for why they cannot be left to the solver. Skipped
	# when the size is not actually moving: _on_tv_dropped reasserts the current
	# scale on every release, and that must not cost a shape query.
	var resizing := not is_nan(previous) and not is_zero_approx(delta)
	var riders: Array[RigidBody3D] = []
	if resizing:
		riders = _riders(previous)
	scale = Vector3.ONE * scale_factor
	if not resizing:
		return
	global_position.y += delta * bottom
	# The bottom is pinned, so the top moved by exactly the change in height.
	_carry_riders(riders, _collider_height() * (scale_factor - previous))
	# Held: the grab driver owns the pose, so there is nothing to park.
	if freeze and not _parked_by_resize:
		return
	# Only a set that is BOTH standing on something and jammed into something needs
	# parking. On open floor the enlarged cabinet touches nothing, there is no
	# penetration to evict, and the body is left as ordinary physics — which is the
	# common case, and the one where a stuck freeze would be most obvious.
	#
	# The park is released again the moment it is not needed, so shrinking a set
	# back down hands it straight to physics. Parking on the way up and never
	# undoing it leaves a set frozen at 1.0x with nothing holding it there.
	#
	# force_update_transform either way: the write above only queues a transform
	# notification, and the flush at the end of the frame is what hands the pose to
	# the physics server. Freezing before that flush parks the body at its old pose,
	# and unfreezing before it resumes gravity from a stale one.
	if _is_standing_on_something() and _is_jammed():
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		force_update_transform()
		freeze = true
		_parked_by_resize = true
	elif _parked_by_resize:
		force_update_transform()
		freeze = false
		_parked_by_resize = false


## How thick a slab above the cabinet's top face counts as "standing on it".
const _RIDER_SLAB := 0.03


## Height of the pickup collider at scale 1.
func _collider_height() -> float:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return 0.0
	return (col.shape as BoxShape3D).size.y


## The bodies standing on top of the set, measured with the cabinet at `at_scale`.
##
## A thin slab just above the top face: a box resting on the cabinet is caught and
## the cabinet itself is not. Dynamic bodies only — world geometry cannot ride
## anything, and a frozen body is either held, parked, or seated in one of our own
## sockets, none of which wants to be shoved.
func _riders(at_scale: float) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D) or get_world_3d() == null \
			or is_nan(at_scale):
		return out
	var full: Vector3 = (col.shape as BoxShape3D).size * at_scale
	var slab := BoxShape3D.new()
	# Shy of the footprint on the horizontal axes so a set standing against a wall
	# does not count the wall, which is static anyway but also not free.
	slab.size = Vector3(maxf(full.x - 0.01, 0.01), _RIDER_SLAB, maxf(full.z - 0.01, 0.01))
	var axes := global_basis.orthonormalized()
	var centre: Vector3 = global_position + axes * (col.position * at_scale) \
		+ Vector3.UP * (full.y * 0.5 + _RIDER_SLAB * 0.5)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = slab
	query.transform = Transform3D(axes, centre)
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 16):
		var rb := hit.get("collider") as RigidBody3D
		if rb == null or rb == self or rb.freeze or is_ancestor_of(rb):
			continue
		if not out.has(rb):
			out.append(rb)
	return out


## Move what was standing on the set by however far the top face just moved.
##
## Resizing is a PLACEMENT, and this is the half of that the solver cannot do for
## you. Growing the cabinet in one step — a committed slider value, a size restored
## from a save, a peer's resize — swallows whatever was on top, and Jolt answers a
## body that is suddenly deep inside another by ejecting it through the nearest
## face: it drops out of the bottom of the set and lands on the floor. Dragging the
## slider hid this, because a 0.1 step only grows the box a couple of centimetres
## and the solver pushes the object back UP each tick.
##
## Only lifted on the way up. Shrinking needs no move — the set slides out from
## under whatever was on it and gravity does the rest — but it does need the WAKE
## below, because a body that fell asleep resting on the cabinet is not disturbed
## by the cabinet leaving, and it hangs in the air where the set used to be.
func _carry_riders(riders: Array[RigidBody3D], lift: float) -> void:
	for rb in riders:
		if not is_instance_valid(rb):
			continue
		if lift > 0.0:
			rb.global_position.y += lift
			# Teleports and physics interpolation: without this the object renders
			# sliding up from where it was rather than arriving with the cabinet.
			rb.reset_physics_interpolation()
		rb.sleeping = false


## Scale the anchor correction was last applied at. NAN until the first
## _apply_scale, whose job is only to put the authored/restored scale on the node.
var _anchored_scale: float = NAN

## Whether the freeze on this body is ours, from a resize, rather than the one
## XRToolsPickable puts on while the set is held.
var _parked_by_resize: bool = false

## How close the base has to be to a surface to count as standing on it, and how
## far the cabinet has to be inside something else to count as jammed.
const _STANDING_GAP := 0.04
const _JAM_DEPTH := 0.01

## Frames between park revalidations. A parked body is frozen, so it has no
## gravity to notice with — nothing else would ever tell it the floor is gone.
const _PARK_CHECK_FRAMES := 12
var _park_check_frame: int = 0


## A park only holds while the set is still standing on something. Re-checked a
## few times a second rather than at the next resize, because what it stands on can
## go away — carried off, deleted with the scene, or scaled out from under it — and
## a frozen set left over an empty floor just hangs there. This is the invariant
## that keeps the freeze from ever reading as a bug: frozen implies supported.
func _release_park_if_unsupported() -> void:
	if not _parked_by_resize:
		return
	_park_check_frame += 1
	if _park_check_frame < _PARK_CHECK_FRAMES:
		return
	_park_check_frame = 0
	if _is_standing_on_something():
		return
	force_update_transform()
	freeze = false
	_parked_by_resize = false


## Whether the set is resting on a surface rather than in flight. Asked fresh per
## resize rather than tracked off the sleep state: a set put down and resized
## straight away — the usual way anyone reaches for the size slider — has not had
## time to fall asleep, and gating on sleep left exactly that case unprotected.
##
## Cast from the base, over a fixed gap. Casting from the origin over a reach that
## grows with the set instead means a big cabinet reads as standing while it is
## still a metre up, so resizing one on the way down parks it in the air.
func _is_standing_on_something() -> bool:
	var world := get_world_3d()
	if world == null:
		return false
	var base: Vector3 = global_position + Vector3.UP * (_local_bottom_y() * scale_factor)
	var query := PhysicsRayQueryParameters3D.create(
		base + Vector3.UP * _STANDING_GAP, base + Vector3.DOWN * _STANDING_GAP)
	query.exclude = [get_rid()]
	query.collision_mask = collision_mask
	return not world.direct_space_state.intersect_ray(query).is_empty()


## Whether the cabinet at its new size is inside the world — the wall behind it,
## the table it now overhangs. The box is shrunk by _JAM_DEPTH so the surface the
## set merely rests on does not read as a jam, and the base is lifted clear of it.
##
## Static bodies only. A prop that has come to rest against the cabinet also shows
## up in the query, and counting it would leave the set parked for as long as
## anything is lying on it. A loose prop is also not the problem being solved: the
## solver pushes it out of the way, which is fine. It is immovable world geometry
## that turns an overlap into an eviction the set can never win.
func _is_jammed() -> bool:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D) or get_world_3d() == null:
		return false
	var full: Vector3 = (col.shape as BoxShape3D).size * scale_factor
	var box := BoxShape3D.new()
	box.size = Vector3(
		maxf(full.x - 2.0 * _JAM_DEPTH, 0.01),
		maxf(full.y - 2.0 * _JAM_DEPTH, 0.01),
		maxf(full.z - 2.0 * _JAM_DEPTH, 0.01))
	var axes := global_basis.orthonormalized()
	# Nudged up off the supporting surface, which sits exactly at the pinned base.
	var centre: Vector3 = global_position + axes * (col.position * scale_factor) \
		+ Vector3.UP * _JAM_DEPTH
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(axes, centre)
	query.exclude = [get_rid()]
	query.collision_mask = collision_mask
	for hit: Dictionary in get_world_3d().direct_space_state.intersect_shape(query, 8):
		if hit.get("collider") is StaticBody3D:
			return true
	return false


## Bottom of the pickup COLLIDER along Y, in local space at scale 1 — the point
## the resize anchor holds still and the point the standing ray casts from.
##
## The collider, not the geometry: what a set rests on is its collision box, and
## the two are not the same height. The 90s cabinet's lowest mesh sits 4.5 cm
## under its box, which is enough to break both callers at once. The anchor lifts
## further than the box actually grew, so the solver spends every slider tick
## shoving the set back down into the table; and the standing ray starts INSIDE
## that table, where Godot reports no hit at all, so `standing` reads false for
## every set on furniture and the park never engages.
##
## Reading the shape also keeps this honest about WHEN it is asked. A sweep of the
## meshes answers with whatever happened to be visible at the time, and
## TVOptionsPanel's viewport quad — most of a metre below the origin — joins the
## tree a frame or two after _ready.
##
## Cheap enough to leave uncached: two property reads, and _resize_body_collision
## swaps the shape out from under any cache when a shell is fitted.
func _local_bottom_y() -> float:
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return 0.0
	return col.position.y - (col.shape as BoxShape3D).size.y * 0.5


func _on_tv_grabbed(_pickable: Node3D, _by: Node3D) -> void:
	# Picking the set up ends the park. XRToolsPickable has already snapshotted
	# freeze into restore_freeze by the time `grabbed` fires and its release_mode is
	# ORIGINAL, so it would restore OUR freeze on release and leave the set hanging
	# wherever it was let go — correct the snapshot, not just the flag.
	if _parked_by_resize:
		_parked_by_resize = false
		restore_freeze = false
	# The grab driver is created during the grab; stop it copying scale so the
	# TV keeps its size while held (deferred so the driver exists first).
	call_deferred("_lock_grab_scale")


func _lock_grab_scale() -> void:
	if _grab_driver != null and "update_scale" in _grab_driver:
		_grab_driver.update_scale = false


func _on_tv_dropped(_pickable: Node3D) -> void:
	# Safety net: reassert our scale in case the release disturbed it.
	_apply_scale()


## True when the TV is switched on (used by the remote's POWER cell tint).
func is_powered_on() -> bool:
	return _tv_enabled


## True when audio is muted (used by the remote's MUTE cell tint).
func is_muted() -> bool:
	return _muted


## What the set's own amplifier is passing: silence while off or muted.
func _effective_volume() -> float:
	return 0.0 if (not _tv_enabled or _muted) else _volume


## …and what reaches one input, which is nothing at all unless that input is the
## one SOURCE has selected.
##
## The set has five sound sources and only ever plays one. Deselecting an input
## used to silence only its PICTURE (set_screen_enabled) and leave its sound
## running, so switching a console to the tuner played the channel over the top
## of the game you had just been playing.
func _volume_for(source: int) -> float:
	return _effective_volume() if current_source == source else 0.0


## Push the current volume to every connected device and to the built-in tuner, so
## one knob governs whichever input is showing and the other four are quiet.
func _apply_audio_volume() -> void:
	# Every slot, not just the composite ones: a console reached through an RF switch
	# is on Source.RF and has to be silenced with the rest when it is not showing.
	for i in _connected_systems.size():
		var system: Node3D = _connected_systems[i]
		if system != null and is_instance_valid(system):
			system.set_audio_volume(_volume_for(i))
	if _tuner:
		_tuner.set_volume(_volume_for(Source.TV))


## Hand the glass to the selected input and take it off every other one.
##
## The same call covers SOURCE and POWER, which want the identical rule: exactly one
## host may paint, and only while the set is on. Without it a deselected console goes
## on writing its material onto the screen every frame and the two fight.
func _apply_screen_enable() -> void:
	for i in _connected_systems.size():
		var system: Node3D = _connected_systems[i]
		if system != null and is_instance_valid(system) \
				and system.has_method("set_screen_enabled"):
			# RF has a second condition on top of being selected: the set has to be
			# tuned to the channel the switch is putting the console on.
			var showing: bool = current_source == i and (i != Source.RF or _rf_tuned())
			system.set_screen_enabled(_tv_enabled and showing)


## Which socket input is selected, or -1 while the tuner is showing.
##
## Tested against Source.TV rather than against COMPOSITE_INPUTS: RF is past the
## composite block but it is still an input with a host on it, and a bound of
## COMPOSITE_INPUTS would hide that host from _selected_system — which is what owns
## the volume keys and the power button.
func _selected_input() -> int:
	return -1 if current_source == Source.TV else current_source


## Snow for an aerial channel with nothing on it. Built on first use, like the tuner
## — a set that never leaves the composite inputs should not pay for it.
func _rf_static() -> ShaderMaterial:
	if _rf_static_material == null:
		_rf_static_material = ShaderMaterial.new()
		_rf_static_material.shader = STATIC_SHADER
	return _rf_static_material


## True when the set is tuned to the channel the connected RF switch is using.
##
## Read off the host duck-typed, and a host that has no opinion counts as a match:
## the channel switch belongs to the CONSOLE (an NES wears one on its back panel),
## so a deck or a machine without one fed through an RF switch should simply appear
## rather than being invisibly wrong on both channels.
func _rf_tuned() -> bool:
	var host: Node3D = _connected_systems[Source.RF] \
		if _connected_systems.size() > Source.RF else null
	if host == null or not is_instance_valid(host):
		return false
	if not host.has_method("get_rf_channel"):
		return true
	var ch := int(host.call("get_rf_channel"))
	# -1 is "this machine has no channel switch". A match, not a mismatch: otherwise
	# a deck fed through an RF switch would be invisible on BOTH channels.
	return ch < 0 or ch == rf_channel


## The connected console's channel switch moved. Repaint, because the same switch
## position decides whether there is a picture at all and this is the only thing
## that tells the set it changed.
func on_rf_channel_changed() -> void:
	if current_source != Source.RF:
		return
	_apply_screen_enable()
	_apply_audio_volume()
	show_osd_timed(_source_banner(), 2.0)


## The host feeding the selected input, if there is one and it is still alive.
func _selected_system() -> Node3D:
	var input := _selected_input()
	if input < 0:
		return null
	var system: Node3D = _connected_systems[input]
	return system if system != null and is_instance_valid(system) else null


## A volume key clears mute (like a real set) so the change is audible.
func _clear_mute_silently() -> void:
	if _muted:
		_muted = false
		hide_osd()


func _on_volume_down() -> void:
	_clear_mute_silently()
	_volume = maxf(0.0, _volume - 0.1)
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_DOWN, {"tv": self})


func _on_volume_up() -> void:
	_clear_mute_silently()
	_volume = minf(1.0, _volume + 0.1)
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_UP, {"tv": self})


## Toggle mute: silence (or restore) the connected device and show/clear a sticky
## "MUTE" OSD in the same corner "POWER" uses. No-op audibility change while off.
## Red while muted, matching the remote's own mute tint. Driven from here rather
## than the button so the remote's mute lands on the same cap.
func _update_mute_button_color() -> void:
	if _mute_btn:
		_mute_btn.set_color(Color(1.0, 0.35, 0.35) if _muted else Color(0.35, 0.35, 0.35))


func _on_mute_toggle() -> void:
	_muted = not _muted
	_update_mute_button_color()
	_update_audio_mode_button()
	_apply_audio_volume()
	if _muted:
		show_osd("MUTE")
	else:
		hide_osd()
	NetworkManager.report_event(NetObjectSync.EV_TV_MUTE, {"tv": self})


func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled else Color(1.0, 0.1, 0.1))
	if _tv_enabled:
		_play_power_on_anim()
		# Coming back on while muted keeps the sticky MUTE indicator, otherwise
		# show the usual POWER flash.
		if _muted:
			show_osd("MUTE")
		else:
			show_osd_timed("POWER", 3.0)
	else:
		_stop_power_on_anim()
		hide_osd()
		_vol_osd_token += 1
		_set_vol_osd_text("")
	# Powering back on must not un-mute a composite input while the set is showing
	# the tuner (or another input) -- it would start repainting the screen underneath.
	_apply_screen_enable()
	if _tuner:
		_tuner.set_active(_tv_enabled and current_source == Source.TV)
	_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_POWER, {"tv": self})


## Ignore-gravity: the device floats where it is put instead of falling. Restored
## from a save through this flag, which FloatLock reads once at _ready.
var ignore_gravity: bool = false
var _float_lock: FloatLock = null


func get_ignore_gravity() -> bool:
	return _float_lock != null and _float_lock.enabled


func set_ignore_gravity(on: bool) -> void:
	ignore_gravity = on
	if _float_lock != null:
		_float_lock.set_enabled(on)
