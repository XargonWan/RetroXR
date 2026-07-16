## RetroSystemModelDualScreen — clamshell dual-screen handhelds (DS / 3DS).
##
## Dual-screen cores render BOTH screens into one composite framebuffer
## (melonDS top/bottom stacked 256×384; patched azahar side-by-side stereo
## 400×480). The C++ VideoHandler drives ONE mesh — here a hidden proxy quad
## (the Virtual Boy pattern) — and this model feeds the proxy's emission
## texture into a screen_window ShaderMaterial per visible screen quad:
##   * each quad's `source_rect` selects its region of the composite, and
##   * a stereo top screen (3DS) adds `eye_shift` so the RIGHT eye samples the
##     right-eye half (VIEW_INDEX) — real depth in the headset.
##
## Video-out: TWO cables (get_video_channels), TOP and BOTTOM, each with its
## own labelled port on the back edge. RetroSystem mirrors the same proxy
## texture onto each connected TV through the same shader, and taps on the
## BOTTOM TV feed the touch screen.
##
## The bottom screen is a touch screen: an Area3D over it accepts desktop
## pointer press/drag AND VR fingertip pokes, converts the hit to composite-
## framebuffer UV and feeds host.feed_touch() → RETRO_DEVICE_POINTER (which is
## how melonDS/citra take touch input).
##
## Clamshells keep the cabinet START/STOP button (has_start_stop_button):
## the tiny back-edge power knob other handhelds use would be swallowed by the
## hinge, so configure_buttons shrinks the button and mounts it on the front
## edge instead.
##
## Subclasses set body/screen dimensions and the UV rects in _init.
class_name RetroSystemModelDualScreen
extends RetroSystemModelHandheld

const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

# Base local frame is the handheld convention: flat, top face +Y, hinge/back
# edge -Z. The lid pivots at the back-top edge; interior angle `lid_open_deg`.

## Lid (top screen half) size: x = width, y = thickness, z = length.
var lid_size := Vector3(0.133, 0.011, 0.0739)
## Interior clamshell angle in degrees (180 = flat open).
var lid_open_deg := 110.0
## Physical screen sizes in metres (width × height on the panel face).
var top_screen_size := Vector2(0.061, 0.0457)
var bottom_screen_size := Vector2(0.061, 0.0457)
## Screen centre offsets: top on the lid interior (x, along-lid), bottom on
## the base top face (x, z).
var top_screen_offset := Vector2(0.0, 0.0)
var bottom_screen_offset := Vector2(0.0, 0.0)
## Each screen's region of the composite core framebuffer.
var top_uv_rect := Rect2(0.0, 0.0, 1.0, 0.5)
var bottom_uv_rect := Rect2(0.0, 0.5, 1.0, 0.5)
## Right-eye UV-x shift for a stereo side-by-side composite (3DS azahar).
## 0 = mono core output (DS).
var top_eye_shift := 0.0

var _bottom_screen: MeshInstance3D = null
var _lid_pivot: Node3D = null
var _touch: Area3D = null
# Hidden proxy quad the C++ VideoHandler renders the composite into.
var _proxy: MeshInstance3D = null
# screen_window materials feeding each quad from the proxy's texture.
var _top_mat: ShaderMaterial = null
var _bottom_mat: ShaderMaterial = null
# Unlit-LCD materials shown while no core picture exists.
var _top_off_mat: StandardMaterial3D = null
var _bottom_off_mat: StandardMaterial3D = null
# VR fingertip touch state (per engaged controller).
var _touch_ctrl: XRController3D = null
var _touch_pointer_down := false
var _touch_controllers: Array[XRController3D] = []


