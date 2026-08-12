## RetroSystemModelNES — the American front-loading NES (NES-001).
##
## Wires POWER / RESET, the power LED, the two controller sockets, the AV lead and
## the front-loading cartridge bay. The bay sits behind a hinged front flap (the
## "NesLid"): a grip-latched VRHinge swings the flap on its real hinge, so a
## cartridge can only be seated or pulled while the flap is up. Inserting or
## removing a cart drives the flap automatically.
##
## Ported from RetroVR's model of the same name, which was written against
## Mordred's EmuVR GLB. This one drives greenestbanana's Sketchfab shell instead
## (see LICENSE-nes-console.txt), so the parts that existed only to repair the
## .ugc->.glb conversion are gone:
##
##   * no clutter-hiding — the cord and controller were stripped from the asset.
##   * no decal-alpha repair — Sketchfab exports NesLabels as alphaMode MASK,
##     already correct; it was the .ugc converter that forced OPAQUE.
##   * no front-band repaint — that shell shared one black material between a
##     bogus front band and the cradle. This shell splits into three meshes.
##   * no flap-decal reparenting and no AnimationPlayer to disarm — the wordmark
##     decal was removed from the asset and no clips ship with it.
##
## The flap and port geometry carry over unchanged: both models measure the same
## hardware, and their port positions agree within 2 mm.
class_name RetroSystemModelNES
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/consoles/nes/nes_console.glb"
const RCA_PORT_SCENE := preload("res://Scenes/Objects/cables/rca_port.tscn")
const BUTTON_DEPRESS_DEPTH := 0.0022
# Travel of the CH3/CH4 knob. 3 mm, so that a 6 mm knob stays inside the 9.8 mm
# recess the shell moulds for it at both detents — see _build_channel_switch.
const CH_THROW := 0.003
const INSERT_SLIDE := 0.07        # metres the cart slides in from the flap mouth
const LID_OPEN_DEG := -105.0      # flap swing about its top-rear hinge edge
const LID_ANIM_TIME := 0.35

var _glb: Node3D = null

# Front flap (hinge). Rotated about a hinge edge computed from its own AABB —
# the top-rear edge, which on this asset coincides exactly with the NesLidPivot
# node's origin, so the computed pivot lands at (0,0,0) in the flap's parent.
var _lid_mesh: MeshInstance3D = null
var _lid_rest: Transform3D = Transform3D.IDENTITY
var _lid_pivot: Vector3 = Vector3.ZERO   # hinge point in the flap's parent space
var _lid_amount: float = 0.0             # 0 = shut … 1 = fully open
var _lid_tween: Tween = null

# The shell's own RF SWITCH jack and CH3-CH4 slide switch, on the BACK face. The
# jack is used as it is; the switch needs a cap of its own to slide. See
# _build_rf_panel.
var _rf_out: RcaPort = null
var _ch_slider: VRSlider = null
var _ch_knob: MeshInstance3D = null
var _rf_channel: int = 3

var _power_light_mesh: MeshInstance3D = null
var _power_light_mats: Array[StandardMaterial3D] = []
var _power_button: VRButton = null

var _cartridge_slot: Node3D = null
var _cartridge_insert_dir: Vector3 = Vector3.BACK

# Front-flap interaction — a grip-latched VRHinge drives the flap: grab its
# bottom (free) half and swing it. _flap_frame/_flap_pivot form the angle-driver
# frame the hinge reports into (origin at the real hinge, -Z along the shut
# flap); _deg_open is that frame's angle at full open, so the reported degrees
# map onto _lid_amount 0..1.
var _lid_open: bool = false
var _flap_hinge: VRHinge = null
var _flap_frame: Node3D = null
var _flap_pivot: Node3D = null
var _deg_open: float = 0.0


