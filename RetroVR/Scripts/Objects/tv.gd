## TV — pickable television with a screen surface and a composite video input port.
class_name RetroTV
extends XRToolsPickable


## Emitted when a cable plug connects to this TV's composite port
signal cable_connected(plug)

## Emitted when the cable plug disconnects
signal cable_disconnected


@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
@onready var _composite_port: XRToolsSnapZone = $CompositePort
@onready var _ambilight: SpotLight3D = $Ambilight
@onready var _vol_down_btn: VRButton = $VolumeDownButton
@onready var _vol_up_btn: VRButton = $VolumeUpButton
@onready var _tv_toggle_btn: VRButton = $TVToggleButton
@onready var _volume_label: Label3D = $VolumeLabel
@onready var _osd_label: Label3D = $ScreenMesh/OSDLabel

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
	_vol_down_btn.set_color(Color(0.1, 0.3, 0.9))   # blue
	_vol_up_btn.set_color(Color(0.0, 0.9, 0.9))     # cyan
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0))  # green = on
	_update_volume_label()


func _process(_delta: float) -> void:
	if not _ambilight or not _ambilight.visible:
		return

	_ambilight_frame += 1
	var interval: int = QualityManager.ambilight_interval if QualityManager else 10
	if _ambilight_frame < interval:
		return
	_ambilight_frame = 0

	# Sample average screen color from the screen material's texture
	var mat := _screen_mesh.get_surface_override_material(0) as StandardMaterial3D
	if not mat or not mat.albedo_texture:
		return

	var tex := mat.albedo_texture
	var img := tex.get_image()
	if not img:
		return

	img.resize(1, 1, Image.INTERPOLATE_BILINEAR)
	var avg := img.get_pixel(0, 0)
	_ambilight.light_color = Color(avg.r, avg.g, avg.b)


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
