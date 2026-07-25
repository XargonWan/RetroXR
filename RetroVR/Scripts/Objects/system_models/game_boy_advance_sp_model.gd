## RetroSystemModelGameBoyAdvanceSP — GBA SP (clamshell, landscape, 240×160 LCD).
##
## Unlike the plain GBA, the screen half folds shut over the button half on a
## real hinge (VRHinge — a manual grip-latched fold, NOT a spring-loaded tray;
## same idiom as the NDS/3DS lid, not the PS1/GameCube disc lid). The lid
## ("TopScreen") and the live LCD quad both ride a LidPivot so the picture
## folds with the shell.
class_name RetroSystemModelGameBoyAdvanceSP
extends RetroSystemModelHandheld

func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart


func _glb_path() -> String:
	return "res://imported-assets/game_boy_advance_sp.glb"


var _lid_pivot: Node3D = null
var _hinge: VRHinge = null


## The base's _cache_shell_nodes() only does a direct-child lookup for
## "HandheldScreen" — fine for a fixed shell, but this one's baked scene has
## it nested under LidPivot (it has to fold with the lid), so fall back to a
## recursive find when the direct lookup misses.
func _cache_shell_nodes() -> void:
	super._cache_shell_nodes()
	if _screen == null:
		_screen = find_child("HandheldScreen", true, false) as MeshInstance3D

const LID_REST_DEG := 45.0   # natural half-open display pose, same as the NDS/3DS


func _on_glb_ready() -> void:
	# Baked into game_boy_advance_sp.tscn as LidPivot/LidHinge/CollisionShape3D
	# (with TopScreen reparented onto it) — same idiom as the NDS/3DS. Reuse it
	# when present instead of rebuilding the fold rig every load.
	_lid_pivot = get_node_or_null("LidPivot") as Node3D
	if _lid_pivot != null:
		_hinge = _lid_pivot.get_node_or_null("LidHinge") as VRHinge
		# The live LCD quad (_screen) isn't part of the baked rig — it's built
		# fresh by _upgrade_to_glb every load — so it still needs reparenting
		# onto LidPivot each time, keeping its already-correct world pose.
		if _screen != null and _screen.get_parent() != _lid_pivot:
			_screen.reparent(_lid_pivot, true)
		return
	_mount_lid()


## Builds the fold rig from the shell's own TopScreen mesh: a LidPivot at the
## hinge edge (where TopScreen meets the button half), TopScreen + the live
## screen quad reparented onto it, and a plain VRHinge (grip-latched, not
## spring-loaded — the player folds it by hand, same as the NDS/3DS).
func _mount_lid() -> void:
	var top := _glb.find_child("TopScreen", true, false) as MeshInstance3D
	if top == null:
		return
	var ab: AABB = top.global_transform * top.get_aabb()
	_lid_pivot = Node3D.new()
	_lid_pivot.name = "LidPivot"
	add_child(_lid_pivot)
	# Hinge line: centred in X, at TopScreen's OWN near edge (its max-Y/max-Z
	# corner) — the edge closest to the button half when open. Deriving this
	# from the button half's AABB instead (as a first attempt did) silently
	# assumed a pre-layback axis mapping that doesn't hold after the shell's
	# own -90° layback rotation, putting the pivot ~8cm off and sending the
	# lid flying through a huge arc instead of folding shut.
	_lid_pivot.global_transform = Transform3D(
		global_transform.basis,
		Vector3(ab.get_center().x, ab.position.y + ab.size.y, ab.position.z + ab.size.z))

	var top_world := top.global_transform
	top.reparent(_lid_pivot, false)
	top.global_transform = top_world
	if _screen != null:
		var screen_world := _screen.global_transform
		_screen.reparent(_lid_pivot, false)
		_screen.global_transform = screen_world

	_hinge = VRHinge.new()
	_hinge.name = "LidHinge"
	_hinge.target = _lid_pivot
	_hinge.engage_radius = clampf(maxf(ab.size.x, ab.size.z) * 0.35, 0.025, 0.05)
	_lid_pivot.add_child(_hinge)
	_hinge.position = _lid_pivot.to_local(ab.get_center())
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(ab.size.x, 0.02), maxf(ab.size.z, 0.02), maxf(ab.size.y, 0.01) + 0.02)
	col.shape = box
	_hinge.add_child(col)
	_hinge.icon_offset = Vector3(0.0, 0.0, maxf(ab.size.y, 0.01) * 0.5 + 0.03)
	_lid_pivot.rotation_degrees.x = LID_REST_DEG


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
