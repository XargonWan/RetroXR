## RetroSystemModelDualScreen — clamshell dual-screen handhelds (DS / 3DS).
##
## Dual-screen cores render BOTH screens into one composite framebuffer
## (melonDS top/bottom stacked 256×384; citra/azahar default 400×480 with the
## bottom screen centered). The C++ VideoHandler drives ONE mesh — the top
## screen — with a single persistent emission material. The trick:
##   * each screen quad is a QuadMesh whose UVs are remapped to its region of
##     the composite framebuffer (`_make_uv_quad`), and
##   * the model mirrors the top quad's surface-0 material onto the bottom
##     quad each frame (cheap pointer compare), so both screens light up from
##     the one core texture with zero extra copies.
##
## The bottom screen is a touch screen: an Area3D over it accepts desktop
## pointer press/drag AND VR fingertip pokes, converts the hit to composite-
## framebuffer UV and feeds host.feed_touch() → RETRO_DEVICE_POINTER (which is
## how melonDS/citra take touch input).
##
## Subclasses set body/screen dimensions and the UV rects in _init.
class_name RetroSystemModelDualScreen
extends RetroSystemModelHandheld

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

var _bottom_screen: MeshInstance3D = null
var _lid_pivot: Node3D = null
var _touch: Area3D = null
# VR fingertip touch state (per engaged controller).
var _touch_ctrl: XRController3D = null
var _touch_pointer_down := false
var _touch_controllers: Array[XRController3D] = []


## Build a QuadMesh remapped so its UVs cover `uv_rect` of the texture instead
## of the full [0,1] range — geometry/winding/normals identical to QuadMesh.
static func _make_uv_quad(size: Vector2, uv_rect: Rect2) -> ArrayMesh:
	var q := QuadMesh.new()
	q.size = size
	var arrays := q.surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	for i in uvs.size():
		uvs[i] = uv_rect.position + uvs[i] * uv_rect.size
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


func _build_shell() -> void:
	var half_y := body_size.y / 2.0
	var off_mat := StandardMaterial3D.new()
	off_mat.albedo_color = Color(0.05, 0.05, 0.06)   # dark, unlit LCD

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

	# ── Top screen (lid interior face) — the mesh VideoHandler drives ─────────
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
	_screen.mesh = _make_uv_quad(top_screen_size, top_uv_rect)
	_screen.rotation_degrees = Vector3(-90, 0, 0)   # face lid-interior (+Y local)
	_screen.position = Vector3(top_screen_offset.x, lid_size.y + 0.002,
		-lid_size.z / 2.0 + top_screen_offset.y)
	_screen.set_surface_override_material(0, off_mat)
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
	_bottom_screen.mesh = _make_uv_quad(bottom_screen_size, bottom_uv_rect)
	_bottom_screen.rotation_degrees = Vector3(-90, 0, 0)
	_bottom_screen.position = Vector3(bottom_screen_offset.x, half_y + 0.002, bottom_screen_offset.y)
	_bottom_screen.set_surface_override_material(0, off_mat.duplicate())
	add_child(_bottom_screen)

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


func _ready() -> void:
	super()
	await get_tree().process_frame
	for node in get_tree().root.find_children("*", "XRController3D", true, false):
		_touch_controllers.append(node as XRController3D)


func get_builtin_screen() -> MeshInstance3D:
	return _screen   # top screen — VideoHandler's target


func _process(_delta: float) -> void:
	# Mirror the top screen's material onto the bottom quad: the C++
	# VideoHandler owns the top's surface-0 override; the bottom shows the
	# same material through its own UV window into the composite framebuffer.
	if _screen and _bottom_screen:
		var m := _screen.get_surface_override_material(0)
		if _bottom_screen.get_surface_override_material(0) != m:
			_bottom_screen.set_surface_override_material(0, m)

	_process_fingertip_touch()


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
