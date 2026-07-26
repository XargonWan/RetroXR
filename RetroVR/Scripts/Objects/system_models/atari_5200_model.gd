## RetroSystemModelAtari5200 — Atari 5200 (2-port revision, top-loading cartridge).
##
## Loads an author's imported Atari 5200 GLB and wires the POWER + RESET
## switches and the top cartridge slot (cart drops in). No eject button (carts
## pull straight out, like the 2600) and no removable memory cards.
##
## Registered as the "atari_5200" model (dev-only). GLB is export-excluded;
## _ready() self-guards to the placeholder box if the GLB is absent.
class_name RetroSystemModelAtari5200
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/atari_5200.glb"

var _glb: Node3D = null


func _ready() -> void:
	# The authored atari_5200.tscn bakes the recentred shell as a "Shell" instance
	# plus an editor-authorable "CartSeat" marker (translucent "SeatPreview" box).
	# Reuse that instance instead of loading a second copy of the GLB.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("Atari5200Model: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("Atari5200Model: failed to load %s" % _MODEL_PATH)
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


## An EMPTY marker's own position/rotation is already at its true world
## location (bundle_convert places socket/plug/anchor empties there directly) —
## unlike a MeshInstance3D, whose control meshes ship with an IDENTITY node
## transform (the offset lives in the baked vertex data, not transform.origin;
## see the PSP-1000 shell for the same gotcha). So an anchor needs .global_position
## directly, but a mesh needs its AABB centre in global space instead.
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


## The console shell has no per-port marker meshes, and the model isn't rigged
## richly enough to read a port count off it — assumed 2, matching the smaller
## "2-port" 5200 revision this shell's proportions resemble (the original
## 4-port unit is roughly half again as large). Revisit if that's wrong.
func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


# POWER + RESET switches only (no eject — carts pull straight out).
#
# Same idiom as the 2600: thin levers that slide along the console's depth
# rather than sinking into the shell.
const _SWITCH_THROW := 0.005


func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_switch(power_btn, "Power Button", true)
	# "Finger Button (Slider)" is an anchor empty only — no mesh of its own — so
	# there's no cap to show/move; the shell's own molded switch reads as static.
	_wire_switch(reset_btn, "Finger Button (Slider)", false)
	if eject_btn != null:
		eject_btn.visible = false


func _wire_switch(btn: VRButton, anchor_name: String, has_mesh: bool) -> void:
	if btn == null or _glb == null:
		return
	if has_mesh:
		var mesh := _glb.find_child(anchor_name, true, false) as MeshInstance3D
		if mesh != null:
			btn.set_button_mesh(mesh)
		btn.global_position = _mesh_center(anchor_name)
	else:
		btn.global_position = _anchor(anchor_name)
		# No cap mesh to adopt — hide the generic placeholder square instead of
		# leaving a grey box sitting on the shell's own moulded switch.
		var ph := btn.get_node_or_null("ButtonMesh") as MeshInstance3D
		if ph != null:
			ph.visible = false
	btn.depress_depth = _SWITCH_THROW
	# These sit on the console's TOP deck, so they sink straight DOWN. They used
	# to travel along -Z, which slid them forward across the deck instead of
	# into it.
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


## No per-port marker meshes exist on this shell — approximated across the
## front face (+Z, see _wire_switch), symmetric either side of centre, at the
## same height as the AV jack. Revisit if a richer shell shows up.
const _PORT_SPAN := 0.05
const _PORT_Y := 0.03
const _PORT_INSET := 0.0025


func configure_controller_ports(port_zones: Array) -> void:
	if _glb == null:
		return
	var b := _model_aabb(_glb)
	var front_z: float = b.position.z + b.size.z
	var cols := [-_PORT_SPAN, _PORT_SPAN]
	for i in range(port_zones.size()):
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		# An authored "PortSeat1"/"PortSeat2" marker (baked into atari_5200.tscn)
		# wins over the computed pose below, same idiom as CartSeat/DiscSeat/
		# UMDSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			port_zones[i].global_transform = seat.global_transform
			continue
		if i < cols.size():
			port_zones[i].global_transform = Transform3D(
				global_transform.basis,
				to_global(Vector3(cols[i], _PORT_Y, front_z - _PORT_INSET)))


# --- cartridge (top-load: drops straight down) ---
#
# "System Socket" marks where the cart's CONNECTOR lands — but a snap zone
# seats an object on its CENTRE, so parking the zone there buries most of the
# cartridge inside the console. Raise it by half the seated cart's height so
# the connector sits on the marker and the rest stands proud.
#
# 0.104 m is MediaDimensions.CART_SIZES["atari_5200"].y — the target height
# cartridge.gd's uniform scale-to-width step lands on for this cart model
# (height is the tighter-constrained axis here, unlike the 2600's cart).
const _CART_SEATED_HEIGHT := 0.104


func configure_cartridge_slot(slot: Node3D) -> void:
	if _glb == null:
		return
	var mk := _glb.find_child("System Socket", true, false) as Node3D
	if mk == null:
		slot.global_position = _anchor("System Socket") + Vector3.UP * (_CART_SEATED_HEIGHT * 0.5)
		return
	# Take the marker's BASIS, not just its position: the slot is raked
	# slightly about X, so a cart seated on an identity basis would stand
	# proud at the wrong angle.
	#
	# The extra 180° yaw turns the label to face the console's BACK. A cart's
	# own frame runs +Y from its connector with the label on +Z, so without
	# this the label ends up on the wrong face. Yawing about the slot's own up
	# axis leaves the rake untouched.
	var b: Basis = mk.global_transform.basis.orthonormalized() * Basis(Vector3.UP, PI)
	slot.global_transform = Transform3D(b,
		mk.global_position + b.y * (_CART_SEATED_HEIGHT * 0.5))
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "CartSeat" marker (baked into atari_5200.tscn) wins over the
	# computed pose above, so the seated-cart transform can be dialled in
	# visually in the Godot 3D editor. Absent (script-only fallback) → keep the
	# socket pose.
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
	attach_point.global_position = _anchor("Cable Plug (Y)")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.28, 0.09, 0.29)
	var pos := Vector3(0.0, 0.045, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
