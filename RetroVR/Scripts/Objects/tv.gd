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

# Track the last-snapped plug so we can disconnect properly
var _snapped_plug: CablePlug = null

# Frame counter for ambilight sampling
var _ambilight_frame: int = 0


func _ready() -> void:
	super._ready()
	_composite_port.has_picked_up.connect(_on_plug_snapped)
	_composite_port.has_dropped.connect(_on_plug_released)


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
			system.on_tv_connected(self)


## Called when the cable plug leaves the composite port
func _on_plug_released() -> void:
	cable_disconnected.emit()
	if _snapped_plug:
		remove_collision_exception_with(_snapped_plug)
		var system := _snapped_plug.get_system()
		if system:
			system.on_tv_disconnected()
		_snapped_plug = null
