## RetroSystemModelPlaystation — PlayStation 1 console model.
class_name RetroSystemModelPlaystation
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/King PSX.glb"

## Disc-lid open angle (degrees) about the console's left-right axis. Negative
## lifts the front edge up; the hinge is the lid node's own origin (rear-top edge).
const LID_OPEN_DEG := -78.0

var _lid: Node3D = null
var _lid_closed: Transform3D
var _lid_open: Transform3D
var _lid_tween: Tween
var _lid_poses_ready := false


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene == null:
		push_warning("RetroSystemModelPlaystation: could not load model at %s" % _MODEL_PATH)
		return
	var inst := scene.instantiate() as Node3D
	# The GLB's front faces +X and it's authored far from its own origin. Rotate
	# its front to +Z (the cabinet front, where the controller ports and the
	# memory-card slot sit), then recentre it in X/Z on the origin (its body base
	# is already at y=0). Recentring is computed from the rotated mesh AABB so it
	# stays correct regardless of the rotation or a future re-export.
	inst.rotation_degrees.y = -90.0
	add_child(inst)
	var xz := _model_xz_center(inst)
	inst.position = Vector3(-xz.x, 0.0, -xz.y)

	# Disc lid (CD cover): its node origin is the rear-top hinge, so opening is a
	# rotation about the console's left-right axis through that origin. Poses are
	# computed lazily on first open (see _ensure_lid_poses) — global_transform is
	# not settled yet here in _ready.
	_lid = inst.find_child("DeckelPSX", true, false)


## Combined X/Z centre of all of `inst`'s meshes, expressed in this model node's
## local space (call after add_child, before setting inst.position).
func _model_xz_center(inst: Node3D) -> Vector2:
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
	var ctr := acc.position + acc.size * 0.5
	return Vector2(ctr.x, ctr.z)


## Rest the console body on the ground. The default console collision box bottoms
## out at y=-0.05, but this model's body base is at y=0 — without this it would
## float 5 cm once recentred.
func configure_collision(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col == null or not (col.shape is BoxShape3D):
		return
	col.shape = col.shape.duplicate()
	(col.shape as BoxShape3D).size = Vector3(0.2, 0.055, 0.28)
	col.position = Vector3(0, 0.0275, 0)


## Open/close the CD lid (driven by the OPEN button via RetroSystem's tray state).
func play_open() -> void:
	_ensure_lid_poses()
	_tween_lid(_lid_open)


func play_close() -> void:
	_ensure_lid_poses()
	_tween_lid(_lid_closed)


## Capture the closed pose and derive the open pose the first time the lid moves,
## when the console's global transform has settled. The lid stays closed until the
## OPEN button is pressed, so _lid.transform here is always the rest (closed) pose.
func _ensure_lid_poses() -> void:
	if _lid_poses_ready or _lid == null:
		return
	_lid_poses_ready = true
	_lid_closed = _lid.transform
	var axis := global_transform.basis.x.normalized()
	var g0 := _lid.global_transform
	var g_open := Transform3D(Basis(axis, deg_to_rad(LID_OPEN_DEG)) * g0.basis, g0.origin)
	_lid_open = (_lid.get_parent() as Node3D).global_transform.affine_inverse() * g_open


func _tween_lid(target: Transform3D) -> void:
	if _lid == null:
		return
	if _lid_tween and _lid_tween.is_valid():
		_lid_tween.kill()
	# Interpolate via Transform3D.interpolate_with (slerp rotation + lerp scale) —
	# a plain tween_property on a Transform3D lerps the raw basis components, which
	# mangles this lid's heavily-scaled basis (the GLB cm->m factor) mid-animation.
	var from := _lid.transform
	_lid_tween = create_tween()
	_lid_tween.tween_method(
		func(t: float) -> void: _lid.transform = from.interpolate_with(target, t),
		0.0, 1.0, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


func get_controller_port_count() -> int:
	return 2


## PSX saves live on removable memory cards (PCSX-ReARMed exposes memcard 1
## as RETRO_MEMORY_SAVE_RAM).
func uses_memory_cards() -> bool:
	return true


## Put the card slot on the front-left of the console, next to controller port 1.
func configure_memory_card_slot(slot: Node3D) -> void:
	slot.position = Vector3(-0.09, 0.02, 0.14)
