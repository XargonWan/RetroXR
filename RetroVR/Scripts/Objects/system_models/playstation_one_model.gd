## RetroSystemModelPlaystationOne — PS1 (PSone) disc-tray console model.
##
## Loads an author's PSone GLB and wires the power/open buttons, the CD lid,
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

## Overridable shell description. A sibling PlayStation shell (the full-size
## original) subclasses this model and swaps these out; everything else — the
## lid rig, the hinge/tray sync, the disc seat — is shared.
func _model_path() -> String:
	return "res://unbundled-models/consoles/playstation_one.glb"

## Yaw applied to the GLB so the shell's FRONT faces +Z, the frame every
## placement below assumes. 0 when the model is already authored that way.
func _shell_yaw() -> float:
	return 0.0

## Bundled cables/plugs/props to hide — RetroVR spawns its own. The A/V plug prop
## (see _av_plug_mesh) is deliberately NOT in here: it stays visible as the video
## connector the spawned A/V rope hangs off.
func _hidden_meshes() -> PackedStringArray:
	return PackedStringArray(["controller_plug_002"])

## The shell's own A/V (composite/RCA) plug prop, kept visible so the video lead
## visibly leaves a connector instead of the back panel's empty air.
func _av_plug_mesh() -> String:
	return "RCA_Silver"

func _shell_mesh() -> String:
	return "psone_console"

func _lid_mesh() -> String:
	return "psone_cd_lid"

## Marker the disc rests on.
func _disc_seat_marker() -> String:
	return "socket_media"

## Marker for the A/V out on the back.
func _cable_marker() -> String:
	return "Cable Plug (S)"

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid_pivot: Node3D = null
var _hinge: VRSpringLatchedHinge = null


func _ready() -> void:
	# Store-safe guard — ResourceLoader.exists (NOT FileAccess; false in pck).
	# The scene's own stand-in shell (ConsoleBody + LidPlate) is the fallback and
	# is already visible, so there's nothing to switch on: it's a PSone-shaped
	# body with a working hinge rather than the host's generic SystemBody box.
	# An authored scene may bake the shell as a "Shell" instance plus an
	# editor-authorable "DiscSeat" marker (cylinder "SeatPreview") riding it. Reuse
	# the instance when present, otherwise load the GLB the old runtime way.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		var model_path := _model_path()
		if not ResourceLoader.exists(model_path):
			push_warning("%s: %s missing — using the scene's stand-in shell" % [name, model_path])
			return
		var ps := load(model_path) as PackedScene
		if ps == null:
			push_warning("%s: failed to load %s" % [name, model_path])
			return
		_glb = ps.instantiate() as Node3D
		add_child(_glb)
	# The seat previews (DiscSeat's and MemCardSeat's) are editor aids only —
	# hide all matches before the recentre AABB, not just the first found.
	for preview in find_children("SeatPreview", "", true, false):
		if preview is Node3D:
			(preview as Node3D).visible = false
	# Disable the GLB's auto-played animation so the lid keeps its REST pose, which
	# is the closed lid (verified by diagnostic). PSOneClose is broken — don't use.
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""
	# Hide bundled cables/plugs — RetroVR spawns its own controllers + AV cable.
	for extra in _hidden_meshes():
		var e := _glb.find_child(extra, true, false) as Node3D
		if e != null:
			e.visible = false
	# Turn the shell so its front faces +Z, then recentre on the console body in
	# X/Z (base already rests near y=0). The yaw must come FIRST — the recentre
	# is measured in the rotated frame. Skipped when the scene has pre-baked the
	# yaw+recentre into Shell.transform (metadata/shell_prebaked) — needed for a GLB
	# whose native frame is offset far from origin (the full-size original), so the
	# editor shows it home and the DiscSeat child lands on the console.
	if not has_meta("shell_prebaked"):
		var yaw := _shell_yaw()
		if not is_zero_approx(yaw):
			_glb.basis = Basis(Vector3.UP, yaw)
		# The A/V plug prop stays visible (it's the video rope's connector) but hangs
		# ~4.5 cm off the back, so keep it out of the recentre AABB: hide it across the
		# measurement, then bring it back.
		var plug := _glb.find_child(_av_plug_mesh(), true, false) as Node3D
		if plug != null:
			plug.visible = false
		var xz := _visible_xz_center(_glb)
		_glb.position = Vector3(-xz.x, 0.0, -xz.y)
		if plug != null:
			plug.visible = true
	# The real shell is in — retire the scene's stand-in boxes. They exist so the
	# .tscn shows a PSone (and a swingable lid) when opened in the editor, where
	# the GLB isn't instanced, and so a build without the GLB still gets a shell.
	for path in ["ConsoleBody", "LidMount/LidPivot/LidPlate"]:
		var ph := get_node_or_null(path) as MeshInstance3D
		if ph != null:
			ph.hide()
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
## memory_card.tscn's box is 75 mm along its Z (the insertion axis); leave this
## much of it standing proud of the face when seated.
const _CARD_LENGTH := 0.075
const _CARD_PROTRUDE := 0.022


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
	var mi := _glb.find_child(_shell_mesh(), true, false) as MeshInstance3D
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
	var lid := _glb.find_child(_lid_mesh(), true, false) as MeshInstance3D
	if mount == null or _lid_pivot == null or lid == null:
		return
	var ab: AABB = lid.global_transform * lid.get_aabb()
	mount.global_transform = Transform3D(
		global_transform.basis * Basis(Vector3.UP, PI),
		Vector3(ab.get_center().x, ab.position.y, ab.position.z))
	var world := lid.global_transform
	lid.reparent(_lid_pivot, false)
	lid.global_transform = world
	# The LidHinge is now a VRSpringLatchedHinge (see the .tscn): the OPEN button
	# springs it fully up; the hand pulls it down to close (release near-shut latches,
	# release mid springs back open); the hand can't start an open from closed.
	_hinge = _lid_pivot.get_node_or_null("LidHinge") as VRSpringLatchedHinge
	if _hinge != null:
		_hinge.min_deg = 0.0
		_hinge.max_deg = LID_OPEN_DEG
		_hinge.rotation_changed.connect(_on_lid_hand_swung)


