## RetroSystemModelPSP — Sony PlayStation Portable (PSP-1000, 480×272 widescreen).
##
## Uses an author's detailed imported shell (psp_1000.glb), which — unlike the
## older bare shell — models every control as its own mesh: the ✕○□△ face
## buttons, the d-pad, the analog nub, the L/R shoulders, Start/Select/Home, the
## volume ± and sound/display keys, the slide POWER switch, the EJECT latch and
## the UMD door. That is what lets the pad animate and the tray open.
##
## Media is the UMD (psp_umd.glb, systemid "playstation_portable"), which loads
## through the back-edge UMD door rather than a top slot.
class_name RetroSystemModelPSP
extends RetroSystemModelHandheld


## The PSP-1000 shell suffixes its lens mesh "screen_mesh_0".
func _glb_screen_name() -> String:
	return "screen_mesh_0"


func _glb_path() -> String:
	return "res://imported-assets/psp_1000.glb"


## Store-safe primitive stand-in (spawned only when the GLB shell is absent
## and the .tscn hasn't baked a "Shell" instance — see handheld_model.gd).
func _primitive_path() -> String:
	return "res://Scenes/Objects/system_models/psp_primitive.tscn"


# --- button animation -------------------------------------------------------

## PSP face diamond → RetroPad. ✕ is the confirm/B button, ○ back/A, □ Y, △ X —
## the same glyph-position convention RetroPad already uses.
const _FACE_MESH: Dictionary = {
	ControllerBindings.JOYPAD_B: "FireButtonBottom",   # ✕
	ControllerBindings.JOYPAD_A: "FireButtonRight",    # ○
	ControllerBindings.JOYPAD_Y: "FireButtonLeft",     # □
	ControllerBindings.JOYPAD_X: "FireButtonTop",      # △
	ControllerBindings.JOYPAD_START:  "StartButton",
	ControllerBindings.JOYPAD_SELECT: "SelectButton",
}
const _SHOULDER_MESH: Dictionary = {
	ControllerBindings.JOYPAD_L: "LShoulderButton",
	ControllerBindings.JOYPAD_R: "RShoulderButton",
}

const _FACE_PRESS := 0.0016
const _SHOULDER_PRESS := 0.0030
const _NUB_SLIDE := 0.0022
const _DPAD_TILT_DEG := 9.0
const _ANIM_W := 0.4
## Press axis in the button meshes' PARENT frame ("Shell") — set from the
## face-button normal at cache time, since the GLB carries its own baked
## lay-back rotation (Shell is rotated ~-90° about X relative to this model
## node) and every animated mesh's `.transform` is local to that same Shell,
## not to this node.
var _press_dir := Vector3(0, 0, -1)
## This model's "up" (screen-normal) direction expressed in Shell's local
## frame — the frame-consistent counterpart to _press_dir for building a
## sideways axis (nub slide, power switch slide).
var _shell_up := Vector3.UP

var _anim_cached := false
var _anim_btns: Array[Dictionary] = []   # {node, rest, bit, depth}
var _anim_nub: Dictionary = {}           # analog nub: {node, rest, pivot}
var _anim_dpad: Dictionary = {}          # {node, rest, pivot}


func _on_glb_ready() -> void:
	_cache_anim_meshes()
	_configure_power_slide()
	_configure_umd_door()
	_configure_power_led()


func _cache_anim_meshes() -> void:
	if _anim_cached:
		return
	_anim_cached = true
	# Press direction: into the face, i.e. the negated screen normal, expressed
	# in the button meshes' own parent frame (Shell) — every animated mesh's
	# .transform lives there, NOT in this model node's frame, and Shell carries
	# its own baked lay-back rotation relative to this node. Averaged over the
	# button and snapped to an axis — a single triangle's normal catches a
	# bevelled side (the PSP's read as diagonal).
	var probe := find_child("FireButtonBottom", true, false) as MeshInstance3D
	if probe != null:
		var shell := probe.get_parent() as Node3D
		if shell != null:
			_press_dir = -_axis_normal(probe, shell)
			_shell_up = shell.global_transform.basis.inverse() * Vector3.UP
	for map: Dictionary in [_FACE_MESH, _SHOULDER_MESH]:
		var depth: float = _FACE_PRESS if map == _FACE_MESH else _SHOULDER_PRESS
		for bit: int in map:
			var m := find_child(map[bit], true, false) as MeshInstance3D
			if m != null:
				_anim_btns.append({"node": m, "rest": m.transform, "bit": bit, "depth": depth})
	# Analog nub: mesh "StickLeft2", pivot empty "StickLeft".
	var nub := find_child("StickLeft2", true, false) as MeshInstance3D
	if nub != null:
		_anim_nub = {"node": nub, "rest": nub.transform, "pivot": _pivot_of(nub, "StickLeft")}
	# D-pad: mesh "Dpad2", pivot empty "Dpad".
	var dpad := find_child("Dpad2", true, false) as MeshInstance3D
	if dpad != null:
		_anim_dpad = {"node": dpad, "rest": dpad.transform, "pivot": _pivot_of(dpad, "Dpad")}


