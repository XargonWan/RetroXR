## RetroSystemModelN64 — Nintendo 64 console (cartridge; POWER + RESET, no eject).
##
## Uses the imported N64 GLB. Its front already faces +Z (controller ports, power/reset,
## power LED) so — unlike the PlayStation — it needs no rotation, just a recentre and
## a rest-on-the-ground. The console's real buttons, four controller ports, AV port,
## cartridge slot and power LED are mapped onto the RetroSystem's interaction nodes,
## the same way the PlayStation model wires its GLB.
class_name RetroSystemModelN64
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/N64 imported.glb"

## The GLB's body material uses an embedded GREEN diffuse variant. Swap it for the
## classic grey N64 diffuse (shipped alongside, same UV layout). Point this at
## "..._GoildN64_System_diffuse_Recolors.png" instead for the gold variant.
const _BODY_DIFFUSE := "res://imported-assets/N64 imported_diffuddddddddddddddse.png"

var _led: Array[MeshInstance3D] = []


func _ready() -> void:
	# Store-safe guard: GLB is export-excluded (licence pending). Re-show the host's
	# placeholder box (system.gd hid it) if the model isn't in this build.
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("RetroSystemModelN64: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("RetroSystemModelN64: could not load model at %s" % _MODEL_PATH)
		return
	var inst := scene.instantiate() as Node3D
	add_child(inst)
	# Front already faces +Z; recentre in X/Z and sit the body base on the ground.
	var b := _model_aabb(inst)
	var c := b.position + b.size * 0.5
	inst.position = Vector3(-c.x, -b.position.y, -c.z)

	_recolor_body(inst)

	# Power LED: the model ships bright always-on LED meshes — represent power state
	# with a subtle red emissive instead (driven by on_power_on/off).
	for nm in ["Lichtno", "Lichtno (1)"]:
		var m := inst.find_child(nm, true, false) as MeshInstance3D
		if m:
			_led.append(m)
	_set_led(false)


## Combined AABB of all of `inst`'s meshes, in this model node's local space.
func _model_aabb(inst: Node3D) -> AABB:
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
	return acc


## Re-point every surface using the body's embedded green diffuse at _BODY_DIFFUSE
## (grey). One texture is shared across the body/buttons/plugs; find it on the body
## mesh, then override each surface that uses it, keeping the material's other maps.
func _recolor_body(inst: Node3D) -> void:
	var diffuse := load(_BODY_DIFFUSE) as Texture2D
	if diffuse == null:
		return
	var body := inst.find_child("N64_System 1", true, false) as MeshInstance3D
	if body == null or body.mesh == null:
		return
	var body_mat := body.mesh.surface_get_material(0) as StandardMaterial3D
	if body_mat == null:
		return
	var green_tex := body_mat.albedo_texture
	for n in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var m := mi.mesh.surface_get_material(s) as StandardMaterial3D
			if m and m.albedo_texture == green_tex:
				var dup := m.duplicate() as StandardMaterial3D
				dup.albedo_texture = diffuse
				mi.set_surface_override_material(s, dup)


## Rest on the ground and keep the pickup/pointer boxes below the top-mounted
## POWER/RESET buttons so the desktop pointer can click them (as on the PlayStation).
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.26, 0.05, 0.28)
	var pos := Vector3(0.0, 0.025, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


## POWER + RESET only (cartridge system — no eject/OPEN button).
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_wire_button(power_btn, "switch_power24")
	_wire_button(reset_btn, "button_reset")


func _wire_button(btn: VRButton, mesh_name: String) -> void:
	if btn == null:
		return
	var mesh := find_child(mesh_name, true, false) as MeshInstance3D
	if mesh == null:
		return
	btn.set_button_mesh(mesh)   # hides the placeholder square
	btn.global_position = mesh.global_position
	# Top-mounted buttons press straight down (the GLB has no finger empties).
	btn.depress_depth = 0.0035
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.hide()


func get_controller_port_count() -> int:
	return 4


## Four front ports: the GLB names ports 1 & 2 (left of centre); mirror them across
## the console centre for ports 3 & 4.
func configure_controller_ports(port_zones: Array) -> void:
	# An authored "PortSeat1".."PortSeat4" marker (baked into the model's own
	# scene, when it has one) wins over the GLB-anchor-derived pose below,
	# same "authored wins over computed" idiom as CartSeat/DiscSeat/UMDSeat.
	# "Port1"/"Port2" below are the shell's OWN native marker names (from the
	# GLB itself, like Famicom's "prisemanette1_low") — not this convention —
	# so they stay as the computed fallback, not something to rename.
	var any_seat := false
	for i in range(port_zones.size()):
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			port_zones[i].global_transform = seat.global_transform
			any_seat = true
	if any_seat:
		return
	var p1 := find_child("Port1", true, false) as Node3D
	var p2 := find_child("Port2", true, false) as Node3D
	if p1 == null or p2 == null or port_zones.size() < 4:
		return
	var host := (port_zones[0] as Node3D).get_parent() as Node3D
	var inv := host.global_transform.affine_inverse()
	var l1: Vector3 = inv * p1.global_position
	var l2: Vector3 = inv * p2.global_position
	port_zones[0].position = l1
	port_zones[1].position = l2
	port_zones[2].position = Vector3(-l2.x, l2.y, l2.z)
	port_zones[3].position = Vector3(-l1.x, l1.y, l1.z)


## Video-out (cable/rope) at the AV socket on the console back. Hide the placeholder.
func configure_cable_attach(attach_point: Node3D) -> void:
	var av := find_child("socket_av", true, false) as Node3D
	if av:
		attach_point.global_position = av.global_position
	var visual := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if visual:
		visual.visible = false


## Cartridge drops into the top slot (socket_media).
func configure_cartridge_slot(slot: Node3D) -> void:
	var media := find_child("socket_media", true, false) as Node3D
	if media:
		slot.global_position = media.global_position
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false


## Cartridge saves live on the cart (or controller pak) — no removable memory cards.
func uses_memory_cards() -> bool:
	return false


func on_power_on() -> void:
	_set_led(true)


func on_power_off() -> void:
	_set_led(false)


func _set_led(on: bool) -> void:
	for m in _led:
		if not is_instance_valid(m):
			continue
		var mat := m.get_surface_override_material(0) as StandardMaterial3D
		if mat == null or not mat.resource_local_to_scene:
			mat = StandardMaterial3D.new()
			mat.resource_local_to_scene = true
			m.set_surface_override_material(0, mat)
		mat.albedo_color = Color(0.9, 0.1, 0.1) if on else Color(0.25, 0.06, 0.06)
		mat.emission_enabled = on
		mat.emission = Color(1.0, 0.12, 0.12)
		mat.emission_energy_multiplier = 0.9 if on else 0.0
