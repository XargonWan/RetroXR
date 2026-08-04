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
const BUTTON_DEPRESS_DEPTH := 0.0022
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
		if reset_mesh:
			reset_btn.set_button_mesh(reset_mesh)
			reset_btn.global_position = _mesh_center("ButtonReset")
			reset_btn.set_depress_axis_world(into_face)
	for btn in [power_btn, reset_btn]:
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl:
			lbl.hide()


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


## The NES's AV jacks sit on the RIGHT (+X) flank — this shell moulds them there
## (JackRed / JackYellow at x = 0.12) — so the video cable trails out +X rather
## than straight back like a rear-panel console.
func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb != null:
		attach_point.global_position = _mesh_center("JackYellow")
	# VerletRope leaves the attach point stiffly along its local -Z, so rotate
	# -90° about Y (local -Z -> device +X) to steer the cable out of the flank.
	attach_point.rotation = Vector3(0.0, -PI / 2.0, 0.0)
	var port_visual := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if port_visual:
		port_visual.hide()


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
			# onto +Z (out the front) and its +Z (label) onto world up; X inverts
			# to keep it a rotation. Without this the cart stands on end in the bay.
			slot.global_transform = Transform3D(
				Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
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


## Rest the console ON the surface it is placed on. Without this it keeps
## system.tscn's generic box, centred on the model origin, so half hangs below the
## shell and every table contact holds the console in the air. Sized to the deck
## (0.256 x 0.093 x 0.206) measured off this asset.
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.26, 0.094, 0.208)
	var pos := Vector3(0.0, 0.047, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