func _ready() -> void:
	# An authored nes.tscn may instance the shell as a "Shell" child so the
	# cartridge seat can be dialled in in the Godot 3D editor. Reuse that instance
	# rather than loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("NESModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("NESModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		# MUST be "Shell": that is what RetroSystemModel.has_baked_shell() looks
		# for, and it is how the framework knows this model brings its own printed
		# legends. Left unnamed, the cabinet decided there was no detailed shell
		# and laid its own SystemNameLabel — "NINTENDO ENTERTAINMENT SYSTEM" — flat
		# across the console's front face.
		_glb.name = "Shell"
		add_child(_glb)

	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false

	# The shell is authored centred on its own middle, so half of it would hang
	# below any surface it is placed on. Recentre on X/Z and rest the base at
	# y = 0 — which is also what the port constants below assume. Baked scenes
	# already carry this in the Shell transform, so re-running it would double up.
	if baked == null:
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)

	_lid_mesh = _glb.find_child("NesLid", true, false) as MeshInstance3D
	if _lid_mesh:
		_lid_rest = _lid_mesh.transform
		var a := _lid_mesh.get_aabb()
		var hinge_local := Vector3(a.position.x + a.size.x * 0.5, a.position.y + a.size.y, a.position.z)
		_lid_pivot = _lid_mesh.transform * hinge_local
		_setup_flap_hinge()

	_power_light_mesh = _glb.find_child("PowerLight", true, false) as MeshInstance3D
	if _power_light_mesh:
		_prep_power_light()
		_set_power_light(false)


# --- power LED ------------------------------------------------------------------

## Give the LED an emissive material so it glows red when the console is on and
## reads as a dark unlit lens when off, instead of just toggling visibility.
func _prep_power_light() -> void:
	_power_light_mats.clear()
	for s in range(_power_light_mesh.mesh.get_surface_count()):
		var src := _power_light_mesh.get_active_material(s) as BaseMaterial3D
		var m := StandardMaterial3D.new()
		if src != null:
			m.albedo_color = src.albedo_color
		m.emission_enabled = true
		m.emission = Color(1.0, 0.05, 0.0)
		m.emission_energy_multiplier = 0.0
		_power_light_mesh.set_surface_override_material(s, m)
		_power_light_mats.append(m)


func _set_power_light(on: bool) -> void:
	for m in _power_light_mats:
		m.emission_energy_multiplier = 3.0 if on else 0.0


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


# --- front flap (hinge) ---------------------------------------------------------

## Pose the flap: 0 = shut, 1 = fully open. Rotates the mesh about its hinge edge.
func _set_lid(amount: float) -> void:
	_lid_amount = amount
	if _lid_mesh == null:
		return
	var r := Basis(Vector3.RIGHT, deg_to_rad(LID_OPEN_DEG) * amount)
	var about := Transform3D(r, _lid_pivot - r * _lid_pivot)
	_lid_mesh.transform = about * _lid_rest
	_sync_flap_plug()


