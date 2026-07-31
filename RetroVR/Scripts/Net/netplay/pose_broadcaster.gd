## PoseBroadcaster — samples the local player's head/hand poses for the
## NetworkManager. Added at runtime as a child of the rig's XROrigin3D
## (next to the XRCamera3D and the two XRController3D hands).
extends Node

var _camera: XRCamera3D = null
var _left: XRController3D = null
var _right: XRController3D = null


func _ready() -> void:
	for child: Node in get_parent().get_children():
		if child is XRCamera3D:
			_camera = child
		elif child is XRController3D:
			var ctrl := child as XRController3D
			if ctrl.tracker == &"left_hand":
				_left = ctrl
			elif ctrl.tracker == &"right_hand":
				_right = ctrl


## PackedFloat32Array(21): head pos+quat, left pos+quat, right pos+quat.
## Hands are zeroed in desktop mode (no tracking).
func sample() -> PackedFloat32Array:
	if not is_instance_valid(_camera):
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(21)
	_write_pose(out, 0, _camera.global_transform)
	var vr: bool = get_viewport().use_xr
	if vr and is_instance_valid(_left):
		_write_pose(out, 7, _left.global_transform)
	if vr and is_instance_valid(_right):
		_write_pose(out, 14, _right.global_transform)
	return out


static func _write_pose(out: PackedFloat32Array, at: int, xform: Transform3D) -> void:
	var pos := xform.origin
	var quat := xform.basis.get_rotation_quaternion()
	out[at] = pos.x
	out[at + 1] = pos.y
	out[at + 2] = pos.z
	out[at + 3] = quat.x
	out[at + 4] = quat.y
	out[at + 5] = quat.z
	out[at + 6] = quat.w