func has_spring_latched_lid() -> bool:
	return _hinge != null


func play_open() -> void:
	if _hinge != null:
		_hinge.open()

func play_close() -> void:
	if _hinge != null:
		_hinge.latch_closed()


## A hand-swing that LATCHES the lid shut is the player closing the tray — tell the
## host so the disc becomes ungrabbable and the OPEN button's state follows. Opening
## is button-only, so nothing to report there.
func _on_lid_hand_swung(_deg: float) -> void:
	if _hinge != null and _hinge.is_latched_closed():
		var host := get_parent()
		if host != null and host.has_method("request_tray_state"):
			host.request_tray_state(false)


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
	slot.global_position = _anchor(_disc_seat_marker())
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "DiscSeat" marker (baked into the scene, riding the Shell) wins
	# over the seat marker above, so the disc rest can be dialled in visually in the
	# editor. Absent → keep the GLB seat-marker pose.
	var seat := find_child("DiscSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


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
		# An authored "PortSeat1"/"PortSeat2" marker (baked into
		# playstation_one.tscn) wins over the computed pose below, same
		# "authored wins over computed" idiom as CartSeat/DiscSeat/UMDSeat —
		# so the port pose can be dialled in visually in the editor.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			port_zones[i].global_transform = seat.global_transform
			continue
		if i < cols.size():
			# Rolled 180° about Z. A ControllerPlug's connector points down its +Z
			# with the cable trailing -Z, so a front-facing port needs the plug
			# turned to face the player — but the zone's basis is NOT the plug's
			# final pose: ControllerPlug carries a SnapGrabPoint rotated 180° about
			# X, which the snap composes on top. Measured with a plain 180° yaw
			# here, the plug came out diag(-1,-1,1) — upside down with the
			# connector pointing back OUT of the console. Rolling instead cancels
			# that flip and lands the plug at yaw-180: upright, connector inward.
			# (Invisible on consoles still using the symmetric cylinder plug.)
			port_zones[i].global_transform = Transform3D(
				global_transform.basis * Basis(Vector3.BACK, PI),
				Vector3(cols[i].x, y, z))


func configure_cable_attach(attach_point: Node3D) -> void:
	# Off the visible A/V plug's tip; the GLB's cable marker is the fallback.
	attach_point.global_position = av_plug_cable_end(
		_glb.find_child(_av_plug_mesh(), true, false) if _glb != null else null,
		_anchor(_cable_marker()))
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## Slot 1 is modelled — a thin plate on the front face at (x=-0.034, y=0.018).
## (It was previously derived from the controller-plug empty + a guessed offset,
## which put the card in mid-air above the console.)
func configure_memory_card_slot(slot: Node3D) -> void:
	# An authored "MemCardSeat" marker (baked into playstation_one.tscn) wins
	# over the computed pose below, same idiom as the controller ports above.
	var seat := find_child("MemCardSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform
		return
	var c := _mesh_center("psone_memcard_slot_01")
	# Sunk in by half the card's length less _CARD_PROTRUDE: the zone seats a card
	# on its CENTRE, so parking it on the face alone left the card half-hanging
	# out of the console like a shelf. Seat it inserted, with a real card's worth
	# of grip left proud so it can still be pulled back out.
	slot.global_position = Vector3(c.x, c.y,
		_front_face_z() - _PORT_INSET - (_CARD_LENGTH * 0.5 - _CARD_PROTRUDE))


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.2, 0.045, 0.18)
	var pos := Vector3(0.0, 0.022, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
