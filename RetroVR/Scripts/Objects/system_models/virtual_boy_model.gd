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
## Not a handheld: one controller port, and the video-out cable works too. The
## TV does NOT get the raw side-by-side frame (which reads as two squashed
## copies) — get_video_channels() hands it the LEFT half plus eye_shift 0.5, so
## screen_window.gdshader samples the right half for the right eye and a
## connected TV comes out in stereo as well. Same mechanism the 3DS top screen
## uses; the console is stereo end to end.
##
## Detailed shell (an author imported) when imported-assets/virtual_boy.glb ships;
## the primitive bipod authored in virtual_boy.tscn is the store-safe fallback.
class_name RetroSystemModelVirtualBoy
extends RetroSystemModel

const STEREO_SHADER := preload("res://Shaders/vb_stereo.gdshader")
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")
const _MODEL_PATH := "res://imported-assets/virtual_boy.glb"

## The shell is authored with its EYEPIECES on -Z and its cart slot / A/V out on
## +Z — backwards from the framework's "front is +Z". Yaw it so the lenses face
## the player and the sockets end up round the back.
const _SHELL_YAW := PI
## Bundled A/V lead; RetroVR spawns its own cable.
const _HIDE := ["RCA_Red"]
## The GLB's own opaque lens panes, replaced by the live stereo eyepiece.
const _LENS := ["screen_mesh", "screen_mesh (1)"]

# Visor ~220×110×95 mm on a ~250 mm stand, red-on-black like the hardware.
const VISOR_SIZE := Vector3(0.22, 0.11, 0.095)
const STAND_H := 0.25
## Eyepiece view: one eye's 384×224 image (12:7).
const EYE_SIZE := Vector2(0.132, 0.077)

var _glb: Node3D = null
var _proxy: MeshInstance3D = null
var _eyepiece: MeshInstance3D = null
var _stereo_mat: ShaderMaterial = null
## One live quad per PHYSICAL lens: the left pane shows the left-eye half of the
## side-by-side frame and the right pane the right-eye half, exactly like the
## hardware wires its two displays. With your head in the visor each eye lines up
## with its own pane, which is the arrangement the console was built around.
var _lens_quads: Array[MeshInstance3D] = []
var _lens_mats: Array[ShaderMaterial] = []
var _visor_center_y := 0.0

## Screen-cast light: the visor spills the VB's signature red glow when it's
## showing a picture (fixed red — the display is always red-on-black, so no
## per-frame colour sample is needed; energy just tracks picture on/off).
const VB_LIGHT_ENERGY := 0.7
const VB_LIGHT_COLOR := Color(1.0, 0.05, 0.05)
var _vb_light: OmniLight3D = null


## The systemid whose cart dimensions this console takes (MediaDimensions).
func _cart_systemid() -> String:
	return "virtual_boy"


func get_controller_port_count() -> int:
	return 1


func get_builtin_screen() -> MeshInstance3D:
	return _proxy   # hidden — VideoHandler renders here, the eyepiece samples it


func is_stereo_side_by_side() -> bool:
	return true


## A TV fed the raw side-by-side frame shows two squashed copies. Hand it the
## LEFT half and let screen_window.gdshader shift +0.5 for the right eye, so the
## TV is stereo too rather than a flat curiosity.
func get_video_channels() -> Array:
	return [{"label": "", "rect": Rect2(0.0, 0.0, 0.5, 1.0), "touch": false,
		"eye_shift": 0.5}]


func get_forced_core_options() -> Dictionary:
	return {"vb_3dmode": "side-by-side", "vb_sidebyside_separation": "0"}


