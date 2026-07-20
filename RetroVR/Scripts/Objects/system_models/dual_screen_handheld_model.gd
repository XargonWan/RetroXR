## RetroSystemModelDualScreen — clamshell dual-screen handhelds (DS / 3DS).
##
## Dual-screen cores render BOTH screens into one composite framebuffer
## (melonDS top/bottom stacked 256×384; patched azahar side-by-side stereo
## 400×480). The C++ VideoHandler drives ONE mesh — a hidden proxy quad
## (the Virtual Boy pattern) — and this model feeds the proxy's emission
## texture into a screen_window ShaderMaterial per visible screen quad:
##   * each quad's `source_rect` selects its region of the composite, and
##   * a stereo top screen (3DS) adds `eye_shift` so the RIGHT eye samples the
##     right-eye half (VIEW_INDEX) — real depth in the headset.
##
## The visible shell — base, hinged lid, both screens + bezels, the touch area,
## the hidden proxy quad, the grabbable lid hinge, cosmetics, and the volume
## slider — is authored in the per-device scene (nds.tscn / n3ds.tscn). This
## script caches those nodes, builds the two window ShaderMaterials at runtime
## (source_tex is live core output — it can only be bound per-frame), feeds the
## screens, and handles touch input.
##
## Video-out: TWO cables (get_video_channels), TOP and BOTTOM, each with its
## own labelled port on the back edge. RetroSystem mirrors the same proxy
## texture onto each connected TV through the same shader, and taps on the
## BOTTOM TV feed the touch screen.
##
## Subclasses set the composite UV rects + stereo eye_shift in _init.
class_name RetroSystemModelDualScreen
extends RetroSystemModelHandheld

const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

# Base local frame is the handheld convention: flat, top face +Y, hinge/back
# edge -Z. The lid pivots at the back-top edge (LidPivot, authored in the scene).

## Physical bottom-screen size in metres — read back from the authored
## BottomScreen quad; drives the touch-area UV mapping.
var bottom_screen_size := Vector2(0.061, 0.0457)
## Each screen's region of the composite core framebuffer (set in subclass _init).
var top_uv_rect := Rect2(0.0, 0.0, 1.0, 0.5)
var bottom_uv_rect := Rect2(0.0, 0.5, 1.0, 0.5)
## Right-eye UV-x shift for a stereo side-by-side composite (3DS azahar).
## 0 = mono core output (DS).
var top_eye_shift := 0.0

var _bottom_screen: MeshInstance3D = null
var _lid_pivot: Node3D = null
# Grabbable lid hinge. The lid's rotation about X lives on _lid_pivot (0 = flat /
# 180° interior open, 180 = folded shut); the public angle (get/set_lid_angle_deg)
# is the interior open angle, 180 minus that rotation.
var _hinge: VRHinge = null
var _touch: Area3D = null
# Hidden proxy quad the C++ VideoHandler renders the composite into.
var _proxy: MeshInstance3D = null
# screen_window materials feeding each quad from the proxy's texture.
var _top_mat: ShaderMaterial = null
var _bottom_mat: ShaderMaterial = null
# Unlit-LCD materials shown while no core picture exists (authored on the quads).
var _top_off_mat: StandardMaterial3D = null
var _bottom_off_mat: StandardMaterial3D = null
# VR fingertip touch state (per engaged controller).
var _touch_ctrl: XRController3D = null
var _touch_pointer_down := false
var _touch_controllers: Array[XRController3D] = []


## Measure only the base (bottom clamshell half) when placing the system name
## label, so it lands on the base's front — the same +Z face the START button
## sits on — rather than over the raised lid / top screen. (Used by
## RetroSystem._body_aabb / _place_name_label.)
func name_label_body() -> Node3D:
	return get_node_or_null("HandheldBody")


## Upright on the base's vertical front (+Z) face (where the START button is),
## centred and filling most of the thin base height — not flat on the top.
func name_label_placement() -> Dictionary:
	return {"upright": true, "v_center": 0.5, "h_frac": 0.72}


func _ready() -> void:
	_cache_dual_nodes()
	# Window materials, ready before the first frame of core output.
	_top_mat = ShaderMaterial.new()
	_top_mat.shader = SCREEN_WINDOW_SHADER
	_bottom_mat = ShaderMaterial.new()
	_bottom_mat.shader = SCREEN_WINDOW_SHADER
	_apply_window_params()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_touch_controllers.append(node as XRController3D)


