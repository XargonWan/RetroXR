## TV — pickable television with a screen surface and a composite video input port.
class_name RetroTV
extends XRToolsPickable


## Emitted when a cable plug connects to this TV's composite port
signal cable_connected(plug)

## Emitted when the cable plug disconnects
signal cable_disconnected


const CRT_SHADER := preload("res://Shaders/crt_effect.gdshader")
const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")

## CRT display filter (curvature, scanlines, aperture mask). Applied to
## whatever source is showing — a system's game or the VCR's video.
@export var crt_enabled: bool = true

@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
@onready var _composite_port: XRToolsSnapZone = $CompositePort
@onready var _ambilight: SpotLight3D = $Ambilight
@onready var _vol_down_btn: VRButton = $VolumeDownButton
@onready var _vol_up_btn: VRButton = $VolumeUpButton
@onready var _tv_toggle_btn: VRButton = $TVToggleButton
@onready var _crt_btn: VRButton = $CRTButton
@onready var _volume_label: Label3D = $VolumeLabel
@onready var _osd_label: Label3D = $ScreenMesh/OSDLabel

# CRT wrap state: the ShaderMaterial we install over the source material, and
# the source material we replaced (restored when the filter turns off).
var _crt_material: ShaderMaterial = null
var _crt_wrapped: Material = null

# Bumped each time an OSD message is shown or hidden so a stale auto-hide timer
# from a previous message can't clear a newer one.
var _osd_token: int = 0

# Track the last-snapped plug so we can disconnect properly
var _snapped_plug: CablePlug = null

# Button state and volume control. The connected host is any node implementing
# the TV contract (on_tv_connected/on_tv_disconnected/set_audio_volume/
# set_screen_enabled) — a RetroSystem or a VCRPlayer — so it's typed loosely.
var _connected_system: Node3D = null
var _volume: float = 1.0       # 0.0–1.0, default 100%
var _tv_enabled: bool = true

# Frame counter for ambilight sampling
var _ambilight_frame: int = 0


func _ready() -> void:
	super._ready()
	_composite_port.has_picked_up.connect(_on_plug_snapped)
	_composite_port.has_dropped.connect(_on_plug_released)
	_vol_down_btn.button_pressed.connect(_on_volume_down)
	_vol_up_btn.button_pressed.connect(_on_volume_up)
	_tv_toggle_btn.button_pressed.connect(_on_tv_toggle)
	_crt_btn.button_pressed.connect(_on_crt_toggle)
	_vol_down_btn.set_color(Color(0.1, 0.3, 0.9))   # blue
	_vol_up_btn.set_color(Color(0.0, 0.9, 0.9))     # cyan
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0))  # green = on
	_update_crt_button_color()
	_update_volume_label()


func _process(_delta: float) -> void:
	_update_crt()

	if not _ambilight or not _ambilight.visible:
		return

	_ambilight_frame += 1
	var interval: int = QualityManager.ambilight_interval if QualityManager else 10
	if _ambilight_frame < interval:
		return
	_ambilight_frame = 0

	# Sample average screen color from the current source texture (works for
	# system emission materials, VCR materials and the CRT wrapper alike).
	var tex := _current_source_texture()
	if not tex:
		return
	var img := tex.get_image()
	if not img:
		return

	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var avg := img.get_pixel(0, 0)
	_ambilight.light_color = Color(avg.r, avg.g, avg.b)


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

	# VHS shader on the screen: chain the CRT stage inside it via its
	# crt_enabled uniform rather than replacing the material.
	if override is ShaderMaterial and override != _crt_material:
		var sm := override as ShaderMaterial
		if sm.shader == VCR_SHADER:
			# Note: an unset uniform reads back as null, never bool — compare
			# against the Variant directly.
			var cur: Variant = sm.get_shader_parameter("crt_enabled")
			if (cur == true) != crt_enabled:
				sm.set_shader_parameter("crt_enabled", crt_enabled)
		_crt_wrapped = null
		return

	if not crt_enabled:
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
	if _crt_material == null:
		_crt_material = ShaderMaterial.new()
		_crt_material.shader = CRT_SHADER
	_crt_material.set_shader_parameter("source_tex", tex)
	_crt_wrapped = override
	_screen_mesh.set_surface_override_material(0, _crt_material)


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
	if _crt_wrapped != null and _screen_mesh.get_surface_override_material(0) == _crt_material:
		_screen_mesh.set_surface_override_material(0, _crt_wrapped)
	_crt_wrapped = null


func set_crt_enabled(enabled: bool) -> void:
	crt_enabled = enabled
	_update_crt_button_color()


func _on_crt_toggle() -> void:
	set_crt_enabled(not crt_enabled)


func _update_crt_button_color() -> void:
	if _crt_btn:
		_crt_btn.set_color(Color(1.0, 0.6, 0.1) if crt_enabled else Color(0.35, 0.35, 0.35))


## Returns the screen MeshInstance3D so Libretro can render onto it
func get_screen_mesh() -> MeshInstance3D:
	return _screen_mesh


# ── On-screen display (top-right corner) ────────────────────────────────────────

## Show a persistent OSD message (stays until replaced or hidden).
func show_osd(text: String) -> void:
	_osd_token += 1
	_osd_label.text = text
	_osd_label.visible = true


## Show an OSD message that auto-hides after `seconds` (unless superseded).
func show_osd_timed(text: String, seconds: float) -> void:
	_osd_token += 1
	var tok := _osd_token
	_osd_label.text = text
	_osd_label.visible = true
	get_tree().create_timer(seconds).timeout.connect(func():
		if tok == _osd_token:
			hide_osd()
	)


## Clear the OSD.
func hide_osd() -> void:
	_osd_token += 1
	_osd_label.visible = false
	_osd_label.text = ""


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
			system.on_tv_connected(self)


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
			system.on_tv_disconnected()
		_connected_system = null
		_snapped_plug = null


func _update_volume_label() -> void:
	_volume_label.text = "%d" % roundi(_volume * 100.0)


func _on_volume_down() -> void:
	_volume = maxf(0.0, _volume - 0.1)
	_update_volume_label()
	if _tv_enabled and _connected_system:
		_connected_system.set_audio_volume(_volume)


func _on_volume_up() -> void:
	_volume = minf(1.0, _volume + 0.1)
	_update_volume_label()
	if _tv_enabled and _connected_system:
		_connected_system.set_audio_volume(_volume)


func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled else Color(1.0, 0.1, 0.1))
	if _connected_system:
		_connected_system.set_screen_enabled(_tv_enabled)
		_connected_system.set_audio_volume(_volume if _tv_enabled else 0.0)