## btn = RETRO_JOYPAD bitmask; lstick/rstick are the analog values (−1..1) as sent
## to the core (y already screen-negated). Lerps the meshes toward that state.
func animate_controls(btn: int, lstick: Vector2, _rstick: Vector2) -> void:
	if not _anim_cached:
		_cache_anim_meshes()

	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var down := 1.0 if (btn & (1 << int(e["bit"]))) != 0 else 0.0
		var tgt := Transform3D(rest.basis, rest.origin + _press_dir * (float(e["depth"]) * down))
		node.transform = node.transform.interpolate_with(tgt, _ANIM_W)

	if not _anim_nub.is_empty():
		# The nub slides in-plane. The plane is perpendicular to the press axis;
		# lstick.x runs across the face, lstick.y up it (already screen-negated).
		var ax := _shell_up.cross(_press_dir).normalized()
		if ax.length() < 0.5:
			ax = Vector3.RIGHT
		var ay := _press_dir.cross(ax).normalized()
		var off := (ax * lstick.x + ay * lstick.y) * _NUB_SLIDE
		var node: MeshInstance3D = _anim_nub["node"]
		var rest: Transform3D = _anim_nub["rest"]
		node.transform = node.transform.interpolate_with(Transform3D(rest.basis, rest.origin + off), _ANIM_W)

	if not _anim_dpad.is_empty():
		var pitch := float((btn >> ControllerBindings.JOYPAD_UP) & 1) - float((btn >> ControllerBindings.JOYPAD_DOWN) & 1)
		var roll := float((btn >> ControllerBindings.JOYPAD_LEFT) & 1) - float((btn >> ControllerBindings.JOYPAD_RIGHT) & 1)
		# Screen-up handheld: UP/DOWN tilt about the console's left-right axis (X),
		# LEFT/RIGHT about the front-back axis. Pitch is negated so UP pushes the
		# far edge into the shell, matching the 3DS. This rotation is built and
		# applied in Shell's LOCAL frame (Dpad2's .transform lives there), and
		# Shell carries a ~-90° lay-back about X relative to this model node —
		# so "front-back" in the model's own frame is Shell's local Y axis, not
		# Z (rotating about Shell's Z instead, as a naive port of the 3DS code
		# would, spins the whole pad around the screen-normal axis — exactly the
		# "rolling" bug this was fixed from).
		var r := Basis.from_euler(Vector3(deg_to_rad(-pitch * _DPAD_TILT_DEG), deg_to_rad(-roll * _DPAD_TILT_DEG), 0.0))
		var node: MeshInstance3D = _anim_dpad["node"]
		var rest: Transform3D = _anim_dpad["rest"]
		var pivot: Vector3 = _anim_dpad["pivot"]
		var about := Transform3D(r, pivot - r * pivot)
		node.transform = node.transform.interpolate_with(about * rest, _ANIM_W)


# --- power slide ------------------------------------------------------------

## The PSP powers on with a SLIDE, not a button — the switch on the right edge
## pushes up. The GLB's On clip translates PowerButton, so drive the real mesh
## from the base's _power_switch value instead of hiding it under a primitive.
var _power_mesh: MeshInstance3D = null
var _power_rest := Transform3D.IDENTITY
const _POWER_SLIDE := 0.004


func _configure_power_slide() -> void:
	_power_mesh = find_child("PowerButton", true, false) as MeshInstance3D
	if _power_mesh == null:
		return
	_power_rest = _power_mesh.transform
	# Sit the interaction zone on the real switch and let its motion drive the mesh.
	if _power_switch != null:
		_power_switch.global_position = _mesh_center(_power_mesh)
		_power_switch.value_changed.connect(_on_power_slide)
		_set_power_mesh(_power_switch.value)


func _on_power_slide(v: float) -> void:
	_set_power_mesh(v)


