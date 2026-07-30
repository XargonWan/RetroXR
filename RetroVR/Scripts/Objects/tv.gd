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

## CRT display filter (curvature, scanlines, aperture mask). Applied to
## whatever source is showing — a system's game or the VCR's video.
@export var crt_enabled: bool = true

## Which cabinet to wear. Empty = the original box body authored in tv.tscn, and
## _load_shell() is then a strict no-op — the arcade and den TVs must render
## bit-identically to before this system existed.
@export var tv_model: String = ""

## Cabinet variants. A shell supplies geometry plus Marker3D seats; every
## functional node stays on this TV. See Scripts/Objects/tv_shell.gd.
const _SHELL_SCENES := {
	"crt_90s":     "res://Scenes/Objects/tv_models/crt_90s.tscn",
	"crt_monitor": "res://Scenes/Objects/tv_models/crt_monitor.tscn",
}

var _shell: RetroTVShell = null

@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
@onready var _composite_port: XRToolsSnapZone = $CompositePort
@onready var _ambilight: SpotLight3D = $Ambilight
@onready var _vol_down_btn: VRButton = $VolumeDownButton
@onready var _vol_up_btn: VRButton = $VolumeUpButton
@onready var _tv_toggle_btn: VRButton = $TVToggleButton
@onready var _crt_btn: VRButton = $CRTButton
@onready var _stereo_btn: VRButton = $StereoButton
@onready var _volume_label: Label3D = $VolumeLabel
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
const STEREO_MODE_NAMES := ["3D: STEREO", "3D: LEFT EYE", "3D: RIGHT EYE"]

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

# Track the last-snapped plug so we can disconnect properly
var _snapped_plug: CablePlug = null

# Button state and volume control. The connected host is any node implementing
# the TV contract (on_tv_connected/on_tv_disconnected/set_audio_volume/
# set_screen_enabled) — a RetroSystem or a VCRPlayer — so it's typed loosely.
var _connected_system: Node3D = null
var _volume: float = 1.0       # 0.0–1.0, default 100%
var _tv_enabled: bool = true

## The set's own mechanical noise — flyback whine plus switch transients, through
## SpatialAudioEmitter. Deliberately NOT routed through _effective_volume(): the
## whine is radiated by the transformer, not the speaker, so the volume knob and
## MUTE do not touch it. Only power does, which is how a real set behaves.
var _crt_hum: CrtHum = null
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
	# Before anything reads the screen mesh or the buttons — _screen_size_m below
	# is derived from ScreenMesh, and a shell may have moved and rescaled it.
	_load_shell()
	_build_crt_hum()
	_composite_port.has_picked_up.connect(_on_plug_snapped)
	_composite_port.has_dropped.connect(_on_plug_released)
	_vol_down_btn.button_pressed.connect(_on_volume_down)
	_vol_up_btn.button_pressed.connect(_on_volume_up)
	_tv_toggle_btn.button_pressed.connect(_on_tv_toggle)
	_crt_btn.button_pressed.connect(_on_crt_toggle)
	_stereo_btn.button_pressed.connect(_on_stereo_toggle)
	_vol_down_btn.set_color(Color(0.1, 0.3, 0.9))   # blue
	_vol_up_btn.set_color(Color(0.0, 0.9, 0.9))     # cyan
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0))  # green = on
	# Hidden until a stereo source is connected (see _update_stereo_button).
	# VRButton._ready adds the pointable layer — strip it while hidden so the
	# invisible button can't eat pokes or laser clicks (deferred: our _ready
	# runs before the child button's).
	_stereo_btn.set_process(false)
	_stereo_btn.set_deferred("collision_layer", 0)
	_update_crt_button_color()
	_update_stereo_button_color()
	_update_volume_label()

	# Keep the chosen display size across pickups: xr-tools' grab driver is a
	# RemoteTransform3D that copies scale (forcing us back to 1x while held), so
	# disable its scale copy on grab and reassert our scale on drop.
	grabbed.connect(_on_tv_grabbed)
	dropped.connect(_on_tv_dropped)
	sleeping_state_changed.connect(_on_sleeping_state_changed)
	_apply_scale()

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
	_seat_node(_composite_port, _shell.port_seat())
	_seat_node(_ambilight, _shell.ambilight_seat())
	_seat_node(_volume_label, _shell.volume_label_seat())

	# Bezel buttons march along the row marker's local +X from the first cap.
	var row: Variant = _shell.button_row_seat()
	var buttons: Array[Node3D] = [
		_vol_down_btn, _vol_up_btn, _tv_toggle_btn, _crt_btn, _stereo_btn,
	]
	if not _shell.show_button_row:
		for btn in buttons:
			btn.visible = false
			btn.set_deferred("collision_layer", 0)
	elif row is Transform3D:
		var base: Transform3D = row
		for i in buttons.size():
			var b: Node3D = buttons[i]
			# Keep each cap's authored basis (they are rotated to face outward);
			# only the origin walks the row.
			b.transform = Transform3D(b.transform.basis,
				base * Vector3(float(i) * _shell.button_pitch, 0.0, 0.0))

	_resize_body_collision(_shell.body_size)


