## RetroSystemModelPlaystation — PlayStation 1 console model.
class_name RetroSystemModelPlaystation
extends RetroSystemModel

const _MODEL_PATH := "res://unbundled-models/consoles/King PSX.glb"

## Disc-lid open angle (degrees) about the console's left-right axis. Negative
## lifts the front edge up; the hinge is the lid node's own origin (rear-top edge).
const LID_OPEN_DEG := -78.0

var _lid: Node3D = null
var _lid_closed: Transform3D
var _lid_open: Transform3D
var _lid_tween: Tween
var _lid_poses_ready := false

var _power_light: OmniLight3D = null
var _led: MeshInstance3D = null


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("RetroSystemModelPlaystation: could not load model at %s" % _MODEL_PATH)
		return
	var inst := scene.instantiate() as Node3D
	# The GLB's front faces +X and it's authored far from its own origin. Rotate
	# its front to +Z (the cabinet front, where the controller ports and the
	# memory-card slot sit), then recentre it in X/Z on the origin (its body base
	# is already at y=0). Recentring is computed from the rotated mesh AABB so it
	# stays correct regardless of the rotation or a future re-export.
	inst.rotation_degrees.y = -90.0
	add_child(inst)
	var xz := _model_xz_center(inst)
	inst.position = Vector3(-xz.x, 0.0, -xz.y)

	# Disc lid (CD cover): its node origin is the rear-top hinge, so opening is a
	# rotation about the console's left-right axis through that origin. Poses are
	# computed lazily on first open (see _ensure_lid_poses) — global_transform is
	# not settled yet here in _ready.
	_lid = inst.find_child("DeckelPSX", true, false)

	# Power LED: the GLB ships a very bright always-on OmniLight (energy 3.14) that
	# blooms hard — worse, it lights the metallic buttons/shell into a big glare.
	# A real power LED doesn't illuminate the room, so disable the light entirely
	# and represent the LED with a small emissive mesh instead (driven by power).
	_power_light = inst.find_child("Power Light", true, false) as OmniLight3D
	if _power_light:
		_power_light.visible = false
	_led = inst.find_child("Licht PSX 2000", true, false) as MeshInstance3D
	_set_led(false)


## Combined X/Z centre of all of `inst`'s meshes, expressed in this model node's
## local space (call after add_child, before setting inst.position).
func _model_xz_center(inst: Node3D) -> Vector2:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			if first:
				acc = ab
				first = false
			else:
				acc = acc.merge(ab)
		for ch in n.get_children():
			stack.append(ch)
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


