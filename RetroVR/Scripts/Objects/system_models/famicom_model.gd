## RetroSystemModelFamicom — Nintendo Family Computer (Famicom), the JP regional
## variant of the NES. Cartridge console, top-loading under the red flap.
##
## Loads an author's imported Famicom GLB and wires POWER / RESET / EJECT, the top
## cartridge slot (cart drops in from above), the RF cable and the two DIN
## controller sockets. The GLB ships the Famicom's two hardwired pads + coiled
## leads; RetroVR spawns its own controllers, so those (and the loose plug) are
## hidden — the moulded console-side sockets stay.
##
## Registered as the "nes" model (dev-only). GLB is export-excluded (licence
## pending); _ready() self-guards to the placeholder box if the GLB is absent.
class_name RetroSystemModelFamicom
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/famicom.glb"

var _glb: Node3D = null


func _ready() -> void:
	# The authored famicom.tscn instances the shell as a "Shell" child plus an
	# editor-authorable "CartSeat" marker (translucent "SeatPreview" box), which
	# rides the shell so it stays put through the runtime recentre below. Reuse the
	# instance instead of loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("FamicomModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("FamicomModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		add_child(_glb)
	# The cart-seat preview box is an editor aid only — hide it BEFORE the recentre
	# so it doesn't skew the body AABB.
	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	_hide_clutter(_glb)
	# Recentre on the VISIBLE body (after the sprawling pads/leads are hidden) and
	# rest the base on the ground.
	var b := _model_aabb(_glb)
	var c := b.position + b.size * 0.5
	_glb.position = Vector3(-c.x, -b.position.y, -c.z)


# Hide the two hardwired pads (manette*), their coiled leads (cable*), pad face
# controls (cross/startselect/ab/pPlane) and the loose plug. Keep the console's
# own DIN sockets (prise…manette…) — RetroVR spawns its own controllers.
# (Manual recursion — find_children's type filter skips MeshInstance3D here.)
func _hide_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			var is_pad := nm.contains("manette") and not nm.contains("prise")
			var is_lead := nm.contains("cable") or nm.contains("plug")
			var is_pad_ctrl := nm.contains("cross") or nm.contains("startselect") \
				or nm.begins_with("ab") or nm.begins_with("pplane")
			# The screw meshes are posed at the (now-hidden) pad shells, so they float
			# free as stray specks — hide them (console screws sit underneath anyway).
			var is_screw := nm.contains("screw")
			if is_pad or is_lead or is_pad_ctrl or is_screw:
				mi.visible = false
		for c in n.get_children():
			stack.append(c)


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


func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "power_low")
	_wire_button(reset_btn, "reset_low")
	_wire_button(eject_btn, "eject_low")


func _wire_button(btn: VRButton, mesh_name: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = _mesh_center(mesh_name)
	btn.depress_depth = 0.0022
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- cartridge (top-load: drops straight down under the red flap) ---
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.global_position = _anchor("socket_media")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "CartSeat" marker (baked into famicom.tscn, riding the Shell)
	# wins over the socket pose above, so the seated-cart transform can be dialled
	# in visually in the Godot 3D editor. Absent → keep the socket pose.
	var seat := find_child("CartSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


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


func configure_controller_ports(port_zones: Array) -> void:
	var p1 := _anchor("prisemanette1_low")
	var p2 := _anchor("prisemanette2_low")
	# An authored "PortSeat1"/"PortSeat2" marker (baked into famicom.tscn)
	# wins over the anchor-derived pose, same idiom as CartSeat/DiscSeat/
	# UMDSeat.
	var seat1 := find_child("PortSeat1", true, false) as Node3D
	var seat2 := find_child("PortSeat2", true, false) as Node3D
	if port_zones.size() >= 1:
		port_zones[0].global_transform = seat1.global_transform if seat1 != null \
			else Transform3D(global_transform.basis, p1)
	if port_zones.size() >= 2:
		port_zones[1].global_transform = seat2.global_transform if seat2 != null \
			else Transform3D(global_transform.basis, p2)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("socket_av")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.22, 0.07, 0.16)
	var pos := Vector3(0.0, 0.035, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
