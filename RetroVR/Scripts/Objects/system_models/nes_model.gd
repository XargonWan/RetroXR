## RetroSystemModelNES — the American front-loading NES (NES-001).
##
## Loads an author's imported "NES System" GLB and wires POWER / RESET, the power LED,
## the two controller sockets, the RF video-out and the front-loading cartridge
## bay. The bay sits behind a hinged front flap (the "NesLid"): the GLB ships an
## authored Open/Close animation that swings the flap on its real hinge, so a
## cartridge can only be seated or pulled while the flap is up. Poking the flap
## with a controller face button toggles it; inserting/removing a cart drives it
## automatically. The ZIF cartridge slides straight back into the socket.
##
## Registered as the default "nes" model (dev-only). GLB is export-excluded
## (licence pending); _ready() self-guards to the placeholder box if it's absent.
class_name RetroSystemModelNES
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/nes_system.glb"
const BUTTON_DEPRESS_DEPTH := 0.0022
const LID_ZONE_RADIUS := 0.10
const INSERT_SLIDE := 0.07        # metres the cart slides in from the flap mouth
const LID_OPEN_DEG := -105.0      # flap swing about its top-rear hinge edge
const LID_ANIM_TIME := 0.35

var _glb: Node3D = null

# Front flap (hinge). The converter bakes all node transforms to identity, which
# breaks the GLB's authored Open/Close clips (they'd pivot about the model
# origin), so the flap is rotated about a hinge edge computed from its own AABB.
var _lid_mesh: MeshInstance3D = null
var _lid_rest: Transform3D = Transform3D.IDENTITY
var _lid_pivot: Vector3 = Vector3.ZERO   # hinge point in the flap's parent space
var _lid_amount: float = 0.0             # 0 = shut … 1 = fully open
var _lid_tween: Tween = null

var _power_light_mesh: MeshInstance3D = null
var _power_light_mats: Array[StandardMaterial3D] = []
var _power_button: VRButton = null

var _cartridge_slot: Node3D = null
var _cartridge_insert_dir: Vector3 = Vector3.FORWARD

# Front-flap (hinge) interaction
var _lid_open: bool = false
var _lid_local_pos: Vector3 = Vector3.ZERO
var _has_lid_zone: bool = false
var _controllers_in_lid_zone: Array = []


func _ready() -> void:
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
	add_child(_glb)

	# The GLB ships authored Open/Close/On/Off/Reset clips, but the .bundle→.glb
	# converter bakes node transforms to identity, so their rotation tracks pivot
	# about the model origin (the flap flies off). Stop any autoplay; the flap and
	# buttons are driven directly instead.
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
		ap.active = false

	_hide_clutter(_glb)
	_fix_decal_alpha(_glb)
	_fix_front_band(_glb)
	# Recentre on the visible body and rest the base on the ground.
	var b := _model_aabb(_glb)
	var c := b.position + b.size * 0.5
	_glb.position = Vector3(-c.x, -b.position.y, -c.z)

	# Capture the flap and its hinge: the top-rear edge of the NesLid mesh, along
	# the console's left-right (X) axis. Rotating the flap about this lifts it up.
	_lid_mesh = _glb.find_child("NesLid", true, false) as MeshInstance3D
	if _lid_mesh:
		_lid_rest = _lid_mesh.transform
		var a := _lid_mesh.get_aabb()
		var hinge_local := Vector3(a.position.x + a.size.x * 0.5, a.position.y + a.size.y, a.position.z)
		_lid_pivot = _lid_mesh.transform * hinge_local
		# The Nintendo logo (and any other decal printed on the door) is a separate
		# quad flush with the flap face; parent those to the flap so they swing with
		# the hinge instead of hanging in mid-air when it opens.
		_attach_flap_decals()

	_power_light_mesh = _glb.find_child("PowerLight", true, false) as MeshInstance3D
	if _power_light_mesh:
		_prep_power_light()
		_set_power_light(false)

	# Proximity zone over the flap's finger-slider marker so a face-button press
	# there toggles the hinge (the contextual-action pattern used across RetroVR).
	var finger := _glb.find_child("Finger Button (Slider) Open Deckel", true, false) as Node3D
	if finger:
		_lid_local_pos = to_local(finger.global_position)
		_has_lid_zone = true