func _ready() -> void:
	_visor_center_y = STAND_H + VISOR_SIZE.y / 2.0
	# The stand / visor / eye-shade / eyepiece / hidden proxy are authored in
	# virtual_boy.tscn; cache the two functional nodes.
	_proxy = get_node_or_null("ProxyScreen") as MeshInstance3D
	_eyepiece = get_node_or_null("Eyepiece") as MeshInstance3D
	# The eyepiece's live stereo material is per-instance (source_tex is bound
	# per-frame from the proxy), so build it here rather than sharing one packed
	# sub-resource across every Virtual Boy in the room.
	_stereo_mat = ShaderMaterial.new()
	_stereo_mat.shader = STEREO_SHADER
	if _eyepiece:
		_eyepiece.set_surface_override_material(0, _stereo_mat)
	_upgrade_to_glb()
	# Red visor glow, parented to the (possibly GLB-repositioned) eyepiece so it
	# spills out the eye-shade toward the viewer. Off until a picture is present.
	if _eyepiece:
		_vb_light = OmniLight3D.new()
		_vb_light.name = "ScreenCastLight"
		_vb_light.light_color = VB_LIGHT_COLOR
		_vb_light.omni_range = 0.5
		_vb_light.omni_attenuation = 1.5
		_vb_light.shadow_enabled = false
		_vb_light.light_energy = 0.0
		_vb_light.position = Vector3(0.0, 0.0, -0.05)
		_eyepiece.add_child(_vb_light)


## Swap the primitive bipod for the detailed shell. The functional nodes stay
## authoritative — the hidden proxy the VideoHandler renders into, and the live
## stereo eyepiece — but the eyepiece is moved onto the real lens aperture and
## the GLB's own opaque panes are hidden behind it.
func _upgrade_to_glb() -> void:
	if not ResourceLoader.exists(_MODEL_PATH):
		return
	var ps := load(_MODEL_PATH) as PackedScene
	if ps == null:
		return
	_glb = ps.instantiate() as Node3D
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	_glb.basis = Basis(Vector3.UP, _SHELL_YAW)
	add_child(_glb)
	for nm in _HIDE:
		var e := _glb.find_child(nm, true, false) as Node3D
		if e != null:
			e.visible = false
	# Rest the shell on the floor and centre it in X/Z, measured AFTER the yaw.
	var ab := _glb_aabb()
	_glb.position = Vector3(-ab.get_center().x, -ab.position.y, -ab.get_center().z)
	# Hide the primitive stand-ins now the real shell is in.
	for nm in ["StandBase", "StandColumn", "Visor", "EyeShade"]:
		var ph := get_node_or_null(nm) as MeshInstance3D
		if ph != null:
			ph.hide()
	_place_eyepiece()
	_place_volume_wheel()


func _glb_aabb() -> AABB:
	var acc := AABB()
	var first := true
	for n in _glb.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return acc


## Put the live stereo quad across BOTH lens apertures and retire the GLB panes.
##
## One quad rather than one per lens: in VR each eye sees both physical lenses
## (there is no head-in-a-vice divider), so a per-lens image would be shown to
## both eyes. A single quad sampled by VIEW_INDEX gives each eye its own half —
## correct stereo without needing the barrier the real hardware relies on.
## The volume thumbwheel, split out of the body mesh in Blender (the shell ships
## it welded into "Virtual Boy1"). Turning it drives the console's audio volume
## and spins the wheel itself, so the one control the head unit really does have
## actually works.
const _VOL_SWEEP_DEG := 70.0

var _vol_wheel: MeshInstance3D = null
var _vol_rest: Transform3D
var _vol_slider: VRSlider = null


func _place_volume_wheel() -> void:
	if _glb == null:
		return
	_vol_wheel = _glb.find_child("VolumeWheel", true, false) as MeshInstance3D
	_vol_slider = get_node_or_null("VolumeSlider") as VRSlider
	if _vol_wheel == null or _vol_slider == null:
		return
	_vol_rest = _vol_wheel.transform
	var ab: AABB = (global_transform.affine_inverse() * _vol_wheel.global_transform) * _vol_wheel.get_aabb()
	_vol_slider.global_position = to_global(ab.get_center())
	var knob := _vol_slider.get_node_or_null("KnobMesh") as MeshInstance3D
	if knob != null:
		knob.hide()
	_vol_slider.value_changed.connect(_on_volume)
	_apply_volume(_vol_slider.value)


func _on_volume(v: float) -> void:
	_apply_volume(v)
	var host := get_parent()
	if host != null and host.has_method("set_audio_volume"):
		host.set_audio_volume(v)