## Rest the console body on the ground. The default console collision box bottoms
## out at y=-0.05, but this model's body base is at y=0 — without this it would
## float 5 cm once recentred.
func configure_collision(host: Node3D) -> void:
	# Size BOTH the pickup box and the pointer-grab proxy (PointerArea) to the
	# console with their tops just below the top/front buttons (~y 0.051). The
	# PointerArea box otherwise reaches y=0.07 and, being closer than the button
	# Area3Ds, steals the desktop pointer ray — so buttons can't be clicked or
	# highlighted (VR poke still works, it's proximity-based).
	var box := Vector3(0.2, 0.046, 0.28)
	var pos := Vector3(0.0, 0.023, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


## Open/close the CD lid (driven by the OPEN button via RetroSystem's tray state).
func play_open() -> void:
	_ensure_lid_poses()
	_tween_lid(_lid_open)


func play_close() -> void:
	_ensure_lid_poses()
	_tween_lid(_lid_closed)


## Capture the closed pose and derive the open pose the first time the lid moves,
## when the console's global transform has settled. The lid stays closed until the
## OPEN button is pressed, so _lid.transform here is always the rest (closed) pose.
func _ensure_lid_poses() -> void:
	if _lid_poses_ready or _lid == null:
		return
	_lid_poses_ready = true
	_lid_closed = _lid.transform
	var axis := global_transform.basis.x.normalized()
	var g0 := _lid.global_transform
	var g_open := Transform3D(Basis(axis, deg_to_rad(LID_OPEN_DEG)) * g0.basis, g0.origin)
	_lid_open = (_lid.get_parent() as Node3D).global_transform.affine_inverse() * g_open


func _tween_lid(target: Transform3D) -> void:
	if _lid == null:
		return
	if _lid_tween and _lid_tween.is_valid():
		_lid_tween.kill()
	# Interpolate via Transform3D.interpolate_with (slerp rotation + lerp scale) —
	# a plain tween_property on a Transform3D lerps the raw basis components, which
	# mangles this lid's heavily-scaled basis (the GLB cm->m factor) mid-animation.
	var from := _lid.transform
	_lid_tween = create_tween()
	_lid_tween.tween_method(
		func(t: float) -> void: _lid.transform = from.interpolate_with(target, t),
		0.0, 1.0, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


## Drive the console's physical POWER/RESET/OPEN buttons instead of the placeholder
## VR button squares: each VRButton is moved onto its GLB button, uses that mesh for
## the depress animation, takes its press direction from the matching "Finger Button"
## empty, and hides the placeholder label.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "Start", "Finger Button Power")
	_wire_button(reset_btn, "Reset Taste", "Finger Button Rest")
	_wire_button(eject_btn, "Opern Taste", "Finger Button Open")


func _wire_button(btn: VRButton, mesh_name: String, finger_name: String) -> void:
	if btn == null:
		return
	var mesh := find_child(mesh_name, true, false) as MeshInstance3D
	var finger := find_child(finger_name, true, false) as Node3D
	if mesh:
		btn.set_button_mesh(mesh)   # also hides the placeholder square
	var anchor: Node3D = finger if finger else mesh
	if anchor:
		btn.global_position = anchor.global_position
	# These buttons are on the top face and press straight down. The GLB finger
	# empties' -Z points sideways here (the model is rotated -90 deg), so drive the
	# travel from world-down instead of the empty.
	btn.depress_depth = 0.0035
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.hide()


## Light the power LED only while the console is on — a subtle green glow.
func on_power_on() -> void:
	_set_led(true)


func on_power_off() -> void:
	_set_led(false)


func _set_led(on: bool) -> void:
	if _led == null:
		return
	var mat := _led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or not mat.resource_local_to_scene:
		mat = StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		_led.set_surface_override_material(0, mat)
	mat.albedo_color = Color(0.15, 0.85, 0.3) if on else Color(0.12, 0.18, 0.12)
	mat.emission_enabled = on
	# Keep emission just under the glow HDR threshold (~1.0) so the tiny LED reads
	# as a lit green dot with only a faint halo, not a blown-out bloom.
	mat.emission = Color(0.25, 0.9, 0.4)
	mat.emission_energy_multiplier = 0.9 if on else 0.0


func get_controller_port_count() -> int:
	return 2


## PSX saves live on removable memory cards (PCSX-ReARMed exposes memcard 1
## as RETRO_MEMORY_SAVE_RAM).
func uses_memory_cards() -> bool:
	return true


## Video-out where the cable/rope attaches — the AV/power output on the back.
## The placeholder gray cylinder (PortVisual) is hidden; the model has its own port.
func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.position = Vector3(-0.04, 0.02, -0.126)
	var visual := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if visual:
		visual.visible = false


## The two controller ports sit on the front face, below the memory-card slots.
func configure_controller_ports(port_zones: Array) -> void:
	if port_zones.size() >= 1:
		port_zones[0].position = Vector3(-0.032, 0.02, 0.12)
	if port_zones.size() >= 2:
		port_zones[1].position = Vector3(0.03, 0.02, 0.12)


## Put the card slot on the front-left of the console, next to controller port 1.
func configure_memory_card_slot(slot: Node3D) -> void:
	slot.position = Vector3(-0.09, 0.02, 0.14)


## Seat the disc on the CD rotor inside the bay (exposed when the lid opens),
## not the default slot floating above the console centre. The rotor sits at
## ~(0, 0.047, 0.011) in the console's local space.
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.position = Vector3(0.0, 0.05, 0.011)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
