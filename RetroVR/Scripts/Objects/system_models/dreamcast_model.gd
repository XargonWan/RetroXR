## RetroSystemModelDreamcast — Sega Dreamcast disc console model.
##
## Loads an author's imported Dreamcast GLB and wires power/open buttons, the GD-ROM
## lid (GLB Open_PAN forward; Close_PAN is broken so close = reverse + snap, same
## quirk as PSone/Saturn), disc seat, cable and collision. 4 controller ports,
## no console memory-card slot (Dreamcast saves to the VMU in the controller).
## Dev-only: GLB export-excluded; _ready() self-guards to the placeholder box.
class_name RetroSystemModelDreamcast
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/dreamcast_console.glb"
const _OPEN_ANIM := "Dreamcast 2_Open_PAN"

var _glb: Node3D = null
var _anim: AnimationPlayer = null
var _lid: Node3D = null
var _lid_closed: Transform3D


func _ready() -> void:
	if not ResourceLoader.exists(_MODEL_PATH):
		push_warning("DreamcastModel: %s missing — using placeholder box" % _MODEL_PATH)
		var host := get_parent()
		if host:
			var body := host.get_node_or_null("SystemBody") as MeshInstance3D
			if body:
				body.show()
		return
	var ps := load(_MODEL_PATH) as PackedScene
	if ps == null:
		push_warning("DreamcastModel: failed to load %s" % _MODEL_PATH)
		return
	_glb = ps.instantiate() as Node3D
	_anim = _glb.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if _anim != null:
		_anim.autoplay = ""   # keep the rest pose (lid closed) on load
	add_child(_glb)
	var xz := _visible_xz_center(_glb)
	_glb.position = Vector3(-xz.x, 0.0, -xz.y)
	_lid = _glb.find_child("Lid", true, false) as Node3D
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


func _mesh_center(mesh_name: String) -> Vector3:
	if _glb == null:
		return global_position
	var m := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


func get_controller_port_count() -> int:
	return 4


func uses_memory_cards() -> bool:
	return false


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


# --- buttons (power + open; Dreamcast has no reset button) ---
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_button(power_btn, "Power Button")
	_wire_button(eject_btn, "Eject Button")


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
	slot.global_position = _anchor("spindle")
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.global_position = _anchor("socket_av")
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.24, 0.09, 0.24)
	var pos := Vector3(0.0, 0.045, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