func _seat_node(node: Node3D, seat: Variant) -> void:
	if node != null and seat is Transform3D:
		node.transform = seat


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
		if effective == _blue_material or effective == null:
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
		if sm.shader == VCR_SHADER or sm.shader == WINDOW_SHADER:
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

	if not crt_enabled and not _source_is_sbs():
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


## True when the connected source outputs a side-by-side stereo frame (Virtual Boy).
func _source_is_sbs() -> bool:
	return _connected_system != null \
		and _connected_system.has_method("is_stereo_output") \
		and _connected_system.is_stereo_output()


## True while what's showing is a stereo source: a full-frame SBS system (VB)
## or a dual-screen system's window channel with a per-eye shift (3DS top).
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
		_stereo_btn.visible = active
		_stereo_btn.set_process(active)
		_stereo_btn.collision_layer = VRButton.POINTABLE_LAYER if active else 0


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


func set_crt_enabled(enabled: bool) -> void:
	crt_enabled = enabled
	_update_crt_button_color()
	NetworkManager.report_event(NetObjectSync.EV_TV_CRT, {"tv": self, "on": enabled})


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


func _update_stereo_button_color() -> void:
	if _stereo_btn:
		# Magenta = per-eye stereo; dimmer purple flavors for single-eye modes.
		match stereo_mode:
			0: _stereo_btn.set_color(Color(1.0, 0.2, 1.0))
			1: _stereo_btn.set_color(Color(0.55, 0.35, 0.75))
			2: _stereo_btn.set_color(Color(0.35, 0.35, 0.75))


## Returns the screen MeshInstance3D so Libretro can render onto it
func get_screen_mesh() -> MeshInstance3D:
	return _screen_mesh


## World positions of the set's left and right speakers, in that order.
##
## Derived from ScreenMesh rather than the cabinet, because a shell can move and
## rescale the screen (see _load_shell) and hardcoded cabinet offsets would drift
## away from whatever model is actually fitted.
##
## The set faces +Z: the screen sits proud of the front face and the composite
## port is on the back at -Z. Speakers go on the front baffle, flanking the tube
## and slightly below its centre, which is where a CRT of this vintage puts them.
## Emitting from the cabinet centre instead makes the sound appear to come from
## inside the box -- inaudible with amplitude panning, obvious with HRTF.
##
## The offsets are in the set's own local metres, so they are applied with the
## UNNORMALISED basis: its columns are scale_factor long, which converts to world
## and tracks the display scale (and any parent's) for free. Normalising here
## would pin the speakers to 1x while the picture around them grew.
func get_speaker_positions() -> PackedVector3Array:
	var half_w: float = _screen_size_m.x * 0.5 + 0.055
	var drop: float = _screen_size_m.y * 0.35
	var basis := global_transform.basis
	# Front of the screen, not the cabinet centre.
	var face: Vector3 = _screen_mesh.global_position + basis.z * 0.005
	var right: Vector3 = basis.x * half_w
	var down: Vector3 = -basis.y * drop
	var out := PackedVector3Array()
	out.push_back(face - right + down)
	out.push_back(face + right + down)
	return out


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
	var filled := roundi(_volume * 10.0)
	var text := "VOL " + "|".repeat(filled) + "-".repeat(10 - filled)
	_set_vol_osd_text(text)
	get_tree().create_timer(2.0).timeout.connect(func():
		if tok == _vol_osd_token:
			_vol_osd_token += 1
			_set_vol_osd_text("")
	)


func _set_vol_osd_text(text: String) -> void:
	_vol_osd_label.text = text
	_vol_osd_text_2d.text = text
	_refresh_osd_texture(text)


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
				or candidate.shader == WINDOW_SHADER:
			sm = candidate
	if sm != null:
		sm.set_shader_parameter("osd_tex", _osd_viewport.get_texture())
		sm.set_shader_parameter("osd_enabled", main_active or vol_active)
		_osd_label.visible = false
		_vol_osd_label.visible = false
	else:
		_osd_label.visible = main_active
		_vol_osd_label.visible = vol_active