func _build_shell() -> void:
	var half_y := body_size.y / 2.0
	var off_mat := StandardMaterial3D.new()
	off_mat.albedo_color = Color(0.05, 0.05, 0.06)   # dark, unlit LCD
	_top_off_mat = off_mat
	_bottom_off_mat = off_mat.duplicate()

	# Window materials, ready before the first frame of core output.
	_top_mat = ShaderMaterial.new()
	_top_mat.shader = SCREEN_WINDOW_SHADER
	_bottom_mat = ShaderMaterial.new()
	_bottom_mat.shader = SCREEN_WINDOW_SHADER
	_apply_window_params()

	# ── Base (bottom half) ────────────────────────────────────────────────────
	var base := MeshInstance3D.new()
	base.name = "HandheldBody"
	var base_mesh := BoxMesh.new()
	base_mesh.size = body_size
	base.mesh = base_mesh
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	base.set_surface_override_material(0, body_mat)
	add_child(base)

	# ── Lid, hinged at the back-top edge ──────────────────────────────────────
	_lid_pivot = Node3D.new()
	_lid_pivot.name = "LidPivot"
	_lid_pivot.position = Vector3(0, half_y, -body_size.z / 2.0)
	# Panel extends -Z at 0°; rotating +X tips it up. Interior angle =
	# 180° - rotation, so rotation = 180 - lid_open_deg.
	_lid_pivot.rotation_degrees = Vector3(180.0 - lid_open_deg, 0, 0)
	add_child(_lid_pivot)

	var lid := MeshInstance3D.new()
	lid.name = "Lid"
	var lid_mesh := BoxMesh.new()
	lid_mesh.size = lid_size
	lid.mesh = lid_mesh
	lid.set_surface_override_material(0, body_mat)
	lid.position = Vector3(0, lid_size.y / 2.0, -lid_size.z / 2.0)
	_lid_pivot.add_child(lid)

	# ── Top screen (lid interior face) ────────────────────────────────────────
	var top_bezel := MeshInstance3D.new()
	top_bezel.name = "TopBezel"
	var tb_mesh := BoxMesh.new()
	tb_mesh.size = Vector3(top_screen_size.x + 0.008, 0.0015, top_screen_size.y + 0.008)
	top_bezel.mesh = tb_mesh
	var bezel_mat := StandardMaterial3D.new()
	bezel_mat.albedo_color = Color(0.10, 0.10, 0.12)
	top_bezel.set_surface_override_material(0, bezel_mat)
	top_bezel.position = Vector3(top_screen_offset.x, lid_size.y + 0.0008,
		-lid_size.z / 2.0 + top_screen_offset.y)
	_lid_pivot.add_child(top_bezel)

	_screen = MeshInstance3D.new()
	_screen.name = "TopScreen"
	var top_quad := QuadMesh.new()
	top_quad.size = top_screen_size
	_screen.mesh = top_quad
	_screen.rotation_degrees = Vector3(-90, 0, 0)   # face lid-interior (+Y local)
	_screen.position = Vector3(top_screen_offset.x, lid_size.y + 0.002,
		-lid_size.z / 2.0 + top_screen_offset.y)
	_screen.set_surface_override_material(0, _top_off_mat)
	_lid_pivot.add_child(_screen)

	# ── Bottom screen (base top face) + touch area ────────────────────────────
	var bot_bezel := MeshInstance3D.new()
	bot_bezel.name = "BottomBezel"
	var bb_mesh := BoxMesh.new()
	bb_mesh.size = Vector3(bottom_screen_size.x + 0.008, 0.0015, bottom_screen_size.y + 0.008)
	bot_bezel.mesh = bb_mesh
	bot_bezel.set_surface_override_material(0, bezel_mat)
	bot_bezel.position = Vector3(bottom_screen_offset.x, half_y + 0.0008, bottom_screen_offset.y)
	add_child(bot_bezel)

	_bottom_screen = MeshInstance3D.new()
	_bottom_screen.name = "BottomScreen"
	var bot_quad := QuadMesh.new()
	bot_quad.size = bottom_screen_size
	_bottom_screen.mesh = bot_quad
	_bottom_screen.rotation_degrees = Vector3(-90, 0, 0)
	_bottom_screen.position = Vector3(bottom_screen_offset.x, half_y + 0.002, bottom_screen_offset.y)
	_bottom_screen.set_surface_override_material(0, _bottom_off_mat)
	add_child(_bottom_screen)

	# ── Hidden proxy the C++ VideoHandler renders the composite into ──────────
	_proxy = MeshInstance3D.new()
	_proxy.name = "ProxyScreen"
	var pquad := QuadMesh.new()
	pquad.size = Vector2(0.01, 0.01)
	_proxy.mesh = pquad
	_proxy.position = Vector3(0, half_y, 0)
	_proxy.visible = false
	add_child(_proxy)

	_touch = Area3D.new()
	_touch.name = "TouchScreen"
	_touch.collision_layer |= VRSlider.POINTABLE_LAYER
	var tcol := CollisionShape3D.new()
	var tshape := BoxShape3D.new()
	tshape.size = Vector3(bottom_screen_size.x, 0.006, bottom_screen_size.y)
	tcol.shape = tshape
	_touch.add_child(tcol)
	_touch.position = _bottom_screen.position
	# The interaction resolver walks UP from the hit collider to the first
	# ancestor with pointer_event() — the TouchScreen area has none, so events
	# land on this model's pointer_event below. (VRSliders keep their own.)
	add_child(_touch)

	_add_cosmetics(half_y)


