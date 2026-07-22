## RetroSystemModelPlaystationOne — PS1 (PSone) disc-tray console model.
##
## Loads an author's imported PSone GLB and wires the power/open buttons, the CD lid,
## the disc seat, memory-card slot, controller ports and cable. LOADER_TRAY:
## RetroSystem calls play_open()/play_close() to swing the lid.
##
## The shell scene (playstation_one.tscn) owns the lid's LidPivot + its VRHinge,
## so the lid can also be lifted BY HAND, the same way the 3DS clamshell works.
## Both paths drive the one pivot, and a hand-swing reports the tray state back
## to RetroSystem so the disc becomes grabbable exactly when the lid is up.
##
## Dev-only: the GLB lives in export-excluded imported-assets/ (licence pending);
## _ready() self-guards and re-shows the placeholder box if the GLB is absent.
class_name RetroSystemModelPlaystationOne
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/playstation_one.glb"

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid_pivot: Node3D = null
var _hinge: VRHinge = null


func _ready() -> void:
	# Store-safe guard — ResourceLoader.exists (NOT FileAccess; false in pck).
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("PlaystationOneModel: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var ps := load(_MODEL_PATH) as PackedScene
	if ps == null:
		push_warning("PlaystationOneModel: failed to load %s" % _MODEL_PATH)
		return
	_glb = ps.instantiate() as Node3D
	# Disable the GLB's auto-played animation so the lid keeps its REST pose, which
	# is the closed lid (verified by diagnostic). PSOneClose is broken — don't use.
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""
	add_child(_glb)
	# Hide bundled cables/plugs — RetroVR spawns its own controllers + AV cable.
	for extra in ["controller_plug_002", "RCA_Silver"]:
		var e := _glb.find_child(extra, true, false) as Node3D
		if e != null:
			e.visible = false
	# Recentre on the console body in X/Z (base already rests near y=0).
	var xz := _visible_xz_center(_glb)
	_glb.position = Vector3(-xz.x, 0.0, -xz.y)
	_mount_lid()


func _visible_xz_center(root: Node3D) -> Vector2:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


# World position of a GLB marker empty (accounts for the recentre offset).
func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


## Half-depth of the scene's PortRecess/slot box, so the recess sits FLUSH in the
## front face rather than half-buried or floating proud of it.
const _PORT_INSET := 0.0025


## World-space centre of a GLB mesh's bounding box. Preferred over the marker
## empties on this model — several of them describe accessories (a cable plug,
## the lid centre) rather than the part they're named after.
func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var mi := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mi == null or mi.mesh == null:
		return global_position
	var ab: AABB = mi.global_transform * mi.get_aabb()
	return ab.position + ab.size * 0.5


## World z of the console's front face (the shell's own +Z extent).
func _front_face_z() -> float:
	if _glb == null:
		return global_position.z
	var mi := _glb.find_child("psone_console", true, false) as MeshInstance3D
	if mi == null or mi.mesh == null:
		return global_position.z
	return ((mi.global_transform * mi.get_aabb()) as AABB).end.z


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return true


# --- disc lid: RetroSystem drives these for LOADER_TRAY consoles ---
#
# The GLB's own PSOneOpen clip is UNUSABLE: bundle_convert.py bakes every node
# transform to identity, so the authored hinge pivot is lost and the clip
# rotates the lid about the model origin — it swung 5 cm sideways and ended up
# BEHIND the console (measured open centre (0.053, 0.012, -0.100) against a
# body that stops at z=-0.072). Same failure as the NES flap. Rotate about the
# lid's own real hinge instead: its back-bottom edge, axis +X.
const LID_OPEN_DEG := 70.0
const LID_SWING_TIME := 0.55
## Hand-swing thresholds (with hysteresis) at which the tray is reported open /
## closed, so a half-lifted lid doesn't chatter the state.
const _LID_OPEN_AT := 45.0
const _LID_CLOSE_AT := 25.0

var _lid_tween: Tween = null


## Move the GLB's lid mesh under the scene's LidPivot, placed at the lid's REAL
## hinge — the back-bottom edge of its own bounding box.
##
## The 180° yaw lives on LidMount, the pivot's PARENT, not on the pivot itself.
## VRHinge measures the hand's angle in the target's PARENT frame while applying
## it as the target's local rotation.x, so those two frames have to agree: with
## the yaw on the pivot, every drag mapped into the second quadrant and clamped
## straight to max_deg (the lid was un-draggable). The yaw is needed at all
## because VRHinge expects the hinged leaf to lie along -Z, and the PSone's lid
## extends +Z from its hinge — the mirror of the 3DS clamshell it was written for.
func _mount_lid() -> void:
	var mount := get_node_or_null("LidMount") as Node3D
	_lid_pivot = get_node_or_null("LidMount/LidPivot") as Node3D
	var lid := _glb.find_child("psone_cd_lid", true, false) as MeshInstance3D
	if mount == null or _lid_pivot == null or lid == null:
		return
	var ab: AABB = lid.global_transform * lid.get_aabb()
	mount.global_transform = Transform3D(
		global_transform.basis * Basis(Vector3.UP, PI),
		Vector3(ab.get_center().x, ab.position.y, ab.position.z))
	var world := lid.global_transform
	lid.reparent(_lid_pivot, false)
	lid.global_transform = world
	_hinge = _lid_pivot.get_node_or_null("LidHinge") as VRHinge
	if _hinge != null:
		_hinge.max_deg = LID_OPEN_DEG
		_hinge.rotation_changed.connect(_on_lid_hand_swung)


func play_open() -> void:
	_swing_lid(LID_OPEN_DEG)

func play_close() -> void:
	_swing_lid(0.0)


func _swing_lid(target_deg: float) -> void:
	if _lid_pivot == null:
		return
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_lid_tween = create_tween()
	_lid_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Tween from wherever the lid ACTUALLY is (a hand may have left it part-way).
	_lid_tween.tween_method(_set_lid_angle,
		rad_to_deg(_lid_pivot.rotation.x), target_deg, LID_SWING_TIME)


func _set_lid_angle(deg: float) -> void:
	_lid_pivot.rotation.x = deg_to_rad(deg)


## Lifting or pushing the lid by hand IS opening/closing the tray — tell the host
## so the disc becomes grabbable and the OPEN button's latch follows. The tween
## is killed first: the hand owns the lid while it's being dragged.
func _on_lid_hand_swung(deg: float) -> void:
	var host := get_parent()
	if host != null and host.has_method("request_tray_state"):
		if deg >= _LID_OPEN_AT:
			host.request_tray_state(true)
		elif deg <= _LID_CLOSE_AT:
			host.request_tray_state(false)
	# Killed AFTER the state change, which routes back through play_open/close:
	# the hand is holding the lid, so cancel the swing it just kicked off.
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()


# --- buttons ---
#
# Anchor empties DON'T line up with the buttons here: "OpenClose" sits at the
# lid centre (x=0.009) and "Eject" is over the OPEN button mesh (x=0.075) — so
# the OPEN button was wired to the lid centre and RESET landed on top of OPEN.
# Take every button pose from its own mesh instead; the geometry can't lie.
# The PSone has only TWO physical buttons: one 30 mm round button on the left
# and one on the right (OPEN). The left one is printed "⏻ / RESET" — a single
# control serving both, with the power glyph toward the console's BACK and the
# word RESET toward the FRONT. Split its touch zone along that printed line so
# each half does what it says, both depressing the same mesh.
const _PWR_SPLIT := 0.007

func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "psone_button_power_reset", Vector3(0, 0, -_PWR_SPLIT))
	_wire_button(reset_btn, "psone_button_power_reset", Vector3(0, 0, _PWR_SPLIT))
	_wire_button(eject_btn, "psone_button_open")


