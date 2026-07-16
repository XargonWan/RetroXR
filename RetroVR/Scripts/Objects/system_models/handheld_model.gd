## RetroSystemModelHandheld — shared base for handheld consoles (Game Boy family).
##
## A handheld is a RetroSystem whose model provides a BUILT-IN screen: the core
## renders to the on-device LCD when no TV is connected, and the video-out
## cable moves the picture to a TV (Super Game Boy style). The model builds a
## procedural shell (body, screen, cosmetic d-pad/buttons), repositions the
## cartridge slot + video-out port, resizes the root collision to the device,
## and adds the on-device controls: a volume slider and a 2-detent power switch.
##
## Subclasses set the dimensions/colors in _init (Game Boy portrait, GBA
## landscape) — everything else lives here.
class_name RetroSystemModelHandheld
extends RetroSystemModel

# Device local frame: lying flat, screen on the +Y (top) face, top edge of the
# screen toward -Z, cartridge slot on the back edge (-Z), video-out on the left.

## Body size in metres (x = width, y = thickness, z = length).
var body_size := Vector3(0.09, 0.032, 0.148)
## Screen quad size (x = width, z = height on the device face).
var screen_size := Vector2(0.047, 0.043)
## Screen centre offset from the body centre, on the top face.
var screen_offset := Vector3(0.0, 0.0, -0.03)
var body_color := Color(0.75, 0.73, 0.70)     # classic DMG grey
var accent_color := Color(0.45, 0.15, 0.45)   # button magenta

var _screen: MeshInstance3D = null
var _power_switch: VRSlider = null
var _volume_slider: VRSlider = null
var _host: Node3D = null

# Optional per-device LCD display filter (e.g. the DMG dot-matrix look). A
# subclass sets _lcd_shader; the base then wraps the built-in screen's material
# with it — the same watch-and-rewrap the TV uses for its CRT, since the C++
# video handler re-asserts its own StandardMaterial3D (emission = picture) each
# frame. Left null → no filter (GBA colour LCD, etc.).
var _lcd_shader: Shader = null
var _lcd_material: ShaderMaterial = null


func is_handheld() -> bool:
	return true


## Keep the LCD filter wrapped over the live core picture. Cheap identity checks
## in the steady state; only re-installs when the source material changes.
func _process(_delta: float) -> void:
	if _lcd_shader == null or _screen == null:
		return
	var override := _screen.get_surface_override_material(0)
	if override == null or override == _lcd_material:
		return
	var tex := _screen_emission_texture(override)
	if tex == null:
		return   # off / no picture — leave the unlit LCD material alone
	if _lcd_material == null:
		_lcd_material = ShaderMaterial.new()
		_lcd_material.shader = _lcd_shader
	_lcd_material.set_shader_parameter("source_tex", tex)
	_screen.set_surface_override_material(0, _lcd_material)


## The live picture texture out of whichever material the core installed (it uses
## an emissive StandardMaterial3D; our own wrapper carries source_tex).
func _screen_emission_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).emission_texture
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	return null


func get_controller_port_count() -> int:
	return 0


func get_builtin_screen() -> MeshInstance3D:
	return _screen


func _ready() -> void:
	_build_shell()


func _build_shell() -> void:
	var half_y := body_size.y / 2.0

	var body := MeshInstance3D.new()
	body.name = "HandheldBody"
	var body_mesh := BoxMesh.new()
	body_mesh.size = body_size
	body.mesh = body_mesh
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body.set_surface_override_material(0, body_mat)
	add_child(body)

	# Screen bezel (slightly recessed dark plate) + the LCD quad on top of it.
	var bezel := MeshInstance3D.new()
	bezel.name = "ScreenBezel"
	var bezel_mesh := BoxMesh.new()
	bezel_mesh.size = Vector3(screen_size.x + 0.012, 0.002, screen_size.y + 0.012)
	bezel.mesh = bezel_mesh
	var bezel_mat := StandardMaterial3D.new()
	bezel_mat.albedo_color = Color(0.12, 0.12, 0.14)
	bezel.set_surface_override_material(0, bezel_mat)
	bezel.position = screen_offset + Vector3(0, half_y + 0.001, 0)
	add_child(bezel)

	_screen = MeshInstance3D.new()
	_screen.name = "HandheldScreen"
	var quad := QuadMesh.new()
	quad.size = screen_size
	_screen.mesh = quad
	# Face up (+Y), screen-top toward -Z.
	_screen.rotation_degrees = Vector3(-90, 0, 0)
	_screen.position = screen_offset + Vector3(0, half_y + 0.0025, 0)
	var off_mat := StandardMaterial3D.new()
	off_mat.albedo_color = Color(0.35, 0.4, 0.33)   # unlit DMG green-grey
	_screen.set_surface_override_material(0, off_mat)
	add_child(_screen)

	# Cosmetic d-pad + A/B buttons on the lower face area.
	_add_cosmetics(half_y)