## Spin the wheel about its own axle (the mesh's long axis, X) so the ribs
## travel through the slot as the value changes.
func _apply_volume(v: float) -> void:
	if _vol_wheel == null:
		return
	var ab: AABB = _vol_wheel.get_aabb()
	var pivot: Vector3 = _vol_rest * ab.get_center()
	var r := Basis(Vector3.RIGHT, deg_to_rad((v - 0.5) * _VOL_SWEEP_DEG))
	_vol_wheel.transform = Transform3D(r, pivot - r * pivot) * _vol_rest


## World position of a GLB marker empty.
func _marker(nm: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(nm, true, false) as Node3D
	return n.global_position if n != null else global_position


func _place_eyepiece() -> void:
	if _glb == null:
		return
	# The primitive single quad is retired: the shell models both panes, so feed
	# them separately instead of stretching one image across the pair.
	if _eyepiece != null:
		_eyepiece.visible = false
	var lenses: Array[MeshInstance3D] = []
	for nm in _LENS:
		var lens := _glb.find_child(nm, true, false) as MeshInstance3D
		if lens != null and lens.mesh != null:
			lenses.append(lens)
	if lenses.size() < 2:
		return
	# Sort by x so index 0 is the player's LEFT pane. Facing the console (the
	# player stands at +Z looking down -Z), the player's left is -X.
	lenses.sort_custom(func(a: MeshInstance3D, b: MeshInstance3D) -> bool:
		return _lens_x(a) < _lens_x(b))
	for i in lenses.size():
		var lens := lenses[i]
		var ab: AABB = (global_transform.affine_inverse() * lens.global_transform) * lens.get_aabb()
		lens.visible = false                      # our live quad replaces the pane
		var quad := MeshInstance3D.new()
		quad.name = "LensLeft" if i == 0 else "LensRight"
		var qm := QuadMesh.new()
		qm.size = Vector2(ab.size.x, ab.size.y)
		quad.mesh = qm
		var mat := ShaderMaterial.new()
		mat.shader = WINDOW_SHADER
		# Left half of the composite, pinned per pane: stereo_mode 1 never
		# applies eye_shift (left eye), 2 always applies it (right eye).
		mat.set_shader_parameter("source_rect", Vector4(0.0, 0.0, 0.5, 1.0))
		mat.set_shader_parameter("eye_shift", 0.5)
		mat.set_shader_parameter("stereo_mode", 1 if i == 0 else 2)
		quad.set_surface_override_material(0, mat)
		add_child(quad)
		quad.position = Vector3(ab.get_center().x, ab.get_center().y, ab.end.z + 0.0012)
		_lens_quads.append(quad)
		_lens_mats.append(mat)


func _lens_x(m: MeshInstance3D) -> float:
	var ab: AABB = (global_transform.affine_inverse() * m.global_transform) * m.get_aabb()
	return ab.get_center().x


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
	for m in _lens_mats:
		if m.get_shader_parameter("source_tex") != tex:
			m.set_shader_parameter("source_tex", tex)
	# Visor glow tracks whether there's a picture (fixed red set at creation).
	if _vb_light:
		_vb_light.light_energy = VB_LIGHT_ENERGY if tex != null else 0.0


## Sit the START/STOP and RESET buttons on the front of the bipod base plate
## instead of leaving them at the default cabinet front-face height, where the
## Virtual Boy's tall stand leaves them floating in mid-air. The StandBase plate
## top is at y = 0.012; the button boxes are 0.02 tall (half-height 0.01), so a
## button resting on the plate centres at y = 0.022. They keep the default
## upright (+Z-facing) orientation, so the poke/press mechanics are unchanged.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	power_btn.set_color(Color(0.0, 1.0, 0.0))   # START/STOP label+colour owned by system.gd
	if _glb != null:
		# No bipod to sit on. Rest them ON the shell's top face, outboard of the
		# carry handle and clear of the cart slot at the back, rather than at the
		# front lip where the protruding eye shade leaves them floating in air.
		# Use the shell's own top controls rather than dropping boxes on it.
		var ab := _glb_aabb()
		_bind_to_shell(power_btn, _FOCUS_L, ab.end.y)
		_bind_to_shell(reset_btn, _FOCUS_R, ab.end.y)
		return
	power_btn.position = Vector3(0.04, 0.022, 0.045)
	reset_btn.position = Vector3(-0.04, 0.022, 0.045)


## The shell's OWN top controls, measured off an orthographic render of the top
## face (the model bakes them into the body mesh, so there is nothing to bind a
## button mesh to — these are positions only).
##
## Note what they actually are: the two silver sliders are the LEFT and RIGHT
## FOCUS adjusters (the word FOCUS is printed between them) and the dial above
## is the IPD wheel. The real Virtual Boy has no power switch or volume on the
## head unit at all — both live on the controller — so there is no authentic
## console control to bind START/STOP to. These are the nearest real affordances.
const _FOCUS_L := Vector3(-0.0163, 0.0, 0.0021)
const _FOCUS_R := Vector3(0.0185, 0.0, 0.0021)
## Focus sliders travel sideways (the caps are marked with left/right arrows).
const _SLIDER_TRAVEL := 0.003


## Put a control's touch zone on a real feature of the shell and remove our own
## placeholder geometry entirely. Nothing animates: the controls are part of the
## body mesh, so there is no separate node to move. Splitting them out would need
## the Blender pass the 3DS slider knobs got.
func _bind_to_shell(btn: VRButton, xz: Vector3, top_y: float) -> void:
	if btn == null:
		return
	var mesh := btn.get_node_or_null("ButtonMesh") as MeshInstance3D
	if mesh != null:
		mesh.hide()
	btn.position = Vector3(xz.x, top_y - 0.004, xz.z)
	btn.depress_depth = _SLIDER_TRAVEL
	btn.set_depress_axis_world(Vector3.LEFT)   # slides, not sinks
	# Drop the cabinet's START/RESET caption: it would be printed across a
	# control that is actually a focus slider, which is worse than no label.
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


## Underside controller socket. Measured off a straight-up render of the bottom
## face against the six-pin socket the shell actually models — not the marker
## names, and not the battery-cover panel just behind it, which is what a first
## eyeball estimate lands on.
const _PORT_X := 0.082
const _PORT_Z := -0.0334


## The single controller port sits under the front of the visor pointing down,
## like the real EXT connector on the underside of the head unit.
func configure_controller_ports(port_zones: Array) -> void:
	if port_zones.size() > 0:
		var zone: Node3D = port_zones[0]
		if _glb != null:
			# Controller socket on the UNDERSIDE, right of centre — measured off
			# an orthographic render of the bottom face (with a reference marker
			# at a known +X, because looking straight up makes left/right
			# ambiguous). Matches the manual's bottom view: socket to one side,
			# volume dial and headphone jack on the other.
			var ab := _glb_aabb()
			zone.position = Vector3(_PORT_X, ab.position.y + 0.006, _PORT_Z)
			zone.rotation_degrees = Vector3(90, 0, 0)
			var recess := zone.get_node_or_null("PortRecess") as MeshInstance3D
			if recess != null:
				recess.hide()
			return
		zone.position = Vector3(0, STAND_H - 0.008, VISOR_SIZE.z / 2.0 - 0.025)
		# Rotate the zone's +Z (the plug's approach axis on every other system's
		# front face) to face straight down.
		zone.rotation_degrees = Vector3(90, 0, 0)


## How far the cart's centre sits out from socket_media along the grip axis.
##
## socket_media marks where the connector mates and a snap zone seats on the
## object's CENTRE, so some offset is needed or the cart vanishes inside the
## shell — but a full half-length (27 mm) leaves it hanging 32 mm out in open
## air. Sized off the shell instead: scanning the shell mesh across the band the
## cart passes through (|x| < 0.03, y = 0.0147 +/- 0.004) puts its front face at
## z = -0.0629, with the hood overhanging to -0.0761 just above. Park the cart's
## grip end 2 mm proud of that overhang, so it reads as seated but still has a
## lip to take hold of: 0.0781 - 0.0407 - 0.054 / 2.
const _CART_SEAT_OUT := 0.0104


func configure_cartridge_slot(slot: Node3D) -> void:
	if _glb != null:
		var mk := _glb.find_child("socket_media", true, false) as Node3D
		if mk != null:
			var b: Basis = _glb.global_transform.basis.orthonormalized()
			# Lay the cart flat with the label up, connector leading along the
			# axis the bundle's own `Virtual Boy_Insert_PAN` clip travels on
			# (Z alone — so the cart is pushed in horizontally, not dropped in
			# from the top). A cartridge is authored connector -Y / label +Z, so
			# map its +Y (grip) onto the shell's +Z and its +Z (label) onto
			# world up. X has to invert for this to stay a rotation.
			#
			# Position comes from socket_media itself, NOT from the clip's end
			# pose: the converter bakes node translations but copies animation
			# channel values through untouched, so the two are in different
			# frames and differencing them is meaningless. The clip is good for
			# the axis and nothing else.
			#
			var sb: Basis = b * Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0))
			slot.global_transform = Transform3D(sb, mk.global_position + sb.y * _CART_SEAT_OUT)
			var sv := slot.get_node_or_null("SlotVisual") as MeshInstance3D
			if sv != null:
				sv.visible = false
			return
		slot.global_position = _marker("socket_media")
		var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
		if v != null:
			v.visible = false
		return
	slot.position = Vector3(0, _visor_center_y + VISOR_SIZE.y / 2.0 + 0.01, 0)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false