# Hide the moulded RF/power leads and their plug ends — RetroVR spawns its own
# video-out cable (attached at the "Cable Plug (YW)" marker). The console body,
# flap, cradle, buttons and LED stay.
func _hide_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			if nm.contains("cable") or nm.contains("plug") or nm.contains("rca") \
					or nm.contains("connector"):
				mi.visible = false
		for ch in n.get_children():
			stack.append(ch)


# The printed labels/logos are decal quads whose atlas has a transparent
# background, but the .bundle→.glb converter leaves the material OPAQUE, so the
# alpha-0 background renders as its underlying white and boxes the text. Give any
# textured surface with an alpha channel alpha-scissor (cutout) so the background
# is discarded. Surfaces that are actually opaque keep every pixel (alpha > 0.5)
# and are unchanged.
func _fix_decal_alpha(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var mat := mi.get_active_material(s) as BaseMaterial3D
				if mat == null or mat.albedo_texture == null:
					continue
				var img := mat.albedo_texture.get_image()
				if img == null or img.detect_alpha() == Image.ALPHA_NONE:
					continue
				var dup := mat.duplicate() as BaseMaterial3D
				dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				dup.alpha_scissor_threshold = 0.5
				mi.set_surface_override_material(s, dup)
		for c in n.get_children():
			stack.append(c)


# Parent any decal quad that sits on the flap face (the Nintendo logo) to the
# NesLid mesh so it rotates with the hinge. Spatial test against the flap's own
# (grown) world AABB — the deck, cradle and body-front decals fall outside it.
func _attach_flap_decals() -> void:
	var flap_aabb := (_lid_mesh.global_transform * _lid_mesh.get_aabb()).grow(0.004)
	var to_move: Array[MeshInstance3D] = []
	var stack: Array[Node] = [_glb]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi != _lid_mesh and mi.mesh != null:
			if flap_aabb.has_point(mi.global_transform * mi.get_aabb().get_center()):
				to_move.append(mi)
		for ch in n.get_children():
			stack.append(ch)
	for mi in to_move:
		mi.reparent(_lid_mesh, true)


# Give the power LED an emissive material so it visibly glows red when the console
# is on (and reads as a dark unlit lens when off) instead of just toggling
# visibility. Applied to the reddish lens surface(s) of the PowerLight mesh.
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
	var acc := AABB(); var first := true
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


func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


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


## Swing the flap up on its hinge and enable the cartridge bay.
func play_open() -> void:
	if _lid_open:
		return
	_lid_open = true
	_tween_lid(1.0)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = true


## Swing the flap shut and gate the bay closed.
func play_close() -> void:
	if not _lid_open:
		return
	_lid_open = false
	_tween_lid(0.0)
	if _cartridge_slot != null:
		_cartridge_slot.enabled = false


func _toggle_lid() -> void:
	if _lid_open:
		play_close()
	else:
		play_open()


func _process(_delta: float) -> void:
	if not _has_lid_zone:
		return
	var controllers := get_tree().get_nodes_in_group("xr_controllers")
	if controllers.is_empty():
		controllers = get_tree().root.find_children("*", "XRController3D", true, false)
	for ctrl in controllers:
		if not (ctrl is XRController3D):
			continue
		var xr := ctrl as XRController3D
		var inside: bool = to_local(PokeTip.tip_of(xr)).distance_to(_lid_local_pos) <= LID_ZONE_RADIUS
		var was_inside: bool = xr in _controllers_in_lid_zone
		if inside and not was_inside:
			_controllers_in_lid_zone.append(xr)
			xr.button_pressed.connect(_on_lid_button.bind(xr))
		elif not inside and was_inside:
			_controllers_in_lid_zone.erase(xr)
			if xr.button_pressed.is_connected(_on_lid_button):
				xr.button_pressed.disconnect(_on_lid_button)


func _on_lid_button(action: String, _ctrl: XRController3D) -> void:
	if action == "ax_button" or action == "by_button":
		_toggle_lid()


# --- ports / buttons / cable ----------------------------------------------------

func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_power_button = power_btn
	power_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	reset_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	power_btn.set_latched_pressed(false)
	reset_btn.set_latched_pressed(false)
	if _glb != null:
		var power_finger := _glb.find_child("Finger Button Power", true, false) as Node3D
		var reset_finger := _glb.find_child("Finger Button Reset", true, false) as Node3D
		var power_mesh := _glb.find_child("ButtonPower", true, false) as MeshInstance3D
		var reset_mesh := _glb.find_child("ButtonReset", true, false) as MeshInstance3D
		if power_mesh:
			power_btn.set_button_mesh(power_mesh)   # also hides the placeholder box
		if power_finger:
			power_btn.global_position = power_finger.global_position
			power_btn.set_depress_axis_from_node(power_finger)
		if reset_mesh:
			reset_btn.set_button_mesh(reset_mesh)
		if reset_finger:
			reset_btn.global_position = reset_finger.global_position
			reset_btn.set_depress_axis_from_node(reset_finger)
	for btn in [power_btn, reset_btn]:
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl:
			lbl.hide()


## The two port sockets on the front panel, measured off the shell's own "1" and
## "2" number decals (the Plane_003 / Plane_004 quads at x = 0.0645 / 0.0824,
## z = 0.0978) and dropped to the socket mouths below them.
##
## The GLB's "Cable Plug Port1" marker is NOT the socket: like the PSone's, it is
## where imported parks the plug prop, 2.1 cm proud of the face. And there is no
## Port2 marker at all, so the old lookup left port 2 wherever the scene had put
## it — down at floor level, off to the left of the console.
const _PORT_X := [0.0645, 0.0824]
const _PORT_Y := 0.0301
const _PORT_Z := 0.0975


func configure_controller_ports(port_zones: Array) -> void:
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		if i < _PORT_X.size():
			zone.position = Vector3(_PORT_X[i], _PORT_Y, _PORT_Z)
			# Front-facing socket: roll 180 about Z so the plug seats connector-in
			# and upright (a yaw would land it upside down - see the snap-zone
			# note in plans/bundle-import-notes.md).
			zone.rotation_degrees = Vector3(0, 0, 180)
		var recess := zone.get_node_or_null("PortRecess") as MeshInstance3D
		if recess:
			recess.hide()
		var lbl := zone.get_node_or_null("PortLabel") as Label3D
		if lbl:
			lbl.hide()


func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb != null:
		var marker := _glb.find_child("Cable Plug (YW)", true, false) as Node3D
		if marker:
			attach_point.global_position = marker.global_position
	var port_visual := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if port_visual:
		port_visual.hide()


# --- cartridge (front-load: slides straight back into the ZIF socket) -----------

func configure_cartridge_slot(slot: Node3D) -> void:
	_cartridge_slot = slot
	if _glb != null:
		# Seat the cart in the visible cradle under the flap; take the insert axis
		# (the console's front→back direction) from the socket marker's orientation.
		var cradle := _glb.find_child("NesCradle", true, false) as MeshInstance3D
		if cradle:
			# Lay the cart FLAT, label up, connector pointing into the machine. A
			# cartridge is authored connector -Y / label +Z, so map its +Y (grip)
			# onto +Z (out the front) and its +Z (label) onto world up; X inverts to
			# keep it a rotation. Without this the cart stood on end in the tray.
			slot.global_transform = Transform3D(
				Basis(Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)),
				cradle.global_transform * cradle.get_aabb().get_center())
		var socket := _glb.find_child("System Socket", true, false) as Node3D
		if socket:
			_cartridge_insert_dir = socket.global_transform.basis.z.normalized()
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


## The shell mesh's surface 2 is a near-black material (albedo 0.004) applied to a
## vertical band across the front-right, running the full height of the console
## and over the top face. No NES has that - the front panel is one grey. It reads
## as a black slab stuck to the machine, so repaint it in the shell's own grey.
##
## Surface-level override, not a material edit: the same black material is shared
## with NesCradle, which is genuinely black and must stay that way.
const _BAND_SURFACE := 2


func _fix_front_band(root: Node3D) -> void:
	var deck := root.find_child("NesDeck", true, false) as MeshInstance3D
	if deck == null or deck.mesh == null or deck.mesh.get_surface_count() <= _BAND_SURFACE:
		return
	var shell: Material = deck.get_active_material(0)
	var band: Material = deck.get_active_material(_BAND_SURFACE)
	if not (shell is BaseMaterial3D and band is BaseMaterial3D):
		return
	var fixed := (band as BaseMaterial3D).duplicate() as BaseMaterial3D
	fixed.albedo_color = (shell as BaseMaterial3D).albedo_color
	deck.set_surface_override_material(_BAND_SURFACE, fixed)