func _add_cosmetics(half_y: float) -> void:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.15, 0.17)
	var accent := StandardMaterial3D.new()
	accent.albedo_color = accent_color

	# The cosmetic set is sized for a Game Boy face — on narrower bodies
	# (WonderSwan, Pokemon Mini) the fixed button spread hangs off the edge,
	# so scale the d-pad bars, button radius and spread with body width.
	var s := clampf(body_size.x / 0.09, 0.6, 1.0)

	# Classic Game Boy layout: d-pad lower-left, A/B lower-right, below the
	# screen. On landscape bodies (GBA / Lynx / NGP / PSP) that lands on the
	# screen bezel — flank the screen instead (d-pad left, buttons right,
	# centred on it), like the real hardware.
	var dpad_pos := Vector3(-body_size.x * 0.28, half_y + 0.002, body_size.z * 0.28)
	var btn_base := Vector3(body_size.x * 0.22, half_y + 0.002, body_size.z * 0.30)
	var btn_offsets := [Vector3(0, 0, 0), Vector3(0.017 * s, 0, -0.010 * s)]
	if _hits_screen_bezel(dpad_pos, 0.014) or _hits_screen_bezel(btn_base, 0.014):
		var side := (body_size.x / 2.0 + (screen_size.x + 0.012) / 2.0) / 2.0
		dpad_pos = Vector3(-side, half_y + 0.002, screen_offset.z)
		btn_base = Vector3(side, half_y + 0.002, screen_offset.z)
		btn_offsets = [Vector3(0.006, 0, -0.006), Vector3(-0.006, 0, 0.006)]

	for horizontal in [true, false]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.024 * s, 0.004, 0.008 * s) if horizontal \
			else Vector3(0.008 * s, 0.004, 0.024 * s)
		bar.mesh = bar_mesh
		bar.set_surface_override_material(0, dark)
		bar.position = dpad_pos
		add_child(bar)

	for i in range(2):
		var btn := MeshInstance3D.new()
		var btn_mesh := CylinderMesh.new()
		btn_mesh.top_radius = 0.006 * s
		btn_mesh.bottom_radius = 0.006 * s
		btn_mesh.height = 0.004
		btn.mesh = btn_mesh
		btn.set_surface_override_material(0, accent)
		btn.position = btn_base + btn_offsets[i]
		add_child(btn)


## True when a cosmetic centred at `p` (half-extent `half`) would land on the
## screen bezel footprint on the top face.
func _hits_screen_bezel(p: Vector3, half: float) -> bool:
	return absf(p.x - screen_offset.x) < (screen_size.x + 0.012) / 2.0 + half \
		and absf(p.z - screen_offset.z) < (screen_size.y + 0.012) / 2.0 + half


## Reposition the cartridge slot to the back edge of the device.
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.position = Vector3(0, 0, -body_size.z / 2.0 - 0.01)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false


## Cartridges slide in from behind the device.
func get_cartridge_insert_direction() -> Vector3:
	return Vector3(0, 0, -1)


## Video-out port on the rear edge (the Super Game Boy fantasy), offset to the
## side of the centred cartridge slot so the two plugs don't overlap.
func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.position = Vector3(body_size.x * 0.30, 0, -body_size.z / 2.0 - 0.002)
	# The scene's console-scale grey port barrel dwarfs a handheld shell —
	# hide it (the cable itself marks the port).
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false


