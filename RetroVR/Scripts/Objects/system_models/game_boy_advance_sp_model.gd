## RetroSystemModelGameBoyAdvanceSP — GBA SP (clamshell, landscape, 240×160 LCD).
##
## Unlike the plain GBA, the screen half folds shut over the button half on a
## real hinge (VRHinge — a manual grip-latched fold, NOT a spring-loaded tray;
## same idiom as the NDS/3DS lid, not the PS1/GameCube disc lid). The lid
## ("TopScreen") and the live LCD quad both ride a LidPivot so the picture
## folds with the shell.
##
## The whole fold rig is AUTHORED in game_boy_advance_sp.tscn — pivot on the
## hinge axis, lid + picture quad parented onto it, and the VRHinge's own limits,
## grab box and hint icon. Nothing here computes geometry; the scene is the
## source of truth, as it is for every other handheld.
class_name RetroSystemModelGameBoyAdvanceSP
extends RetroSystemModelHandheld

func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart


func _glb_path() -> String:
	return "res://imported-assets/game_boy_advance_sp.glb"


## This GLB is authored LYING FLAT (base on the XZ plane, Y up, lid already swung
## open behind it) — a clamshell has a natural resting pose, so its author
## modelled it in that pose rather than upright. The base class's -90 layback is
## for the slab handhelds, which ARE modelled standing up; applying it here
## stands the SP on its back edge with the lid hanging down through the table.
func _glb_rotation_degrees() -> Vector3:
	return Vector3.ZERO


## The base's _cache_shell_nodes() only does a direct-child lookup for
## "HandheldScreen" — fine for a fixed shell, but this one's baked scene has
## it nested under LidPivot (it has to fold with the lid), so fall back to a
## recursive find when the direct lookup misses.
func _cache_shell_nodes() -> void:
	super._cache_shell_nodes()
	if _screen == null:
		_screen = find_child("HandheldScreen", true, false) as MeshInstance3D


## Lid angle is LidPivot.rotation.x: 0 = folded flat backwards (180° interior),
## 180 = shut — the same convention as the NDS/3DS (see
## RetroSystemModelDualScreen.get_lid_angle_deg). The scene authors the rest at
## 45 (135° interior) and clamps the hinge to 30…180: a real SP stops a little
## past straight rather than laying flat, and 30 is also the angle the GLB itself
## ships the lid at, so the open stop IS the modelled pose.
func _on_glb_ready() -> void:
	# The live LCD quad is normally rebuilt by _upgrade_to_glb; on this baked
	# scene it is authored under LidPivot already. Reparent defensively so the
	# picture folds with the lid either way.
	var lid_pivot := get_node_or_null("LidPivot") as Node3D
	if lid_pivot != null and _screen != null and _screen.get_parent() != lid_pivot:
		_screen.reparent(lid_pivot, true)
	# Hand each slide switch the shell's real cap, so the switch you can see IS
	# the knob — it takes the pointer highlight and travels with the value.
	# Direction and throw are authored on the sliders in game_boy_advance_sp.tscn.
	_adopt_switch(_volume_slider, "VOLUME")
	_adopt_switch(_power_switch, "POWER")


## Unlike the PSP — whose switch sits on a tapering edge and needs an off-axis
## travel direction — both of these run in straight slots moulded into flat
## sides, so they slide along Z. Confirmed twice: each cap's own principal axis
## comes out as pure -Z, and the shell's outward profile beside each is constant
## (~0.0405) across the travel span. An earlier tangent fit here read a taper
## that turned out to be the rounded front corner leaking into the sample
## window, and moving along it pushed the caps INTO the shell rather than along
## it (worst clearance -1.3 mm vs -0.2 mm for straight Z).
func _adopt_switch(slider: VRSlider, mesh_name: String) -> void:
	if slider == null or _glb == null:
		return
	var cap := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if cap != null:
		slider.set_knob_mesh(cap)


func get_controller_port_count() -> int:
	return 0


# --- on-device control animation --------------------------------------------
#
# Driven by HandheldInput._send_joypad from the same state it feeds the core, so
# the shell's own buttons move as you play it. The base half lies flat with its
# face on +Y (see _glb_rotation_degrees), so everything presses straight down.
#
# NOTE the shoulder names. This GLB's "L" mesh sits at +X and its "R" at -X,
# while the D-pad — which is unambiguously the left-hand control — sits at -X.
# The two shoulder meshes are simply named the wrong way round in the bundle, so
# RetroPad L drives the mesh called "R" and vice versa. Verified by rendering
# both tinted next to the D-pad rather than by trusting the names.
const _PRESS_DIR := Vector3.DOWN
const _FACE_PRESS := 0.0010
const _SMALL_PRESS := 0.0006
const _SHOULDER_PRESS := 0.0016
const _DPAD_TILT_DEG := 7.0
const _ANIM_W := 0.35