func configure_cable_attach(attach_point: Node3D) -> void:
	# Video-out on the rear of the visor, not the left edge.
	if _glb != null:
		attach_point.global_position = _marker("Cable Plug (R)")
		var pv := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
		if pv != null:
			pv.visible = false
		return
	attach_point.position = Vector3(0, _visor_center_y, -VISOR_SIZE.z / 2.0 - 0.002)


## The default console collision box (bottom at y=-0.05) leaves the Virtual Boy
## floating above the floor — and a single full-height slab wraps the thin stand
## in a huge invisible volume. Match the actual geometry instead: the main shape
## becomes the visor box (so hand-grabs feel right), plus a base plate and a
## slim column so the stand rests on the ground. The PointerArea (what the
## selection ray hits) must be resized too — its default console-sized box sits
## at floor level, so the ray could never intersect the visor.
func configure_collision(host: Node3D) -> void:
	if _glb != null:
		# One box round the head unit: there is no bipod on this shell, it rests
		# on the table like the real thing does off its stand.
		var ab := _glb_aabb()
		for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
			var c := host.get_node_or_null(path) as CollisionShape3D
			if c != null and c.shape is BoxShape3D:
				c.shape = c.shape.duplicate()
				(c.shape as BoxShape3D).size = ab.size + Vector3(0.01, 0.01, 0.01)
				c.position = ab.get_center()
		return
	var top := _visor_center_y + VISOR_SIZE.y / 2.0   # full height from the floor

	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = VISOR_SIZE
		col.position = Vector3(0, _visor_center_y, 0)

		var base_col := CollisionShape3D.new()
		base_col.name = "StandBaseCollision"
		var base_shape := BoxShape3D.new()
		base_shape.size = Vector3(0.16, 0.012, 0.14)
		base_col.shape = base_shape
		base_col.position = Vector3(0, 0.006, 0)
		host.add_child(base_col)

		var column_col := CollisionShape3D.new()
		column_col.name = "StandColumnCollision"
		var column_shape := BoxShape3D.new()
		column_shape.size = Vector3(0.03, STAND_H, 0.03)
		column_col.shape = column_shape
		column_col.position = Vector3(0, STAND_H / 2.0, 0)
		host.add_child(column_col)

	var pcol := host.get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol != null and pcol.shape is BoxShape3D:
		pcol.shape = pcol.shape.duplicate()
		(pcol.shape as BoxShape3D).size = Vector3(VISOR_SIZE.x + 0.04, top + 0.04, 0.16)
		pcol.position = Vector3(0, (top + 0.04) / 2.0, 0)


func on_power_on() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 1.0)
	for q in _lens_quads:
		q.visible = true


func on_power_off() -> void:
	if _stereo_mat:
		_stereo_mat.set_shader_parameter("powered", 0.0)
	for q in _lens_quads:
		q.visible = false
