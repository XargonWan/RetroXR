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

# Track the last-snapped plug so we can disconnect properly
var _snapped_plug: CablePlug = null

# Button state and volume control
var _connected_system: RetroSystem = null
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


func _on_volume_down() -> void:
	_volume = maxf(0.0, _volume - 0.1)
	if _tv_enabled and _connected_system:
		_connected_system.set_audio_volume(_volume)


func _on_volume_up() -> void:
	_volume = minf(1.0, _volume + 0.1)
	if _tv_enabled and _connected_system:
		_connected_system.set_audio_volume(_volume)


func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled else Color(1.0, 0.1, 0.1))
	if _connected_system:
		_connected_system.set_screen_enabled(_tv_enabled)
		_connected_system.set_audio_volume(_volume if _tv_enabled else 0.0)