func _set_power_mesh(v: float) -> void:
	if _power_mesh == null:
		return
	# Slides along the face's "up" axis (across the short edge on a laid-flat PSP).
	var ax := _shell_up.cross(_press_dir).normalized()
	if ax.length() < 0.5:
		ax = Vector3.RIGHT
	_power_mesh.transform = Transform3D(_power_rest.basis, _power_rest.origin + ax * (v * _POWER_SLIDE))


# --- power LED ---------------------------------------------------------------

## The GLB ships FOUR overlapping "PowerLED"/"PowerLED_001".."_003" meshes,
## all stacked at the same position — looks like separate authored on/off/
## brightness states meant to be toggled by visibility, but nothing ever did,
## so all four render at once and the LED reads as permanently lit regardless
## of power state. Keep just one ("PowerLED") and drive it dynamically instead
## (same fix as the N64's always-lit LED meshes).
var _power_led: MeshInstance3D = null


func _configure_power_led() -> void:
	_power_led = find_child("PowerLED", true, false) as MeshInstance3D
	for nm in ["PowerLED_001", "PowerLED_002", "PowerLED_003"]:
		var extra := find_child(nm, true, false) as MeshInstance3D
		if extra != null:
			extra.visible = false
	_set_power_led(false)


func on_power_on() -> void:
	super.on_power_on()
	_set_power_led(true)


func on_power_off() -> void:
	super.on_power_off()
	_set_power_led(false)


func _set_power_led(on: bool) -> void:
	if _power_led == null:
		return
	var mat := _power_led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or not mat.resource_local_to_scene:
		mat = StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		_power_led.set_surface_override_material(0, mat)
	mat.albedo_color = Color(0.05, 0.3, 0.08) if on else Color(0.05, 0.06, 0.05)
	mat.emission_enabled = on
	mat.emission = Color(0.5, 1.0, 0.3)
	mat.emission_energy_multiplier = 1.0 if on else 0.0


# --- UMD door + eject -------------------------------------------------------

## The UMD lives behind a hinged door on the back — a real mesh ("PSP UMD
## Deckel22"; "Deckel" is German for "lid/cover", same shell as the German-named
## AVKabel/PowerKabel cable meshes) on a real back-edge hinge, a
## VRSpringLatchedHinge rig (same idea as the disc consoles' lids —
## Dreamcast/PS2/Saturn) rather than trusting the GLB's own door
## animation/pivot empty ("PSP UMD Deckel"), which (like those consoles'
## broken Close clips) doesn't drive the mesh correctly. This gives the door a
## real spring: EJECT pops it open, and it can be grabbed and pushed shut by
## hand — it only latches when released near the closed limit.
##
## Baked into psp.tscn as UMDDoorPivot (with the door + UMD Schacht liner
## reparented onto it) / UMDDoorPivot/UMDDoorHinge / .../CollisionShape3D —
## same idiom as playstation_one.tscn's LidMount/LidPivot/LidHinge — rather
## than built at runtime. The pivot hinges at the door's real edge (its
## global-Z-MAXIMUM, the opposite end from the disc consoles' lids) with a
## 180°-about-Y yaw so the door swings DOWN and away from the shell instead
## of up through it; the hinge's grab box only covers the free (swinging)
## half of the door, away from the pivot. See Tools/bake_psp.gd in history
## for how it was built, if it ever needs rebuilding from a fresh GLB.
const _UMD_OPEN_DEG := 40.0
var _umd_door: MeshInstance3D = null
var _umd_hinge: VRSpringLatchedHinge = null
var _umd_door_pivot: Node3D = null


func _configure_umd_door() -> void:
	var pivot := get_node_or_null("UMDDoorPivot") as Node3D
	if pivot == null:
		return
	_umd_door_pivot = pivot
	_umd_door = pivot.get_node_or_null("PSP UMD Deckel22") as MeshInstance3D
	_umd_hinge = pivot.get_node_or_null("UMDDoorHinge") as VRSpringLatchedHinge
	if _umd_hinge != null:
		_umd_hinge.max_deg = _UMD_OPEN_DEG
		_umd_hinge.rotation_changed.connect(_on_umd_door_swung)


## The UMD's real slot is part of the door assembly itself (the "UMD Schacht"
## chute liner is modelled as a child of this same pivot) — unlike a spindle
## console, the seated disc should swing with the door, not stay fixed to
## the shell. See MediaTray.disc_lid_pivot.
func get_disc_lid_pivot() -> Node3D:
	return _umd_door_pivot