## Clamshell cosmetics: the base handheld's d-pad / A-B placement assumes a
## Game Boy face and lands on the bottom screen. Flank the screen instead —
## d-pad in the left bezel strip, A/B in the right, centred on the screen,
## like the real DS/3DS base.
func _add_cosmetics(half_y: float) -> void:
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.15, 0.15, 0.17)
	var accent := StandardMaterial3D.new()
	accent.albedo_color = accent_color

	var bezel_x := bottom_screen_size.x / 2.0 + 0.006
	# Centre of the free strip between the screen bezel and the body edge.
	var side := (body_size.x / 2.0 + bezel_x) / 2.0
	var z0 := bottom_screen_offset.y

	var dpad_pos := Vector3(-side, half_y + 0.002, z0)
	for horizontal in [true, false]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.02, 0.004, 0.007) if horizontal else Vector3(0.007, 0.004, 0.02)
		bar.mesh = bar_mesh
		bar.set_surface_override_material(0, dark)
		bar.position = dpad_pos
		add_child(bar)

	for i in range(2):
		var btn := MeshInstance3D.new()
		var btn_mesh := CylinderMesh.new()
		btn_mesh.top_radius = 0.005
		btn_mesh.bottom_radius = 0.005
		btn_mesh.height = 0.004
		btn.mesh = btn_mesh
		btn.set_surface_override_material(0, accent)
		btn.position = Vector3(side + (0.006 if i == 0 else -0.006), half_y + 0.002,
			z0 + (-0.006 if i == 0 else 0.006))
		add_child(btn)


## Push the UV windows onto the window materials (rects are set by subclass
## _init, so once at build time is enough).
func _apply_window_params() -> void:
	_top_mat.set_shader_parameter("source_rect",
		Vector4(top_uv_rect.position.x, top_uv_rect.position.y,
			top_uv_rect.size.x, top_uv_rect.size.y))
	_top_mat.set_shader_parameter("eye_shift", top_eye_shift)
	_bottom_mat.set_shader_parameter("source_rect",
		Vector4(bottom_uv_rect.position.x, bottom_uv_rect.position.y,
			bottom_uv_rect.size.x, bottom_uv_rect.size.y))
	_bottom_mat.set_shader_parameter("eye_shift", 0.0)


func _ready() -> void:
	super()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_touch_controllers.append(node as XRController3D)


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden — VideoHandler renders here, the screen quads sample it


## TWO video-out cables: TOP (plain) and BOTTOM (carries touch back to the
## core — tapping the TV showing the bottom screen is tapping the touch screen).
func get_video_channels() -> Array:
	return [
		{"label": "TOP", "rect": top_uv_rect, "touch": false, "eye_shift": top_eye_shift},
		{"label": "BOTTOM", "rect": bottom_uv_rect, "touch": true, "eye_shift": 0.0},
	]


## Clamshells keep the labelled START/STOP cabinet button (see configure_buttons).
func has_start_stop_button() -> bool:
	return true


## The composite picture texture currently on the proxy, or null when off.
func _proxy_texture() -> Texture2D:
	if _proxy == null:
		return null
	var mat := _proxy.get_surface_override_material(0)
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).emission_texture
	return null


func _process(_delta: float) -> void:
	# Feed both screen quads from whatever emission texture the VideoHandler
	# put on the proxy (copy-on-change identity checks, VB-eyepiece style).
	var tex := _proxy_texture()
	if tex != null:
		if _top_mat.get_shader_parameter("source_tex") != tex:
			_top_mat.set_shader_parameter("source_tex", tex)
			_bottom_mat.set_shader_parameter("source_tex", tex)
		if _screen.get_surface_override_material(0) != _top_mat:
			_screen.set_surface_override_material(0, _top_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_mat)
	else:
		if _screen.get_surface_override_material(0) != _top_off_mat:
			_screen.set_surface_override_material(0, _top_off_mat)
			_bottom_screen.set_surface_override_material(0, _bottom_off_mat)

	_process_fingertip_touch()


