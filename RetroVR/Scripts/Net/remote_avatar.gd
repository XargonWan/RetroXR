## RemoteAvatar — a remote player's presence: colored head ball (with visor so
## facing reads) + name label, plus two hand blocks for VR players.
## Poses arrive at ~20 Hz (push_pose); rendering interpolates the buffered
## stream at now − RENDER_DELAY for smooth motion.
class_name RemoteAvatar
extends Node3D

## Seconds behind real time we render — one pose interval of slack plus margin.
const RENDER_DELAY := 0.12
const MAX_BUFFER := 40

@onready var _head: MeshInstance3D = $Head
@onready var _left: MeshInstance3D = $LeftHand
@onready var _right: MeshInstance3D = $RightHand
@onready var _label: Label3D = $Head/NameLabel

var _is_vr := false
var _buf: Array[Dictionary] = []   # [{t: float, p: PackedFloat32Array(21)}]


func _ready() -> void:
	# Poses are applied directly each frame; interpolation smoothing would only
	# add latency and teleport-slide artifacts (project uses physics interp).
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	visible = false   # until the first pose arrives


func setup(display_name: String, color: Color, is_vr: bool) -> void:
	_is_vr = is_vr
	_label.text = display_name
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = color
	_head.material_override = head_mat
	var hand_mat := StandardMaterial3D.new()
	hand_mat.albedo_color = color.darkened(0.25)
	_left.material_override = hand_mat
	_right.material_override = hand_mat
	_left.visible = is_vr
	_right.visible = is_vr


func push_pose(pose: PackedFloat32Array) -> void:
	if pose.size() != 21:
		return
	_buf.append({"t": _now(), "p": pose})
	while _buf.size() > MAX_BUFFER:
		_buf.pop_front()
	visible = true


func _process(_delta: float) -> void:
	if _buf.is_empty():
		return
	var target := _now() - RENDER_DELAY

	var idx := _buf.size() - 1
	for i in _buf.size():
		if float(_buf[i]["t"]) >= target:
			idx = i
			break
	var b := _buf[idx]
	var a := _buf[maxi(0, idx - 1)]
	var t0 := float(a["t"])
	var t1 := float(b["t"])
	var w := 0.0 if t1 <= t0 else clampf((target - t0) / (t1 - t0), 0.0, 1.0)

	_apply_part(_head, a["p"], b["p"], 0, w)
	if _is_vr:
		_apply_part(_left, a["p"], b["p"], 7, w)
		_apply_part(_right, a["p"], b["p"], 14, w)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _apply_part(node: Node3D, pa: PackedFloat32Array, pb: PackedFloat32Array, at: int, w: float) -> void:
	var pos_a := Vector3(pa[at], pa[at + 1], pa[at + 2])
	var pos_b := Vector3(pb[at], pb[at + 1], pb[at + 2])
	var quat_a := Quaternion(pa[at + 3], pa[at + 4], pa[at + 5], pa[at + 6])
	var quat_b := Quaternion(pb[at + 3], pb[at + 4], pb[at + 5], pb[at + 6])
	if quat_a.length_squared() < 0.5 or quat_b.length_squared() < 0.5:
		return   # zeroed slot (desktop hands)
	node.position = pos_a.lerp(pos_b, w)
	node.quaternion = quat_a.normalized().slerp(quat_b.normalized(), w)
