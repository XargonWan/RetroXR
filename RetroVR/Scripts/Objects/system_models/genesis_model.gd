## RetroSystemModelGenesis — Sega Genesis / Mega Drive (Model 1) cartridge console.
##
## Loads an author's imported Genesis GLB; wires power/reset buttons, the top cartridge
## slot (cart drops straight down), AV cable, power LED and collision. Dev-only:
## GLB export-excluded; _ready() self-guards to the placeholder box.
class_name RetroSystemModelGenesis
extends RetroSystemModel

var _glb: Node3D = null
var _led: MeshInstance3D = null


## Overridable so regional badges (Mega Drive) can reuse all this wiring — the
## Genesis and Mega Drive Model 1 GLBs share node names, only the shell differs.
func _model_path() -> String:
	return "res://imported-assets/sega_genesis.glb"


func _ready() -> void:
	# An authored scene (genesis.tscn / megadrive.tscn) instances the shell as a
	# "Shell" child plus an editor-authorable "CartSeat" marker riding it. Reuse the
	# instance instead of loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		var path := _model_path()
		if not ResourceLoader.exists(path):
			push_warning("GenesisModel: %s missing — using placeholder box" % path)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(path) as PackedScene
		if scene == null:
			push_warning("GenesisModel: failed to load %s" % path)
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
	# Hide imported's invisible "Finger Button" trigger proxies (they import as
	# untextured white meshes). RetroVR drives the buttons itself.
	var stack: Array[Node] = [_glb]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and String(mi.name).to_lower().contains("finger"):
			mi.visible = false
		for ch in n.get_children():
			stack.append(ch)
	# The bundled A/V plug prop STAYS VISIBLE — it is the connector the spawned
	# video rope hangs off (hidden, the cable sprouted from empty air behind the
	# shell). It does stick ~5 cm out the back though, so keep it out of the
	# recentre AABB: hide it across the measurement, then bring it back.
	var plug := _av_plug()
	if plug != null:
		plug.visible = false
	var b := _model_aabb(_glb)
	var c := b.position + b.size * 0.5
	_glb.position = Vector3(-c.x, -b.position.y, -c.z)   # recentre + rest base on ground
	if plug != null:
		plug.visible = true
	_led = _glb.find_child("PowerLight", true, false) as MeshInstance3D
	_set_led(false)


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


## First matching marker's world position (markers differ across regional GLBs).
func _anchor_any(markers: Array) -> Vector3:
	if _glb != null:
		for m in markers:
			var n := _glb.find_child(m, true, false) as Node3D
			if n != null:
				return n.global_position
	return global_position


func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	# POWER is a rocker, not a button. The shell prints "ON | | OFF" under it and
	# the cap travels between those two ticks — about 9 mm, ON toward -X.
	var cap := _glb.find_child("power", true, false) as MeshInstance3D if _glb != null else null
	build_power_slider(power_btn, cap, Vector3.LEFT, 0.009)
	_wire_button(reset_btn, "reset")


func _wire_button(btn: VRButton, mesh_name: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	var anchor := _mesh_center(mesh_name)
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = anchor
	btn.depress_depth = 0.0022
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- cartridge (top-load: drops straight down) ---
## The two 9-pin ports on the front panel. The GLB marks the cart socket and the
## A/V out but not these, and nothing had ever placed them — both zones sat at the
## framework default, on the floor in front of the console.
##
## First measured off a straight-on render against the shell's own moulded
## CONTROL 1 / CONTROL 2 recesses, then replaced with the author's own numbers:
## an author's SMS/32X bundle carries the SAME `megadrive_console` mesh plus two
## `Port1`/`Port2` markers with plugs posed in them. The render-measured values
## landed within 0.6 mm and 0.1 mm of those, which is the cross-check; these are
## the exact ones. Shared with the Mega Drive — same hardware, same node layout.
const _PORT_X := [0.0539, 0.0849]
const _PORT_Y := 0.0156
const _PORT_Z := 0.1077


func configure_controller_ports(port_zones: Array) -> void:
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		# An authored "PortSeat1"/"PortSeat2" marker (baked into genesis.tscn /
		# megadrive.tscn) wins over the computed pose below, same idiom as
		# CartSeat/DiscSeat/UMDSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		elif i < _PORT_X.size():
			zone.position = Vector3(_PORT_X[i], _PORT_Y, _PORT_Z)
			# Front-facing socket: roll 180 about Z so the plug seats connector-in
			# and upright, rather than the yaw that lands it upside down.
			zone.rotation_degrees = Vector3(0, 0, 180)
		var recess := zone.get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := zone.get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()


func configure_cartridge_slot(slot: Node3D) -> void:
	# socket_media is where the cart's CONNECTOR mates; a snap zone seats on the
	# object's CENTRE, so lift by half the cart or it sinks into the deck. The
	# authored basis is already right: the Genesis loads from the top with the
	# cart upright and its label facing the player, which is the cartridge scene's
	# own rest orientation (connector -Y, label +Z).
	slot.global_position = _anchor("socket_media") 		+ Vector3.UP * (MediaDimensions.cart_size("mega_drive").y * 0.5)
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "CartSeat" marker (baked into genesis.tscn / megadrive.tscn,
	# riding the Shell) wins over the computed pose, so the seated-cart transform
	# can be dialled in visually in the editor. Absent → keep the computed pose.
	var seat := find_child("CartSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


func get_cartridge_insert_direction() -> Vector3:
	return Vector3.DOWN


func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	# XRTools froze the cart at the seated position; slide it in from above.
	var final_pos := cartridge.global_position
	cartridge.freeze = false
	cartridge.global_position = final_pos + Vector3.UP * 0.06
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_position", final_pos, 0.22) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: cartridge.freeze = true)


## The shell's bundled A/V (composite/RCA) plug prop — shown, not hidden.
func _av_plug() -> MeshInstance3D:
	if _glb == null:
		return null
	return _glb.find_child("RCA_Silver", true, false) as MeshInstance3D


func configure_cable_attach(attach_point: Node3D) -> void:
	# Off the visible A/V plug's tip. The markers are the fallback: the Genesis GLB's
	# "socket_av" sits at the back PANEL, so anchoring there would run the rope
	# through the plug prop; the Mega Drive's "Cable Plug (S)" is the plug tip.
	attach_point.global_position = av_plug_cable_end(
		_av_plug(), _anchor_any(["socket_av", "Cable Plug (S)"]))
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.29, 0.07, 0.27)
	var pos := Vector3(0.0, 0.035, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


func on_power_on() -> void:
	super.on_power_on()
	_set_led(true)

func on_power_off() -> void:
	super.on_power_off()
	_set_led(false)


func _set_led(on: bool) -> void:
	if _led == null:
		return
	var mat := _led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or not mat.resource_local_to_scene:
		mat = StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		_led.set_surface_override_material(0, mat)
	mat.albedo_color = Color(0.9, 0.1, 0.1) if on else Color(0.25, 0.06, 0.06)
	mat.emission_enabled = on
	mat.emission = Color(1.0, 0.12, 0.12)
	mat.emission_energy_multiplier = 0.9 if on else 0.0