## Shrink the cabinet power button to handheld scale and mount it on the front
## edge of the base, facing the player, with its START/STOP label under it.
## (RetroSystem keeps this button visible because has_start_stop_button().)
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	power_btn.position = Vector3(body_size.x * 0.36, 0, body_size.z / 2.0 + 0.002)
	power_btn.trigger_radius = 0.015
	power_btn.depress_depth = 0.002
	power_btn.depress_axis = Vector3(0, 0, -1)

	var col := power_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.016, 0.016, 0.008)

	var small := MeshInstance3D.new()
	small.name = "HandheldPowerMesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.005
	cyl.bottom_radius = 0.006
	cyl.height = 0.005
	small.mesh = cyl
	small.rotation_degrees = Vector3(90, 0, 0)   # cylinder axis out of the front face
	power_btn.add_child(small)
	# Re-caches the depress origin and hides the console-scale ButtonMesh.
	power_btn.set_button_mesh(small)

	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.transform = Transform3D.IDENTITY
		lbl.position = Vector3(0, -0.0105, 0.002)
		lbl.pixel_size = 0.0004
		lbl.font_size = 12


## On-device controls: volume slider only. The back-edge power knob the other
## handhelds get would sit inside the hinge — the START/STOP button replaces it.
func configure_handheld_controls(host: Node3D) -> void:
	_host = host
	_build_volume_slider()


## Two labelled video-out ports on the back edge, beside the cartridge slot:
## TOP on the right, BOTTOM on the left.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	var x := body_size.x * (0.30 if channel == 0 else -0.30)
	attach_point.position = Vector3(x, 0, -body_size.z / 2.0 - 0.002)
	_add_port_label("TOP" if channel == 0 else "BOTTOM", x)


func _add_port_label(text: String, x: float) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.pixel_size = 0.00018
	lbl.font_size = 16
	lbl.modulate = Color(0.92, 0.92, 0.94)
	lbl.outline_size = 4
	# On the back face, reading correctly from behind the device.
	lbl.rotation_degrees = Vector3(0, 180, 0)
	lbl.position = Vector3(x, body_size.y * 0.16, -body_size.z / 2.0 - 0.0015)
	add_child(lbl)


# ── Touch screen ──────────────────────────────────────────────────────────────

## Desktop reticle / VR laser events forwarded from the TouchScreen Area3D.
func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.PRESSED:
			_touch_pointer_down = true
			_send_touch(event.position, true)
		XRToolsPointerEvent.Type.MOVED:
			if _touch_pointer_down:
				_send_touch(event.position, true)
		XRToolsPointerEvent.Type.RELEASED, XRToolsPointerEvent.Type.EXITED:
			if _touch_pointer_down:
				_touch_pointer_down = false
				_send_touch(event.position, false)


## VR fingertip: a controller tip hovering just above the bottom screen is a
## stylus. Engage within the pad's bounds + a small height window; release
## when it leaves (with hysteresis, VRSlider-style).
func _process_fingertip_touch() -> void:
	if _touch == null or _touch_pointer_down:
		return
	if _touch_ctrl != null:
		if not is_instance_valid(_touch_ctrl) or not _touch_ctrl.get_is_active() \
				or not _tip_on_screen(PokeTip.tip_of(_touch_ctrl), 1.6):
			var last := _touch_ctrl
			_touch_ctrl = null
			if is_instance_valid(last):
				_send_touch(PokeTip.tip_of(last), false)
		else:
			_send_touch(PokeTip.tip_of(_touch_ctrl), true)
			return
	for ctrl in _touch_controllers:
		if ctrl and ctrl.get_is_active() and _tip_on_screen(PokeTip.tip_of(ctrl), 1.0):
			_touch_ctrl = ctrl
			_send_touch(PokeTip.tip_of(ctrl), true)
			return


func _tip_on_screen(world_pos: Vector3, slack: float) -> bool:
	var local := _touch.to_local(world_pos)
	return absf(local.y) <= 0.025 * slack \
		and absf(local.x) <= bottom_screen_size.x / 2.0 + 0.005 * slack \
		and absf(local.z) <= bottom_screen_size.y / 2.0 + 0.005 * slack


## World point on/over the bottom screen → composite-framebuffer UV → host.
func _send_touch(world_pos: Vector3, pressed: bool) -> void:
	if _host == null or not _host.has_method("feed_touch"):
		return
	var local := _touch.to_local(world_pos)
	var fx := clampf(local.x / bottom_screen_size.x + 0.5, 0.0, 1.0)
	var fy := clampf(local.z / bottom_screen_size.y + 0.5, 0.0, 1.0)
	_host.feed_touch(bottom_uv_rect.position + Vector2(fx, fy) * bottom_uv_rect.size, pressed)