func _tween_lid(to: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_lid_tween = create_tween()
	_lid_tween.tween_method(_set_lid, _lid_amount, to, LID_ANIM_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Swing the flap up on its hinge and enable the cartridge bay. Also snaps the
## grab hinge to the open angle so a following grab resumes from the right pose.
func play_open() -> void:
	if _lid_open:
		return
	_lid_open = true
	_tween_lid(1.0)
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(_deg_open)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = true


## Swing the flap shut and gate the bay closed.
func play_close() -> void:
	if not _lid_open:
		return
	_lid_open = false
	_tween_lid(0.0)
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(0.0)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = false


## How far the flap has swung, in degrees from shut. The clamshell's
## interior-angle convention does not apply to a front flap, but the save format
## is the same field: a lid pose in degrees, or -1 for hardware without one.
func get_lid_angle_deg() -> float:
	return _lid_amount * absf(LID_OPEN_DEG)


## Pose the flap at a saved angle, with no animation — a restore is a state the
## room was already in, not something the player just did. Takes the bay gate and
## the grab hinge with it, so the next grab resumes from the right pose.
func set_lid_angle_deg(open_deg: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	var amount := clampf(open_deg / absf(LID_OPEN_DEG), 0.0, 1.0)
	_set_lid(amount)
	_lid_open = amount > 0.5
	if _flap_hinge != null:
		_flap_hinge.set_rotation_deg_no_signal(_deg_open * amount)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = _lid_open


## Build the grip-latched grab handle on the flap. A hidden angle-driver frame
## (origin at the real hinge, -Z along the shut flap, X along the hinge axis) is
## what the VRHinge reports into; the reported degrees are remapped onto the
## flap's own about-the-hinge rotation via _set_lid, so the mesh keeps its pivot
## math. The grab Area3D rides the flap mesh, so the box, the VR proximity sphere
## and the floating hint icon track the swinging flap.
func _setup_flap_hinge() -> void:
	if _lid_mesh == null:
		return
	var fp := _lid_mesh.get_parent() as Node3D
	if fp == null:
		return
	var a := _lid_mesh.get_aabb()
	var cx := a.position.x + a.size.x * 0.5
	var cz := a.position.z + a.size.z * 0.5
	var hinge_par: Vector3 = _lid_rest * Vector3(cx, a.position.y + a.size.y, cz)
	var free_par: Vector3 = _lid_rest * Vector3(cx, a.position.y, cz)
	var open_rot := Basis(Vector3.RIGHT, deg_to_rad(LID_OPEN_DEG))
	var free_open_par: Vector3 = hinge_par + open_rot * (free_par - hinge_par)
	var to_model: Transform3D = global_transform.affine_inverse() * fp.global_transform
	var hinge_m: Vector3 = to_model * hinge_par
	var free_m: Vector3 = to_model * free_par
	var free_open_m: Vector3 = to_model * free_open_par
	var axis_m: Vector3 = (to_model.basis * Vector3.RIGHT).normalized()
	var shut_dir: Vector3 = (free_m - hinge_m).normalized()
	var x_axis := axis_m
	var z_axis := (-shut_dir - x_axis * (-shut_dir).dot(x_axis)).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	_flap_frame = Node3D.new()
	_flap_frame.name = "FlapHinge"
	add_child(_flap_frame)
	_flap_frame.transform = Transform3D(Basis(x_axis, y_axis, z_axis), hinge_m)
	_flap_pivot = Node3D.new()
	_flap_pivot.name = "FlapDragPivot"
	_flap_frame.add_child(_flap_pivot)
	var open_rel: Vector3 = _flap_frame.transform.affine_inverse() * free_open_m
	_deg_open = rad_to_deg(atan2(open_rel.y, -open_rel.z))
	_flap_hinge = VRHinge.new()
	_flap_hinge.name = "FlapGrab"
	# Squeeze to swing it. Nobody picks a deck up off the desk by its cartridge
	# flap, so the grip is free to mean "open this" here; the hinge mutes that
	# hand's pickup while it is on the flap so the console stays put.
	_flap_hinge.grip_engages = true
	_flap_hinge.target = _flap_pivot
	_flap_hinge.min_deg = minf(0.0, _deg_open)
	_flap_hinge.max_deg = maxf(0.0, _deg_open)
	_flap_hinge.engage_radius = clampf(maxf(a.size.x, a.size.y * 0.5) * 0.6, 0.03, 0.09)
	_lid_mesh.add_child(_flap_hinge)
	_flap_hinge.transform = Transform3D(Basis.IDENTITY,
		Vector3(cx, a.position.y + a.size.y * 0.25, cz))
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(a.size.x * 0.9, a.size.y * 0.5, maxf(a.size.z, 0.006) + 0.012)
	col.shape = box
	_flap_hinge.add_child(col)
	# Hint in the flap's OWN plane, just past the grab box. Derived from the pivot
	# rather than written as a literal -Y: this hinge hangs off the flap MESH while
	# its pivot lives under _flap_frame, so their axes only happen to line up.
	var ax_w: Vector3 = _flap_pivot.global_transform.basis.x.normalized()
	var radial: Vector3 = _flap_hinge.global_position - _flap_pivot.global_position
	radial -= ax_w * radial.dot(ax_w)
	if radial.length() > 0.0001:
		_flap_hinge.place_hint(_flap_hinge.to_local(_flap_hinge.global_position
			+ radial.normalized() * (a.size.y * 0.25 + 0.014)))
	_flap_hinge.rotation_changed.connect(_on_flap_drag)


## Map the grab hinge's reported angle onto the flap open amount and gate the bay.
func _on_flap_drag(deg: float) -> void:
	if is_zero_approx(_deg_open):
		return
	var amount := clampf(deg / _deg_open, 0.0, 1.0)
	_set_lid(amount)
	var open := amount > 0.5
	if open == _lid_open:
		return
	_lid_open = open
	if _cartridge_slot != null:
		_cartridge_slot.enabled = _lid_open


# --- ports / buttons / cable ----------------------------------------------------

func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


## POWER latches down and stays in; RESET is momentary. This shell ships no
## "Finger Button" empties to read the travel axis from, so both are placed at
## their mesh centres and pressed along the console's own -Z, into the front face.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_power_button = power_btn
	power_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	reset_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	power_btn.set_latched_pressed(false)
	reset_btn.set_latched_pressed(false)
	if _glb != null:
		var into_face: Vector3 = -global_transform.basis.z.normalized()
		var power_mesh := _glb.find_child("ButtonPower", true, false) as MeshInstance3D
		var reset_mesh := _glb.find_child("ButtonReset", true, false) as MeshInstance3D
		if power_mesh:
			power_btn.set_button_mesh(power_mesh)   # also hides the placeholder box
			power_btn.global_position = _mesh_center("ButtonPower")
			power_btn.set_depress_axis_world(into_face)
			_ride_cap(power_mesh, "ButtonPowerLabel")
		if reset_mesh:
			reset_btn.set_button_mesh(reset_mesh)
			reset_btn.global_position = _mesh_center("ButtonReset")
			reset_btn.set_depress_axis_world(into_face)
			_ride_cap(reset_mesh, "ButtonResetLabel")
	for btn in [power_btn, reset_btn]:
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl:
			lbl.hide()


## Hang a printed legend on the cap it is printed on.
##
## The shell models POWER and RESET as decal planes 0.1 mm proud of their cap's
## face, but parents them BESIDE the cap under the shared ButtonPowerPivot rather
## than to it. VRButton travels the cap mesh alone, so a pressed button sank 2.2 mm
## and left its word hanging in the air in front of the hole.
func _ride_cap(cap: MeshInstance3D, legend_name: String) -> void:
	var legend := _glb.find_child(legend_name, true, false) as Node3D
	if legend != null and legend.get_parent() != cap:
		legend.reparent(cap)


## The two front-panel sockets, measured off the shell's own "1" and "2" number
## decals and dropped to the socket mouths below them. Carried over from RetroVR's
## model of the same hardware — this shell's decals sit at x = 0.0658 / 0.0840,
## within 2 mm of those, so the same constants hold.
const _PORT_X := [0.0645, 0.0824]
const _PORT_Y := 0.0301
const _PORT_Z := 0.0975


func configure_controller_ports(port_zones: Array) -> void:
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		# An authored "PortSeat1"/"PortSeat2" marker wins over the computed pose,
		# the same "authored beats computed" idiom as CartSeat/DiscSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		elif i < _PORT_X.size():
			zone.position = Vector3(_PORT_X[i], _PORT_Y, _PORT_Z)
			# Front-facing socket: ROLL 180 about Z so the plug seats connector-in
			# and upright. A yaw lands it backwards and upside down.
			#
			# The turning is not done by this rotation alone. ControllerPlug's
			# SnapGrabPoint is itself rotated 180 about X, and XRTools aligns that
			# grab point — not the plug's origin — to the zone. Composed with it, a
			# roll sends the plug's +Z connector to -Z (into the shell) and keeps +Y
			# up; a yaw sends the connector back OUT and flips the plug over.
			zone.rotation_degrees = Vector3(0, 0, 180)
	hide_port_placeholders(port_zones)


## Sockets, not a captive lead: this shell moulds the two jacks the hardware has,
## so the player runs a mono composite lead from them to the set the way you did.
## Video and ONE audio channel — the NES is mono, and its single cord feeds
## whichever speaker it reaches.
func av_port_channels() -> Array:
	return [RcaPort.Channel.VIDEO, RcaPort.Channel.AUDIO_L]


## Seat the two ports on the jacks the shell already moulds — JackYellow for video,
## JackRed for the one audio channel an NES puts out.
##
## Positions are read off those meshes rather than written down: the shell is a
## downloaded asset and its jacks are where they are. The ports' own jack visuals
## are turned off, because the moulded pair underneath is the one that belongs to
## this console and two in the same place would z-fight.
##
## Rotation is +90° about Y, which puts each socket's local +Z on device +X — out
## of the flank. NOT the captive lead's -90°: that convention exists because
## VerletRope leaves an attach point along its local -Z, so it aims the OPPOSITE
## way. Used here it yaws every plug 180° and the connector points out of the
## console while the body sits inside it.
func configure_av_ports(ports: Array) -> void:
	if _glb == null:
		return
	var jacks := ["JackYellow", "JackRed"]
	for i in mini(ports.size(), jacks.size()):
		var port: Node3D = ports[i]
		var centre := _mesh_center(jacks[i])
		if centre == Vector3.ZERO:
			continue
		port.global_position = centre
		port.rotation = Vector3(0.0, PI / 2.0, 0.0)
		if port.has_method("set"):
			port.set("show_jack", false)
	# The back face carries two more of the console's own fittings.
	_build_rf_panel()


## Make the shell's own RF SWITCH jack and CH3-CH4 slide switch work.
##
## BOTH ARE ALREADY MOULDED, on the BACK face beside the AC adapter legend, and the
## shell prints their names in red. Nothing is drawn here: this hangs a snap zone
## over the jack and a VRSlider over the switch, exactly as configure_av_ports does
## for the moulded AUDIO/VIDEO pair on the flank.
##
## ── Measured by raycast, because neither is a named node ────────────────────
## JackRed and JackYellow are their own MeshInstances and can be looked up. These
## two are baked into NesDeck / NesDeckBlack, so the only way to find them is to
## fire rays at the back face along +Z and read where the surface is:
##
##   panel face                z = -0.0964
##   RF SWITCH jack, centred   (0.0635, 0.0290)   boss 2.1 mm proud
##   CH3-CH4 switch, centred   (0.0783, 0.0295)   recessed 2.1 mm into the panel
##
## Absolute in the model's frame rather than stepped off another mesh, which is what
## the rest of this file does for hand-measured geometry (see configure_collision).
## _ready re-centres the GLB deterministically, so these are stable for this asset;
## a re-export that moves the case needs them re-measured.
const RF_OUT_POS := Vector3(0.0635, 0.0290, -0.0985)
const CH_SW_POS := Vector3(0.0783, 0.0308, -0.0982)


func _build_rf_panel() -> void:
	if _glb == null:
		return
	_build_rf_out()
	_build_channel_switch()


func _build_rf_out() -> void:
	var port := RCA_PORT_SCENE.instantiate() as RcaPort
	port.name = "RfOut"
	# Channel.VIDEO, not a channel of its own: an RF feed is not composite video,
	# but nothing in the routing has to know — which input a television treats it as
	# is decided by the SOCKET it lands in at the far end. See CoaxPort.
	port.channel = RcaPort.Channel.VIDEO
	port.direction = RcaPort.Direction.OUT
	# The shell moulds this jack, so the port must not draw a second one on top of
	# it — the same call the AUDIO/VIDEO pair makes, and for the same reason.
	port.show_jack = false
	add_child(port)
	port.position = RF_OUT_POS
	# Yawed a half turn so the socket receives along device -Z, out of the back.
	# The flank pair uses +90 for the same reason; this is that rule on the other
	# face, and a plain yaw is enough because a phono connector is round.
	port.rotation = Vector3(0.0, PI, 0.0)
	_rf_out = port


## Make the moulded CH3-CH4 switch work, and let it actually slide.
##
## The switch IS already modelled — a ribbed thumb cap at the CH3 end of a black slot
## — but it cannot be moved: it is baked into NesDeckBlack along with half the case,
## not a node of its own. A switch that never moves is a switch the player cannot
## read, so the moulded cap is MASKED by a plate the colour of the slot behind it and
## a cap of our own rides in the slot instead. Only two small meshes, both inside the
## recess the shell already moulds, and nothing else about the console is touched.
##
## The alternative — a hidden placeholder knob, the case VRSlider and WidgetOutline
## both document — leaves the printed CH3-CH4 legend pointing at something that never
## changes. Worth the two meshes to avoid.
##
## Sizes come off the raycast and the render: the moulded cap spans x 0.0771..0.0832,
## y 0.0280..0.0336, inside a slot running x 0.0729..0.0836. The mask covers the
## former and our cap slides 3 mm inside the latter.
##
## The mask's DEPTH is the part that bit. A 2.5 mm raycast sweep reported the switch
## at z = -0.0943 and a plate put there left the ribs poking straight through it: the
## sweep had been landing in the rib VALLEYS, and the crests stand out at -0.0965,
## flush with the panel. Both plate and cap therefore sit in FRONT of -0.0965, which
## is also why the cap ends up standing a couple of millimetres proud — as a thumb
## switch does.
const CH_MASK_POS := Vector3(0.0801, 0.0308, -0.0969)


func _build_channel_switch() -> void:
	# The slot's own black, so the plate reads as empty slot rather than as a patch.
	# UNSHADED, and that is the whole trick: the slot it has to disappear into is a
	# deep recess the key light never reaches, so a lit plate across the mouth of it
	# comes back several stops brighter and reads as a patch. Darkness by MATERIAL,
	# the same call gen_rca_jack.gd makes for a socket bore.
	var slot_ink := StandardMaterial3D.new()
	slot_ink.albedo_color = Color(0.02, 0.02, 0.022)
	slot_ink.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mask := MeshInstance3D.new()
	mask.name = "ChannelMask"
	var mask_mesh := BoxMesh.new()
	mask_mesh.size = Vector3(0.0068, 0.0062, 0.0008)
	mask.mesh = mask_mesh
	mask.material_override = slot_ink
	add_child(mask)
	mask.position = CH_MASK_POS

	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.52, 0.51, 0.50)
	cap_mat.roughness = 0.62

	# Authored at the CH3 detent, which is slider value 0 — set_knob_mesh anchors the
	# knob wherever it finds it AT THE CURRENT VALUE, so a cap left mid-slot would put
	# both detents half a throw out.
	_ch_knob = MeshInstance3D.new()
	_ch_knob.name = "ChannelKnob"
	var knob_mesh := BoxMesh.new()
	knob_mesh.size = Vector3(0.0052, 0.0042, 0.0018)
	_ch_knob.mesh = knob_mesh
	_ch_knob.material_override = cap_mat
	add_child(_ch_knob)
	_ch_knob.position = CH_SW_POS + Vector3(CH_THROW * 0.5, 0.0, 0.0)

	var slider := VRSlider.new()
	slider.name = "ChannelSwitch"
	# -X, not +X: the shell prints "CH3-CH4" reading along device -X, so CH3 is the
	# +X end. Value 0 is the low end of the axis, and value 0 has to be CH3.
	slider.axis_local = Vector3(-1.0, 0.0, 0.0)
	slider.travel = CH_THROW
	slider.steps = 2
	slider.value = 0.0
	slider.collision_layer = 1 | (1 << 20)
	slider.engage_radius = 0.020
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CH_THROW + 0.008, 0.009, 0.008)
	col.shape = box
	slider.add_child(col)
	add_child(slider)                     # _ready runs here, before adopting
	slider.position = CH_SW_POS
	slider.set_knob_mesh(_ch_knob)
	slider.value_changed.connect(_on_channel_slider_changed)
	_ch_slider = slider


func _on_channel_slider_changed(value: float) -> void:
	var next: int = 3 if value < 0.5 else 4
	if next == _rf_channel:
		return
	_rf_channel = next
	print("[NES] RF channel switch -> CH%d" % _rf_channel)
	# The set has to re-read it: on the aerial input the picture only appears when
	# its own tuning matches, and nothing else would tell it this moved.
	var host := get_parent()
	if host != null and host.has_method("on_rf_channel_changed"):
		host.call("on_rf_channel_changed")


## Which channel this console's RF switch puts it on. -1 from the base class means
## "no such switch", which is every other machine in the room.
func get_rf_channel() -> int:
	return _rf_channel


## The NES's AV jacks sit on the RIGHT (+X) flank — this shell moulds them there
## (JackRed / JackYellow at x = 0.12) — so the video cable trails out +X rather
## than straight back like a rear-panel console.
func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb != null:
		attach_point.global_position = _mesh_center("JackYellow")
	# VerletRope leaves the attach point stiffly along its local -Z, so rotate
	# -90° about Y (local -Z -> device +X) to steer the cable out of the flank.
	# That also aims PortVisual's +Z connector into the jack, since the plug mesh
	# is authored connector-on-+Z.
	attach_point.rotation = Vector3(0.0, -PI / 2.0, 0.0)
	# PortVisual stays VISIBLE. It used to be hidden because it was a grey
	# cylinder stub that looked wrong against the shell's moulded jacks; now that
	# it is the same yellow RCA plug the TV end wears, it is the connector seated
	# in JackYellow, and hiding it left the cord emerging from nothing.


func get_cable_spawn_offset(channel: int) -> Vector3:
	return Vector3(0.12, 0.0, 0.05 * channel)


# --- cartridge (front-load: slides straight back into the ZIF socket) -----------

func configure_cartridge_slot(slot: Node3D) -> void:
	_cartridge_slot = slot
	if _glb != null:
		var cradle := _glb.find_child("NesCradle", true, false) as MeshInstance3D
		if cradle:
			# Lay the cart FLAT, label up, connector pointing into the machine. A
			# cartridge is authored connector -Y / label +Z, so map its +Y (grip)
			# onto +Z (out the front) and its +Z (label) onto up; X inverts to keep
			# it a rotation. Without this the cart stands on end in the bay.
			#
			# Composed onto the SHELL's basis, not written as a world one: a bare
			# Basis here is an absolute orientation, so the cart faced the same
			# compass direction whichever way the console was turned.
			var b: Basis = _glb.global_transform.basis.orthonormalized()
			slot.global_transform = Transform3D(
				b * Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
				cradle.global_transform * cradle.get_aabb().get_center())
		# This shell ships no "System Socket" marker, so the insert axis is the
		# console's own front direction rather than read off the socket.
		_cartridge_insert_dir = global_transform.basis.z.normalized()
		var seat := find_child("CartSeat", true, false) as Node3D
		if seat != null:
			slot.global_transform = seat.global_transform
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual:
		slot_visual.hide()
	# Bay is sealed by the flap: only accept a cartridge while the flap is open.
	slot.enabled = _lid_open


func get_cartridge_insert_direction() -> Vector3:
	return _cartridge_insert_dir


func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	# Make sure the flap is up, then slide the cart from the mouth back into the
	# socket. XRTools has already snapped/frozen it at the final socket position.
	play_open()
	var final_pos := cartridge.global_position
	cartridge.freeze = false
	cartridge.global_position = final_pos + _cartridge_insert_dir * INSERT_SLIDE
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_position", final_pos, 0.25) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: cartridge.freeze = true)


func play_cartridge_eject(_cartridge: Node3D, _slot: Node3D) -> void:
	# Cart is already in hand; make sure the flap is up so the pull reads right.
	play_open()


func on_power_on() -> void:
	if _power_button:
		_power_button.set_latched_pressed(true)
	_set_power_light(true)


func on_power_off() -> void:
	if _power_button:
		_power_button.set_latched_pressed(false)
	_set_power_light(false)


# --- collision ------------------------------------------------------------------

## Deck envelope, measured off this asset (0.256 x 0.093 x 0.204) and rounded out.
## Without it the console keeps system.tscn's generic box, centred on the model
## origin, so half hangs below the shell and every table contact holds it in the air.
const DECK_BOX := Vector3(0.26, 0.094, 0.208)
const DECK_POS := Vector3(0.0, 0.047, 0.0)
## Slack around the bay mouth, and the extra the flap carries so it still seals
## the mouth from inside.
const MOUTH_MARGIN := 0.001
const PLUG_MARGIN := 0.003
## The flap is an L: a top plate 2.1 mm thick running the bay's full 42 mm depth,
## and a front plate 5.2 mm thick standing its full 34 mm height, with the inside
## corner empty. Padded to something a solver can stop against. One box round the
## pair would fill that corner, which is bay interior — harmless shut, and a
## 48 mm-deep slab standing over the machine once the flap is up.
const FLAP_TOP_PLATE := 0.008
const FLAP_FRONT_PLATE := 0.010
## Bodies the deck is built on: the console's own, and its pointer body.
const COLLISION_PATHS := ["CollisionShape3D", "PointerArea/CollisionShape3D"]

# The flap's plates, on each of those bodies, re-posed by _set_lid. Centres are
# in the flap mesh's own space and run parallel to the shapes.
var _flap_shapes: Array[CollisionShape3D] = []
var _flap_centres: Array[Vector3] = []
var _glb_to_host: Transform3D = Transform3D.IDENTITY


## Rest the console on the surface it is placed on, and leave the cartridge bay
## open to the front.
##
## Four boxes around a fifth that is left empty. A seated cart lies entirely
## inside the deck envelope — front edge 21 mm behind the deck face, top face
## 10 mm below it — so one box for the whole deck puts shell in front of the cart
## from every angle, and no depth threshold tells the deck top (11 mm of box) from
## the bay mouth (26 mm), because the legitimate path is the deeper one. Carved,
## there is nothing in front of the cart to ask the question about.
##
## The mouth is shut by the flap's own box, which _set_lid carries with the flap.
func configure_collision(host: Node3D) -> void:
	var env := AABB(DECK_POS - DECK_BOX * 0.5, DECK_BOX)
	var mouth := _bay_mouth(host, env)
	var open_bay := mouth.size.x > 0.0 and mouth.size.y > 0.0 and mouth.size.z > 0.0
	for path in COLLISION_PATHS:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col == null or not (col.shape is BoxShape3D):
			continue
		if open_bay:
			_carve_bay(col, env, mouth)
		else:
			_box(col, env)
	if open_bay:
		_build_flap_plug(host)


## The front opening, in the host's frame: the flap's own footprint carried out
## to the deck's top and front faces.
func _bay_mouth(host: Node3D, env: AABB) -> AABB:
	if _lid_mesh == null:
		return AABB()
	var fp := _lid_mesh.get_parent() as Node3D
	if fp == null:
		return AABB()
	_glb_to_host = host.global_transform.affine_inverse() * fp.global_transform
	var m: AABB = (_glb_to_host * _lid_rest) * _lid_mesh.get_aabb()
	m = m.grow(MOUTH_MARGIN)
	var hi := Vector3(m.end.x, env.end.y, env.end.z)
	return AABB(m.position, hi - m.position).intersection(env)


## Reuse `col` for the slab under the mouth and give its body three siblings for
## the volume behind it and to either side.
func _carve_bay(col: CollisionShape3D, env: AABB, mouth: AABB) -> void:
	var up_y := mouth.position.y
	var up_h := env.end.y - up_y
	var front_z := mouth.position.z
	var front_d := env.end.z - front_z
	_box(col, AABB(env.position, Vector3(env.size.x, up_y - env.position.y, env.size.z)))
	var walls := [
		["ShellRear", AABB(Vector3(env.position.x, up_y, env.position.z),
			Vector3(env.size.x, up_h, front_z - env.position.z))],
		["ShellLeft", AABB(Vector3(env.position.x, up_y, front_z),
			Vector3(mouth.position.x - env.position.x, up_h, front_d))],
		["ShellRight", AABB(Vector3(mouth.end.x, up_y, front_z),
			Vector3(env.end.x - mouth.end.x, up_h, front_d))],
	]
	var parent := col.get_parent()
	for wall in walls:
		var part_name: String = wall[0]
		var a: AABB = wall[1]
		if a.size.x <= 0.0 or a.size.y <= 0.0 or a.size.z <= 0.0:
			continue
		var extra := parent.get_node_or_null(NodePath(part_name)) as CollisionShape3D
		if extra == null:
			extra = CollisionShape3D.new()
			extra.name = part_name
			parent.add_child(extra)
		_box(extra, a)


## The flap's box, one shape on each of the console's own bodies rather than a
## body of its own parented to the flap mesh. XRTools mutes a held object through
## its body's collision_layer and collision_mask, which reaches every shape on
## that body and nothing on a separate one, so a flap body would keep its Pickable
## layer and sweep a solid box through the room whenever the console was carried.
func _build_flap_plug(host: Node3D) -> void:
	if _lid_mesh == null:
		return
	var a := _lid_mesh.get_aabb()
	var m := PLUG_MARGIN
	# Each plate keeps the flap's own outer face and takes its thickness inward,
	# so the pair reads as the door rather than as a block the size of the door's
	# travel. They meet in the corner, which is solid on the real shell.
	var plates := {
		"BayFlapTop": AABB(
			Vector3(a.position.x - m, a.end.y - FLAP_TOP_PLATE, a.position.z - m),
			Vector3(a.size.x + m * 2.0, FLAP_TOP_PLATE + m, a.size.z + m * 2.0)),
		"BayFlapFront": AABB(
			Vector3(a.position.x - m, a.position.y - m, a.end.z - FLAP_FRONT_PLATE),
			Vector3(a.size.x + m * 2.0, a.size.y + m * 2.0, FLAP_FRONT_PLATE + m)),
	}
	_flap_shapes.clear()
	_flap_centres.clear()
	for path in COLLISION_PATHS:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col == null:
			continue
		var parent := col.get_parent()
		for plate_name in plates:
			var box: AABB = plates[plate_name]
			var plug := parent.get_node_or_null(NodePath(plate_name)) as CollisionShape3D
			if plug == null:
				plug = CollisionShape3D.new()
				plug.name = plate_name
				parent.add_child(plug)
			var shape := BoxShape3D.new()
			shape.size = box.size
			plug.shape = shape
			_flap_shapes.append(plug)
			_flap_centres.append(box.get_center())
	_sync_flap_plug()


## Carry the flap's plates with the flap. Both bodies they live on sit at the
## host's own origin, so the flap mesh's pose in host space is their transform.
func _sync_flap_plug() -> void:
	if _lid_mesh == null or _flap_shapes.is_empty():
		return
	var pose: Transform3D = _glb_to_host * _lid_mesh.transform
	for i in range(_flap_shapes.size()):
		var cs := _flap_shapes[i]
		if is_instance_valid(cs):
			cs.transform = pose * Transform3D(Basis.IDENTITY, _flap_centres[i])


## A fresh BoxShape3D spanning `a`. Never the scene's own shape resource: one
## BoxShape3D sub-resource is shared by every cabinet in the room.
func _box(col: CollisionShape3D, a: AABB) -> void:
	var shape := BoxShape3D.new()
	shape.size = a.size
	col.shape = shape
	col.position = a.get_center()