## Shrink the root collision box to the device and hide the console body.
## Called by RetroSystem after the model loads.
func configure_handheld_body(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		# The .tscn sub-resource is shared across instances — duplicate first.
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = body_size + Vector3(0.01, 0.01, 0.01)
		col.position = Vector3.ZERO
	var body := host.get_node_or_null("SystemBody") as MeshInstance3D
	if body:
		body.visible = false
	# The selection PointerArea keeps its console-sized box otherwise — a huge
	# invisible pointable slab that the desktop reticle / VR laser hits FIRST,
	# shadowing every on-device control (power switch, volume slider, START
	# button, touch screen). Shrink it to the body so controls, which all poke
	# out of the shell, win the raycast.
	var pcol := host.get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol and pcol.shape is BoxShape3D:
		pcol.shape = pcol.shape.duplicate()
		(pcol.shape as BoxShape3D).size = body_size
		pcol.position = Vector3.ZERO


## On-device controls: volume slider (right edge) + power switch (top edge).
func configure_handheld_controls(host: Node3D) -> void:
	_host = host
	_build_volume_slider()
	_build_power_switch()


func _build_volume_slider() -> void:
	var half_y := body_size.y / 2.0
	_volume_slider = _make_slider("VolumeSlider", 0, 1.0)
	_volume_slider.axis_local = Vector3(0, 0, 1)
	_volume_slider.travel = 0.022
	_volume_slider.position = Vector3(body_size.x / 2.0 + 0.002, half_y * 0.4, body_size.z * 0.18)
	add_child(_volume_slider)
	_volume_slider.value_changed.connect(func(v: float) -> void:
		if _host and _host.has_method("set_audio_volume"):
			_host.set_audio_volume(v))


func _build_power_switch() -> void:
	var half_y := body_size.y / 2.0
	_power_switch = _make_slider("PowerSwitch", 2, 0.0)
	_power_switch.axis_local = Vector3(1, 0, 0)
	_power_switch.travel = 0.016
	_power_switch.position = Vector3(-body_size.x * 0.25, half_y + 0.003, -body_size.z / 2.0 + 0.008)
	add_child(_power_switch)
	# Label the switch so players can find how to power the system on/off — it's a
	# small knob on the top edge that's otherwise easy to miss.
	var power_label := Label3D.new()
	power_label.text = "POWER"
	power_label.pixel_size = 0.00022
	power_label.font_size = 16
	power_label.modulate = Color(0.1, 0.1, 0.12)
	power_label.rotation_degrees = Vector3(-90, 0, 0)   # lie flat, readable from above
	power_label.position = Vector3(_power_switch.position.x, half_y + 0.0035, _power_switch.position.z + 0.016)
	add_child(power_label)
	_power_switch.value_changed.connect(func(v: float) -> void:
		if _host == null or not _host.has_method("toggle_power"):
			return
		var want_on := v > 0.5
		if want_on != bool(_host.get("is_powered_on")):
			_host.toggle_power())


func _make_slider(slider_name: String, steps: int, initial: float) -> VRSlider:
	var slider := VRSlider.new()
	slider.name = slider_name
	slider.steps = steps
	slider.engage_radius = 0.028

	var knob := MeshInstance3D.new()
	knob.name = "KnobMesh"
	var knob_mesh := BoxMesh.new()
	knob_mesh.size = Vector3(0.008, 0.006, 0.008)
	knob.mesh = knob_mesh
	var knob_mat := StandardMaterial3D.new()
	knob_mat.albedo_color = Color(0.2, 0.2, 0.22)
	knob.set_surface_override_material(0, knob_mat)
	slider.add_child(knob)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.03, 0.015, 0.03)
	col.shape = shape
	slider.add_child(col)

	slider.set_value_no_signal(initial)
	return slider


## Reflect externally-driven power changes (e.g. cart removal powers off, or a
## multiplayer event) back onto the switch position, and apply the volume
## slider's current position to the freshly-created audio player.
func on_power_on() -> void:
	if _power_switch:
		_power_switch.set_value_no_signal(1.0)
	if _volume_slider and _host and _host.has_method("set_audio_volume"):
		_host.set_audio_volume(_volume_slider.value)


func on_power_off() -> void:
	if _power_switch:
		_power_switch.set_value_no_signal(0.0)
	# Unlit LCD look returns automatically when the core releases the material.