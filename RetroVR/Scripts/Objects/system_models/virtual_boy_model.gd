## RetroSystemModelVirtualBoy — the 1995 stereoscopic tabletop, reborn in VR.
##
## mednafen_vb is forced to vb_3dmode = "side-by-side" (get_forced_core_options
## → the .opt seam), making the core output BOTH eyes in one 768×224 frame.
## The C++ VideoHandler drives a hidden proxy quad; this model copies the
## proxy's emission texture into the eyepiece quad's stereo ShaderMaterial,
## which samples the left half for the left eye and the right half for the
## right (VIEW_INDEX) — real per-eye stereo depth in the headset, without the
## original's head-in-a-vice sweet spot. On desktop the eyepiece shows the
## left eye's image flat.
##
## Not a handheld: it stands on its bipod like the real thing, with one
## controller port. The video-out cable still works — a TV shows the raw
## side-by-side frame, exactly like pointing a capture card at one.
class_name RetroSystemModelVirtualBoy
extends RetroSystemModel

const STEREO_SHADER := preload("res://Shaders/vb_stereo.gdshader")

# Visor ~220×110×95 mm on a ~250 mm stand, red-on-black like the hardware.
const VISOR_SIZE := Vector3(0.22, 0.11, 0.095)
const STAND_H := 0.25
## Eyepiece view: one eye's 384×224 image (12:7).
const EYE_SIZE := Vector2(0.132, 0.077)

var _proxy: MeshInstance3D = null
var _eyepiece: MeshInstance3D = null
var _stereo_mat: ShaderMaterial = null
var _visor_center_y := 0.0


func get_controller_port_count() -> int:
	return 1


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden — VideoHandler renders here, the eyepiece samples it


func get_forced_core_options() -> Dictionary:
	return {"vb_3dmode": "side-by-side", "vb_sidebyside_separation": "0"}


func _ready() -> void:
	_visor_center_y = STAND_H + VISOR_SIZE.y / 2.0
	_build_shell()


func _build_shell() -> void:
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0.08, 0.08, 0.09)
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.55, 0.08, 0.10)

	# Bipod stand: base plate + column.
	var base := MeshInstance3D.new()
	base.name = "StandBase"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(0.16, 0.012, 0.14)
	base.mesh = base_mesh
	base.set_surface_override_material(0, black)
	base.position = Vector3(0, 0.006, 0)
	add_child(base)

	var column := MeshInstance3D.new()
	column.name = "StandColumn"
	var col_mesh := CylinderMesh.new()
	col_mesh.top_radius = 0.012
	col_mesh.bottom_radius = 0.012
	col_mesh.height = STAND_H
	column.mesh = col_mesh
	column.set_surface_override_material(0, black)
	column.position = Vector3(0, STAND_H / 2.0, 0)
	add_child(column)

	# Visor body (red) with a black eye-shade plate on the front (+Z), which
	# is where the player leans in — the eyepiece screen sits on that plate.
	var visor := MeshInstance3D.new()
	visor.name = "Visor"
	var visor_mesh := BoxMesh.new()
	visor_mesh.size = VISOR_SIZE
	visor.mesh = visor_mesh
	visor.set_surface_override_material(0, red)
	visor.position = Vector3(0, _visor_center_y, 0)
	add_child(visor)

	var shade := MeshInstance3D.new()
	shade.name = "EyeShade"
	var shade_mesh := BoxMesh.new()
	shade_mesh.size = Vector3(VISOR_SIZE.x * 0.92, VISOR_SIZE.y * 0.82, 0.006)
	shade.mesh = shade_mesh
	shade.set_surface_override_material(0, black)
	shade.position = Vector3(0, _visor_center_y, VISOR_SIZE.z / 2.0 + 0.003)
	add_child(shade)

	# Eyepiece: the stereo quad on the shade, facing the player (+Z).
	_stereo_mat = ShaderMaterial.new()
	_stereo_mat.shader = STEREO_SHADER
	_eyepiece = MeshInstance3D.new()
	_eyepiece.name = "Eyepiece"
	var quad := QuadMesh.new()
	quad.size = EYE_SIZE
	_eyepiece.mesh = quad
	_eyepiece.position = Vector3(0, _visor_center_y, VISOR_SIZE.z / 2.0 + 0.0075)
	_eyepiece.set_surface_override_material(0, _stereo_mat)
	add_child(_eyepiece)

	# Hidden proxy the C++ VideoHandler renders to (side-by-side composite).
	_proxy = MeshInstance3D.new()
	_proxy.name = "ProxyScreen"
	var pquad := QuadMesh.new()
	pquad.size = Vector2(0.01, 0.01)
	_proxy.mesh = pquad
	_proxy.position = Vector3(0, _visor_center_y, 0)
	_proxy.visible = false
	add_child(_proxy)


func _process(_delta: float) -> void:
	# Feed the eyepiece: whatever emission texture the VideoHandler put on the
	# proxy flows into the stereo shader (same copy-on-change pattern as the
	# dual-screen bottom quad and the TVs' CRT wrapper).
	if _proxy == null or _stereo_mat == null:
		return
	var mat := _proxy.get_surface_override_material(0)
	var tex: Texture2D = null
	if mat is StandardMaterial3D:
		tex = (mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	if _stereo_mat.get_shader_parameter("source_tex") != tex:
		_stereo_mat.set_shader_parameter("source_tex", tex)


## The single controller cable plugs into the base at the rear, not the default
## floating console position out in front of the stand.
func configure_controller_ports(port_zones: Array) -> void:
	if port_zones.size() > 0:
		port_zones[0].position = Vector3(0, 0.015, -0.06)


func configure_cartridge_slot(slot: Node3D) -> void:
	# Cart drops into the top of the visor, like the real loading slot.
	slot.position = Vector3(0, _visor_center_y + VISOR_SIZE.y / 2.0 + 0.01, 0)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false


func configure_cable_attach(attach_point: Node3D) -> void:
	# Video-out on the rear of the visor, not the left edge.
	attach_point.position = Vector3(0, _visor_center_y, -VISOR_SIZE.z / 2.0 - 0.002)


## The default console collision box (bottom at y=-0.05) leaves the Virtual Boy
## floating above the floor. Size the box to the model's footprint/height and sit
## its bottom at y=0 so the stand base rests on the ground.
func configure_collision(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return
	col.shape = col.shape.duplicate()
	var top := _visor_center_y + VISOR_SIZE.y / 2.0   # full height from the floor
	(col.shape as BoxShape3D).size = Vector3(VISOR_SIZE.x, top, 0.14)
	col.position = Vector3(0, top / 2.0, 0)


func on_power_on() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 1.0)


func on_power_off() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 0.0)
