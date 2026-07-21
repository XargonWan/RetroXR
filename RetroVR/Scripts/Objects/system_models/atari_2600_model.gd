## RetroSystemModelAtari2600 — Atari 2600 VCS (woodgrain, cartridge, top-loading).
##
## Loads an author's imported Atari 2600 GLB and wires the POWER + RESET switches and
## the top cartridge slot (cart drops in). The 2600 has no eject button (carts pull
## straight out) and no removable memory cards. Two joystick ports on the back.
##
## Registered as the "atari_2600" model (dev-only). GLB is export-excluded (licence
## pending); _ready() self-guards to the placeholder box if the GLB is absent.
## NOTE: the console body mesh is ~290k tris (undecimated) — heavy for one instance.
class_name RetroSystemModelAtari2600
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/atari_2600.glb"

var _glb: Node3D = null


func _ready() -> void:
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("Atari2600Model: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("Atari2600Model: failed to load %s" % _MODEL_PATH)
		return
	_glb = scene.instantiate() as Node3D
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	add_child(_glb)
	# Recentre on the console body and rest the base on the ground.
	var b := _model_aabb(_glb)
	var c := b.position + b.size * 0.5
	_glb.position = Vector3(-c.x, -b.position.y, -c.z)


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


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


# POWER + RESET switches only (no eject — carts pull straight out).
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "Power Switch")
	_wire_button(reset_btn, "Reset")
	if eject_btn != null:
		eject_btn.visible = false


func _wire_button(btn: VRButton, mesh_name: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = _mesh_center(mesh_name)
	btn.depress_depth = 0.002
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- cartridge (top-load: drops straight down) ---
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.global_position = _anchor("socket_media")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func get_cartridge_insert_direction() -> Vector3:
	return Vector3.DOWN


func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	var final_pos := cartridge.global_position
	cartridge.freeze = false
	cartridge.global_position = final_pos + Vector3.UP * 0.06
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_position", final_pos, 0.22) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: cartridge.freeze = true)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("socket_av")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.35, 0.10, 0.24)
	var pos := Vector3(0.0, 0.05, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