func _wire_button(btn: VRButton, mesh_name: String, offset: Vector3 = Vector3.ZERO) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
		var ab: AABB = mesh.global_transform * mesh.get_aabb()
		btn.global_position = ab.position + ab.size * 0.5 + offset
	btn.depress_depth = 0.0025
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- disc seat / ports / cable / memory card ---
func configure_cartridge_slot(slot: Node3D) -> void:
	# Seat the disc on socket_media, NOT the spindle: the spindle marker sits at
	# the rotor's own height (y≈0.0245), which is *inside* the laser assembly
	# (y 0.0212–0.0290) — the disc sank into the mechanism instead of resting on
	# it. socket_media is the same point raised clear of the laser cover.
	slot.global_position = _anchor("socket_media")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## Both ports live on the FRONT face, directly under the two memory-card slots.
##
## The "Playstation Controller Plug 1" empty is NOT the port — it's the far end
## of the cable plug, 2.7 cm out in front of a body that stops at z=+0.072, so
## both zones hung in mid-air (and port 2, derived as port 1 minus 45 mm, sat off
## by the left edge instead of mirrored). The card-slot meshes give the true port
## columns: their x centres are the port x centres on real hardware.
func configure_controller_ports(port_zones: Array) -> void:
	var y := _anchor("Playstation Controller Plug 1").y   # port row height (correct)
	var z := _front_face_z() - _PORT_INSET
	var cols := [_mesh_center("psone_memcard_slot_01"), _mesh_center("psone_memcard_slot_02")]
	for i in range(port_zones.size()):
		# The shell models its own ports and prints its own "1"/"2" — drop the
		# generic black recess box and the floating number (same as nes_model).
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		if i < cols.size():
			port_zones[i].global_position = Vector3(cols[i].x, y, z)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("Cable Plug (S)")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## Slot 1 is modelled — a thin plate on the front face at (x=-0.034, y=0.018).
## (It was previously derived from the controller-plug empty + a guessed offset,
## which put the card in mid-air above the console.)
func configure_memory_card_slot(slot: Node3D) -> void:
	var c := _mesh_center("psone_memcard_slot_01")
	slot.global_position = Vector3(c.x, c.y, _front_face_z() - _PORT_INSET)


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.2, 0.045, 0.18)
	var pos := Vector3(0.0, 0.022, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