func has_spring_latched_lid() -> bool:
	return _umd_hinge != null


## OPEN/CLOSE come through here on a tray-loader system (RetroSystem calls
## play_open/play_close when the eject latch toggles).
func play_open() -> void:
	if _umd_hinge != null:
		_umd_hinge.open()


func play_close() -> void:
	if _umd_hinge != null:
		_umd_hinge.latch_closed()


## The hand pushed the door home (or the wheel/laser did, on desktop) — tell
## the host so it marks the UMD tray closed, same as the disc consoles.
func _on_umd_door_swung(_deg: float) -> void:
	if _umd_hinge != null and _umd_hinge.is_latched_closed():
		var host := get_parent()
		if host != null and host.has_method("request_tray_state"):
			host.request_tray_state(false)


func configure_buttons(_power_btn: VRButton, _reset_btn: VRButton, eject_btn: VRButton) -> void:
	# Mount the eject latch on the GLB's own EjectButton position.
	var em := find_child("EjectButton", true, false) as MeshInstance3D
	if em != null:
		eject_btn.global_position = _mesh_center(em)
	eject_btn.trigger_radius = 0.015
	eject_btn.depress_depth = 0.002
	eject_btn.depress_axis = -_press_dir
	var lbl := eject_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.visible = false
	var vis := eject_btn.get_node_or_null("ButtonMesh") as MeshInstance3D
	if vis != null:
		vis.visible = false


## UMD loads through the back-edge door. The MediaSlot ride travels the zone's
## -Z, so keep the flat placement (no cartridge-style -90° rotation).
func configure_cartridge_slot(slot: Node3D) -> void:
	var socket := _glb.find_child("System Socket", true, false) as Node3D if _glb != null else null
	if socket != null:
		slot.global_position = socket.global_position
	else:
		slot.position = Vector3(0, 0, -body_size.z / 2.0 - 0.01)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
	# An authored "UMDSeat" marker (baked into the scene, riding the Shell) wins
	# over the socket-derived pose above, so the UMD rest can be dialled in
	# visually in the editor — same idiom as the disc systems' "DiscSeat"
	# (see playstation_one_model.gd). Absent → keep the socket-derived pose.
	var seat := find_child("UMDSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


# --- helpers ----------------------------------------------------------------

## True world position of a button/switch mesh. The PSP-1000 GLB's control
## meshes all ship with an IDENTITY node transform — their offset lives
## entirely in the baked vertex data, not the node's transform.origin — so
## mesh.global_position always reads as Shell's own origin, not the mesh's
## actual location. Every mesh-anchored interaction zone (eject latch, power
## slide) needs this instead.
func _mesh_center(mesh: MeshInstance3D) -> Vector3:
	return mesh.global_transform * mesh.get_aabb().get_center()


## Mean outward normal of a mesh, snapped to the nearest primary axis, in
## `ref`'s frame (pass the mesh's own parent so the result lines up with the
## `.transform` these meshes are actually animated in). Averaging cancels the
## button's bevel; snapping guards against a residual tilt sending presses in
## slightly off directions.
func _axis_normal(mi: MeshInstance3D, ref: Node3D) -> Vector3:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return Vector3.UP
	var arr: Array = mi.mesh.surface_get_arrays(0)
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	if norms.is_empty():
		return Vector3.UP
	var rel := ref.global_transform.affine_inverse() * mi.global_transform
	var acc := Vector3.ZERO
	for nrm in norms:
		acc += (rel.basis * nrm).normalized()
	if acc.length() < 0.001:
		return Vector3.UP
	acc = acc.normalized()
	# Snap to whichever axis it lies closest to.
	var ax := Vector3.RIGHT
	if absf(acc.y) >= absf(acc.x) and absf(acc.y) >= absf(acc.z):
		ax = Vector3.UP
	elif absf(acc.z) >= absf(acc.x):
		ax = Vector3.BACK
	return ax * signf(acc.dot(ax))


## A pivot empty's position in the mesh's parent frame, or the mesh AABB centre.
func _pivot_of(mesh: MeshInstance3D, empty_name: String) -> Vector3:
	for n in find_children("*", "Node3D", true, false):
		if n is MeshInstance3D:
			continue
		if String(n.name) == empty_name:
			return mesh.get_parent().to_local((n as Node3D).global_position)
	var a: AABB = mesh.get_aabb()
	return mesh.transform * a.get_center()