## Snaps a cable plug into this TV's composite port (used by save/load to restore connections).
func accept_plug_restore(plug: CablePlug) -> void:
	print("[RetroTV] accept_plug_restore: plug=%s port=%s" % [plug, _composite_port])
	_composite_port.pick_up_object(plug)
	print("[RetroTV] accept_plug_restore: done, port.picked_up=%s" % _composite_port.picked_up_object)


## Called when a cable plug snaps into the composite port
func _on_plug_snapped(plug: Node3D) -> void:
	# Hand the incoming host a clean screen so the C++ video handler doesn't
	# capture our CRT wrapper as the "original" material to restore later.
	_unwrap_crt()
	cable_connected.emit(plug)
	if plug is CablePlug:
		_snapped_plug = plug as CablePlug
		# Prevent the frozen kinematic plug from physically pushing the TV
		add_collision_exception_with(_snapped_plug)
		var system := _snapped_plug.get_system()
		if system:
			_connected_system = system
			# Multi-output systems need to know WHICH cable landed; other
			# hosts (VCR/DVD) keep the plain single-arg contract.
			if system is RetroSystem:
				(system as RetroSystem).on_tv_connected(self, _snapped_plug)
			else:
				system.on_tv_connected(self)
			NetworkManager.report_event(NetObjectSync.EV_TV_PLUG,
				{"owner": system, "tv": self, "ch": _snapped_plug.channel})


## Called when the cable plug leaves the composite port
func _on_plug_released() -> void:
	# Unwrap before the host tears down so it restores over its own material,
	# not our CRT wrapper.
	_unwrap_crt()
	cable_disconnected.emit()
	if _snapped_plug:
		remove_collision_exception_with(_snapped_plug)
		var system := _snapped_plug.get_system()
		if system:
			if system is RetroSystem:
				(system as RetroSystem).on_tv_disconnected(_snapped_plug)
			else:
				system.on_tv_disconnected()
		_connected_system = null
		_snapped_plug = null
		NetworkManager.report_event(NetObjectSync.EV_TV_UNPLUG, {"tv": self})


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
	# Grow/shrink away from the surfaces the TV is up against rather than about
	# its own origin. A set is placed base-down and back-to-wall, so scaling about
	# the centre drives its bottom into the table and its back into the wall. The
	# solver resolves both penetrations by ejecting the body, and because the size
	# slider re-applies every tick the ejections accumulate: the TV sinks a little,
	# tips, and walks across the furniture. Pinning the bottom and the back face
	# keeps both contacts intact, so the extra size grows upward and forward.
	#
	# The offsets are unscaled local constants rather than world measurements taken
	# after the write: a child's global_transform is still stale in the frame its
	# parent's scale changes, so re-measuring reads back pre-scale values and the
	# correction cancels to nothing.
	#
	# previous is tracked here, not read back off scale.y, because the authored or
	# restored position already sits where the anchoring puts it. Correcting a
	# scale the node has never actually worn would shift a persisted 2.1x set up
	# and forward again on every load.
	var previous := _anchored_scale
	_anchored_scale = scale_factor
	# Measured before the scale write, which is what leaves the children stale —
	# and unconditionally, so the very first call, from _ready, is the one that
	# fills the cache while every transform is still coherent.
	var bottom := _local_bottom_y()
	var back := _local_back_z()
	scale = Vector3.ONE * scale_factor
	if is_nan(previous):
		return
	# bottom_world = origin_y + s * local_bottom, so holding it fixed means
	# shifting the origin by (old_s - new_s) * local_bottom; likewise for the back
	# face along the TV's own -Z.
	var delta := previous - scale_factor
	if is_zero_approx(delta):
		return
	global_position += Vector3(0.0, delta * bottom, 0.0) \
		+ global_basis.orthonormalized().z * (delta * back)
	# Whatever the enlarged cabinet still overlaps — a corner wall, the front edge
	# of the desk it now overhangs — is a penetration the solver would spend the
	# next frames evicting, and the slider re-applies every tick, so the evictions
	# compound into a slide and a slow topple that the set never recovers from.
	# Resizing a set that is standing somewhere is a placement, not a collision:
	# hand it straight back asleep.
	#
	# force_update_transform first: the writes above only queue a transform
	# notification, and the flush at the end of the frame is what pushes the pose
	# to the physics server — and wakes the body. Sleeping it before that flush
	# does nothing at all.
	if _rested_in_place and not freeze:
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		force_update_transform()
		sleeping = true


## Scale the anchor correction was last applied at. NAN until the first
## _apply_scale, whose job is only to put the authored/restored scale on the node.
var _anchored_scale: float = NAN

