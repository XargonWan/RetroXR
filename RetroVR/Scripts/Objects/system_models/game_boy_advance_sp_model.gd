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


func get_controller_port_count() -> int:
	return 0


func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	if power_btn == null or _glb == null:
		return
	var mesh := _glb.find_child("POWER", true, false) as MeshInstance3D
	if mesh != null:
		power_btn.set_button_mesh(mesh)
	power_btn.global_position = mesh.global_transform * mesh.get_aabb().get_center() if mesh else global_position
	power_btn.depress_depth = 0.002
	power_btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb == null:
		return
	var mk := _glb.find_child("RCA_White", true, false) as MeshInstance3D
	attach_point.global_position = mk.global_transform * mk.get_aabb().get_center() if mk else global_position
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false