const _FACE_MESH: Dictionary = {
	ControllerBindings.JOYPAD_A: "A",
	ControllerBindings.JOYPAD_B: "B",
}
const _SMALL_MESH: Dictionary = {
	ControllerBindings.JOYPAD_START:  "START",
	ControllerBindings.JOYPAD_SELECT: "SELECT",
}
const _SHOULDER_MESH: Dictionary = {
	ControllerBindings.JOYPAD_L: "R",   # yes, crossed — see the note above
	ControllerBindings.JOYPAD_R: "L",
}

var _anim_cached := false
var _anim_btns: Array[Dictionary] = []
var _anim_dpad: Dictionary = {}


func _cache_anim_meshes() -> void:
	_anim_cached = true
	if _glb == null:
		return
	for spec: Array in [[_FACE_MESH, _FACE_PRESS], [_SMALL_MESH, _SMALL_PRESS],
			[_SHOULDER_MESH, _SHOULDER_PRESS]]:
		var map: Dictionary = spec[0]
		for bit: int in map:
			var m := _glb.find_child(map[bit], true, false) as MeshInstance3D
			if m != null:
				_anim_btns.append({"node": m, "rest": m.transform, "bit": bit, "depth": float(spec[1])})
	# The D-pad rocks about its own centre — this bundle ships no pivot empty for
	# it, unlike the imported pads whose "Dpad" marker the controllers use.
	var dpad := _glb.find_child("D_PAD", true, false) as MeshInstance3D
	if dpad != null:
		_anim_dpad = {"node": dpad, "rest": dpad.transform,
			"pivot": dpad.transform * dpad.get_aabb().get_center()}


## btn = RETRO_JOYPAD bitmask; the sticks are unused (the SP has no analog).
func animate_controls(btn: int, _lstick: Vector2, _rstick: Vector2) -> void:
	if not _anim_cached:
		_cache_anim_meshes()

	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var down := 1.0 if (btn & (1 << int(e["bit"]))) != 0 else 0.0
		var tgt := Transform3D(rest.basis, rest.origin + _PRESS_DIR * (float(e["depth"]) * down))
		node.transform = node.transform.interpolate_with(tgt, _ANIM_W)

	if _anim_dpad.is_empty():
		return
	var pitch := float((btn >> ControllerBindings.JOYPAD_UP) & 1) - float((btn >> ControllerBindings.JOYPAD_DOWN) & 1)
	var roll := float((btn >> ControllerBindings.JOYPAD_LEFT) & 1) - float((btn >> ControllerBindings.JOYPAD_RIGHT) & 1)
	# Screen-up and flat: UP rocks about X so the FAR (-Z) edge dips, LEFT about
	# Z so the -X edge dips. Both signs are negated from the naive reading —
	# rotating +X by a positive angle lifts the far edge rather than sinking it.
	var r := Basis.from_euler(Vector3(deg_to_rad(-pitch * _DPAD_TILT_DEG), 0.0,
		deg_to_rad(roll * _DPAD_TILT_DEG)))
	var node: MeshInstance3D = _anim_dpad["node"]
	var rest: Transform3D = _anim_dpad["rest"]
	var pivot: Vector3 = _anim_dpad["pivot"]
	var about := Transform3D(r, pivot - r * pivot)
	node.transform = node.transform.interpolate_with(about * rest, _ANIM_W)


# NB: no configure_buttons() override. A plain handheld hides the cabinet
# START/STOP knob (has_start_stop_button() is false when is_handheld()) because
# it carries its own power switch — and this one now does: PowerSwitch and
# VolumeSlider are authored in game_boy_advance_sp.tscn, over the shell's real
# POWER and VOLUME caps on the side edges. The old override aimed the hidden
# cabinet button at the POWER cap, which both did nothing and double-claimed it.


func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb == null:
		return
	var mk := _glb.find_child("RCA_White", true, false) as MeshInstance3D
	attach_point.global_position = mk.global_transform * mk.get_aabb().get_center() if mk else global_position
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false