## True once the set has settled somewhere and stayed there, so a resize can be
## treated as a placement. Only ever set from the sleep edge, never cleared on
## waking: _apply_scale's own teleport wakes the body, and mid-drag the sleep
## timer never gets to expire, so a body that reads awake here is usually one we
## woke ourselves. Pickup is the clearing event — after a drop, the set has to
## come to rest again before another resize will pin it.
var _rested_in_place: bool = false


## Lowest point of the TV's mesh geometry along Y, in local space at scale 1.
## Cached: the meshes never move relative to the TV, so this is a constant.
##
## Only MeshInstance3D counts. A VisualInstance3D sweep would also pick up the
## Ambilight SpotLight3D, whose AABB is its light cone — that reaches far below
## the cabinet, and anchoring to it would lift the TV clean off the table.
var _local_bottom_y_cache: float = NAN


func _local_bottom_y() -> float:
	if not is_nan(_local_bottom_y_cache):
		return _local_bottom_y_cache
	var to_local := global_transform.affine_inverse()
	var lowest := INF
	for mi: MeshInstance3D in _mesh_instances(self):
		var box := mi.get_aabb()
		var xf := to_local * mi.global_transform
		for i in range(8):
			lowest = minf(lowest, (xf * box.get_endpoint(i)).y)
	# to_local already divided out the current scale, so this is the scale-1
	# offset and stays valid however the TV is resized later.
	_local_bottom_y_cache = 0.0 if is_inf(lowest) else lowest
	return _local_bottom_y_cache


## Rear face of the TV along local -Z, at scale 1.
##
## Read off the body collider, not the meshes: what must not enter the wall is
## the shape the solver tests, and the port stub and its snap highlight hang
## behind the cabinet, so a mesh sweep would anchor 20 mm too far back. The
## shape is per-instance already — _resize_body_collision duplicates it.
func _local_back_z() -> float:
	var body_col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if body_col and body_col.shape is BoxShape3D:
		return body_col.position.z - (body_col.shape as BoxShape3D).size.z * 0.5
	return 0.0


func _mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D and (node as MeshInstance3D).visible:
		found.append(node as MeshInstance3D)
	for child in node.get_children():
		found.append_array(_mesh_instances(child))
	return found


func _on_sleeping_state_changed() -> void:
	if sleeping:
		_rested_in_place = true


func _on_tv_grabbed(_pickable: Node3D, _by: Node3D) -> void:
	_rested_in_place = false
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


## Give the set its idle hum. Starts WITHOUT the power-on transient — the TV is
## authored on, and a scene that thunked a degauss at the player as they walked in
## would be announcing something nobody did.
func _build_crt_hum() -> void:
	_crt_hum = CrtHum.new()
	_crt_hum.name = "CrtHum"
	add_child(_crt_hum)
	_crt_hum.set_powered(_tv_enabled, false)


## The volume actually sent to the connected device: silence while off or muted.
func _effective_volume() -> float:
	return 0.0 if (not _tv_enabled or _muted) else _volume


## Push the current effective volume to the connected device (if any).
func _apply_audio_volume() -> void:
	if _connected_system:
		_connected_system.set_audio_volume(_effective_volume())


## A volume key clears mute (like a real set) so the change is audible.
func _clear_mute_silently() -> void:
	if _muted:
		_muted = false
		hide_osd()


func _update_volume_label() -> void:
	_volume_label.text = "%d" % roundi(_volume * 100.0)


func _on_volume_down() -> void:
	_clear_mute_silently()
	_volume = maxf(0.0, _volume - 0.1)
	_update_volume_label()
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_DOWN, {"tv": self})


func _on_volume_up() -> void:
	_clear_mute_silently()
	_volume = minf(1.0, _volume + 0.1)
	_update_volume_label()
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_UP, {"tv": self})


## Toggle mute: silence (or restore) the connected device and show/clear a sticky
## "MUTE" OSD in the same corner "POWER" uses. No-op audibility change while off.
func _on_mute_toggle() -> void:
	_muted = not _muted
	_apply_audio_volume()
	if _muted:
		show_osd("MUTE")
	else:
		hide_osd()
	NetworkManager.report_event(NetObjectSync.EV_TV_MUTE, {"tv": self})


func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	if _crt_hum != null:
		_crt_hum.set_powered(_tv_enabled)
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
	if _connected_system:
		_connected_system.set_screen_enabled(_tv_enabled)
		_connected_system.set_audio_volume(_effective_volume())
	NetworkManager.report_event(NetObjectSync.EV_TV_POWER, {"tv": self})
