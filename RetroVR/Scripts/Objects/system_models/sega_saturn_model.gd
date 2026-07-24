## RetroSystemModelSegaSaturn — Sega Saturn disc console model.
##
## Loads an author's imported Saturn GLB and wires the power/reset/open buttons, the
## CD lid (GLB "..._Open_PAN" animation; "..._Close_PAN" is broken so close =
## reverse + snap, same quirk as the PSone), disc seat, cable and collision.
## Dev-only: GLB is export-excluded; _ready() self-guards to the placeholder box.
class_name RetroSystemModelSegaSaturn
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/sega_saturn.glb"
const _OPEN_ANIM := "Sega Saturn Black_Open_PAN"

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid: Node3D = null
var _lid_closed: Transform3D


func _ready() -> void:
	# The authored sega_saturn.tscn instances the shell as a "Shell" child plus an
	# editor-authorable "DiscSeat" marker (translucent cylinder "SeatPreview") that
	# rides the shell through the recentre below. Reuse the instance when present.
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("SegaSaturnModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var ps := load(_MODEL_PATH) as PackedScene
		if ps == null:
			push_warning("SegaSaturnModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = ps.instantiate() as Node3D
		add_child(_glb)
	# The disc-seat preview is an editor aid only — hide it before the recentre AABB.
	var preview := find_child("SeatPreview", true, false)
	if preview is Node3D:
		(preview as Node3D).visible = false
	# Keep the rest pose (lid CLOSED) on load — disable the GLB's auto-play.
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""
	var rca := _glb.find_child("RCA_Silver", true, false) as Node3D
	if rca != null:
		rca.visible = false
	var xz := _visible_xz_center(_glb)
	_glb.position = Vector3(-xz.x, 0.0, -xz.y)
	_lid = _glb.find_child("CD Tray", true, false) as Node3D
	if _lid != null:
		_lid_closed = _lid.transform


func _visible_xz_center(root: Node3D) -> Vector2:
	var acc := AABB(); var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


func _anchor(marker: String) -> Vector3:
	if _glb == null:
		return global_position
	var n := _glb.find_child(marker, true, false) as Node3D
	return n.global_position if n != null else global_position


# World-space centre of a baked mesh (used for button anchors — Saturn ships no
# button-marker empties).
func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false   # Saturn saves internally / to a backup cart, not a PSX card


# --- disc lid ---
func play_open() -> void:
	if _anim != null and _anim.has_animation(_OPEN_ANIM):
		_anim.play(_OPEN_ANIM)

func play_close() -> void:
	if _anim != null and _anim.has_animation(_OPEN_ANIM):
		_anim.play_backwards(_OPEN_ANIM)
		if not _anim.animation_finished.is_connected(_on_close_finished):
			_anim.animation_finished.connect(_on_close_finished, CONNECT_ONE_SHOT)

func _on_close_finished(_anim_name: StringName) -> void:
	if _lid != null:
		_lid.transform = _lid_closed
	if _anim != null:
		_anim.stop()


# --- buttons (mesh-centre anchored) ---
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "Power Button")
	_wire_button(reset_btn, "Reset Button")
	_wire_button(eject_btn, "Eject")


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


# --- disc seat / cable / collision ---
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.global_position = _anchor("Disc Spindle")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false
	# An authored "DiscSeat" marker (baked into sega_saturn.tscn, riding the Shell)
	# wins over the spindle pose, so the disc rest can be dialled in visually in the
	# editor. Absent → keep the Disc Spindle pose.
	var seat := find_child("DiscSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("Cable Plug (S)")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.27, 0.09, 0.29)
	var pos := Vector3(0.0, 0.045, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
