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
	# The authored atari_2600.tscn bakes the recentred shell as a "Shell" instance
	# plus an editor-authorable "CartSeat" marker (translucent "SeatPreview" box).
	# Reuse that instance instead of loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
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
		add_child(_glb)
		# Recentre on the console body and rest the base on the ground (the baked
		# scene bakes this into Shell.position, so it's only for the runtime path).
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)
	var ap := _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap != null:
		ap.autoplay = ""
	# The cart-seat preview box is an editor aid only — hide it at runtime.
	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false


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
#
# These are SWITCHES, not buttons: thin levers (5 x 17 x 13 mm) that slide along
# the console's depth rather than sinking into the shell. Driving them with the
# usual downward depress made the lever sink into the panel instead of flicking.
# They still ride the VRButton plumbing — power/reset are momentary as far as
# RetroSystem is concerned — only the motion differs.
const _SWITCH_THROW := 0.005


func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_switch(power_btn, "Power Switch")
	_wire_switch(reset_btn, "Reset")
	if eject_btn != null:
		eject_btn.visible = false


func _wire_switch(btn: VRButton, mesh_name: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	btn.global_position = _mesh_center(mesh_name)
	btn.depress_depth = _SWITCH_THROW
	# FORWARD is -Z, away from the player: the 2600's levers push "up" the panel
	# to switch on, and the console's front is +Z.
	btn.set_depress_axis_world(Vector3.FORWARD)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


## Joystick ports are on the BACK panel, flanking the power jack — the shell
## prints "RIGHT CONTROLLER | POWER ADAPTOR | LEFT CONTROLLER" across it, read
## from behind. Measured off an orthographic render of that face: the two
## sockets sit ~32 mm either side of centre at y≈0.032.
##
## Port 1 is the LEFT controller (player 1 on real hardware), which is at -X when
## the console is viewed from the FRONT.
const _PORT_SPAN := 0.032
const _PORT_Y := 0.0316
const _PORT_INSET := 0.0025


func configure_controller_ports(port_zones: Array) -> void:
	if _glb == null:
		return
	var body := _glb.find_child("atari_2600_console", true, false) as MeshInstance3D
	if body == null:
		return
	# LOCAL space, to match cols/_PORT_Y below — measuring this in world space and
	# then passing it through to_global() would offset the whole back panel.
	var local_ab: AABB = (global_transform.affine_inverse() * body.global_transform) * body.get_aabb()
	var back_z: float = local_ab.position.z
	var cols := [-_PORT_SPAN, _PORT_SPAN]
	for i in range(port_zones.size()):
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		# An authored "PortSeat1"/"PortSeat2" marker (baked into atari_2600.tscn)
		# wins over the computed pose below, same idiom as CartSeat/DiscSeat/
		# UMDSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			port_zones[i].global_transform = seat.global_transform
			continue
		if i < cols.size():
			# A BACK-facing port needs a 180° roll about X, where a front-facing
			# one needs it about Z: the plug's connector points down its local +Z
			# and its SnapGrabPoint adds a 180° X flip, which this cancels
			# outright so the connector goes in along +Z and the lead trails out
			# behind the console.
			port_zones[i].global_transform = Transform3D(
				global_transform.basis * Basis(Vector3.RIGHT, PI),
				to_global(Vector3(cols[i], _PORT_Y, back_z + _PORT_INSET)))


# --- cartridge (top-load: drops straight down) ---
#
# `socket_media` marks where the cart's CONNECTOR lands, 24 mm below the shell's
# top face — but a snap zone seats an object on its CENTRE, so parking the zone
# on the marker buried 62 mm of a 77 mm cartridge inside the console. Raise it by
# half the seated cart's height so the connector sits on the marker and the rest
# stands proud, the way a 2600 cart actually sits.
#
# 77 mm is the cart GLB (74.7 mm tall) after cartridge.gd scales it uniformly to
# the 79 mm width in MediaDimensions.CART_SIZES["atari_2600"].
const _CART_SEATED_HEIGHT := 0.0772


func configure_cartridge_slot(slot: Node3D) -> void:
	if _glb == null:
		return
	var mk := _glb.find_child("socket_media", true, false) as Node3D
	if mk == null:
		slot.global_position = _anchor("socket_media") + Vector3.UP * (_CART_SEATED_HEIGHT * 0.5)
		return
	# Take the marker's BASIS, not just its position: the 2600's slot is raked
	# 30° about X (measured: socket_media's Y is (0, 0.866, 0.500)), so a cart
	# seated on an identity basis stood bolt upright out of an angled slot.
	#
	# The extra 180° yaw turns the label to face the console's BACK. A cart's
	# own frame runs +Y from its connector with the label on +Z, so without this
	# the label ends up on the wrong face. Yawing about the slot's own up axis
	# leaves the rake untouched.
	var b: Basis = mk.global_transform.basis.orthonormalized() * Basis(Vector3.UP, PI)
	# Raise along the SLOT's up, not world up, or an angled cart slides off-axis.
	slot.global_transform = Transform3D(b,
		mk.global_position + b.y * (_CART_SEATED_HEIGHT * 0.5))
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "CartSeat" marker (baked into atari_2600.tscn) wins over the
	# computed pose above, so the seated-cart transform can be dialled in visually
	# in the Godot 3D editor. Absent (script-only fallback) → keep the socket pose.
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