## Cache the authored shell nodes and read the dimensions the runtime logic needs.
func _cache_dual_nodes() -> void:
	_lid_pivot = get_node_or_null("LidPivot")
	_screen = get_node_or_null("LidPivot/TopScreen") as MeshInstance3D
	_bottom_screen = get_node_or_null("BottomScreen") as MeshInstance3D
	_proxy = get_node_or_null("ProxyScreen") as MeshInstance3D
	_touch = get_node_or_null("TouchScreen") as Area3D
	_hinge = get_node_or_null("LidPivot/LidHinge") as VRHinge
	_volume_slider = get_node_or_null("VolumeSlider") as VRSlider
	var body := get_node_or_null("HandheldBody") as MeshInstance3D
	if body and body.mesh is BoxMesh:
		body_size = (body.mesh as BoxMesh).size
	if _bottom_screen and _bottom_screen.mesh is QuadMesh:
		bottom_screen_size = (_bottom_screen.mesh as QuadMesh).size
	if _screen:
		_top_off_mat = _screen.get_surface_override_material(0) as StandardMaterial3D
	if _bottom_screen:
		_bottom_off_mat = _bottom_screen.get_surface_override_material(0) as StandardMaterial3D


## Interior open angle in degrees: 0 = folded shut, 180 = flat open.
func get_lid_angle_deg() -> float:
	return 180.0 - rad_to_deg(_lid_pivot.rotation.x) if _lid_pivot else 180.0


## Set the interior open angle (0 shut … 180 flat).
func set_lid_angle_deg(open_deg: float) -> void:
	var rot := clampf(180.0 - open_deg, 0.0, 180.0)
	if _hinge:
		_hinge.set_rotation_deg_no_signal(rot)
	elif _lid_pivot:
		_lid_pivot.rotation.x = deg_to_rad(rot)


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


## Two labelled video-out ports on the back edge, beside the cartridge slot:
## TOP on the right, BOTTOM on the left.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	var x := body_size.x * (0.30 if channel == 0 else -0.30)
	attach_point.position = Vector3(x, 0, -body_size.z / 2.0 - 0.002)
	# Channel 0 is the scene's CableAttachPoint, which carries the console's
	# grey barrel PortVisual — out of scale on a handheld (the extra channels'
	# points are bare Node3Ds), so hide it and let the labels mark the ports.
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false
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
## when it leaves (with hysteresis, VRSlider-style). Hands HOLDING the device
## never count — a gripping hand's tip hovers near the pad permanently and
## would otherwise lock the touch (streaming a stuck press and blocking the
## free hand from poking).
func _process_fingertip_touch() -> void:
	if _touch == null or _touch_pointer_down:
		return
	if _touch_ctrl != null:
		if not is_instance_valid(_touch_ctrl) or not _touch_ctrl.get_is_active() \
				or _is_holding_hand(_touch_ctrl) \
				or not _tip_on_screen(PokeTip.tip_of(_touch_ctrl), 1.6):
			var last := _touch_ctrl
			_touch_ctrl = null
			if is_instance_valid(last):
				_send_touch(PokeTip.tip_of(last), false)
		else:
			_send_touch(PokeTip.tip_of(_touch_ctrl), true)
			return
	for ctrl in _touch_controllers:
		if ctrl and ctrl.get_is_active() and not _is_holding_hand(ctrl) \
				and _tip_on_screen(PokeTip.tip_of(ctrl), 1.0):
			_touch_ctrl = ctrl
			_send_touch(PokeTip.tip_of(ctrl), true)
			return


## True when this controller's hand is currently gripping the device.
func _is_holding_hand(ctrl: XRController3D) -> bool:
	if _host == null:
		return false
	var driver: Variant = _host.get("_grab_driver")
	if driver == null:
		return false
	if driver.primary and driver.primary.controller == ctrl:
		return true
	if driver.secondary and driver.secondary.controller == ctrl:
		return true
	return false


func _tip_on_screen(world_pos: Vector3, slack: float) -> bool:
	var local := _touch.to_local(world_pos)
	return absf(local.y) <= 0.01 * slack \
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
