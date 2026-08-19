class_name CapsenseFingerSnap
extends SkeletonModifier3D

## Visual-only CCD IK for the runtime index finger. XRHandModifier3D writes the
## tracked pose first; this modifier follows it in the skeleton stack and rotates
## the proximal, intermediate and distal joints so the tip meets a nearby claimed
## surface. Bone origins and scales are never changed, so the finger cannot
## stretch. The tracked joint remains the interaction oracle.

const INDEX_PROXIMAL := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL
const INDEX_INTERMEDIATE := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_INTERMEDIATE
const INDEX_DISTAL := XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_DISTAL
const INDEX_TIP := XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP
const JOINTS: Array[int] = [INDEX_DISTAL, INDEX_INTERMEDIATE, INDEX_PROXIMAL]

## Contact farther away than this belongs to hand movement, not pose correction.
const MAX_REACH := 0.030
## Limit each joint's contribution so an edge claim cannot fold a finger back on
## itself. Two CCD passes are enough over a three-joint chain this short.
const MAX_JOINT_TURN := deg_to_rad(28.0)
const ITERATIONS := 2


func _process_modification() -> void:
	var skeleton := get_parent() as Skeleton3D
	var hand := skeleton.get_parent() as CapsenseHand if skeleton != null else null
	if skeleton == null or hand == null:
		return
	var contact: Dictionary = hand.visual_contact()
	if contact.is_empty():
		return
	var world_target := _skin_target(contact["point"], contact["normal"],
		hand.index_tip_radius())
	_solve(skeleton, skeleton.to_local(world_target as Vector3))


## The OpenXR tip transform is the centre of the fingertip joint, not the outer
## skin. Keep that centre one reported radius above the face so the mesh touches
## instead of entering the button.
func _skin_target(surface: Vector3, normal: Vector3, radius: float) -> Vector3:
	var n := normal.normalized() if normal.length_squared() > 1e-10 else Vector3.UP
	return surface + n * maxf(radius, 0.0)


## Kept separate so the synthetic probe can exercise the same solver without an
## OpenXR runtime mesh.
func _solve(skeleton: Skeleton3D, target: Vector3) -> void:
	if skeleton.get_bone_count() <= INDEX_TIP:
		return
	skeleton.force_update_all_bone_transforms()
	var start_tip := skeleton.get_bone_global_pose(INDEX_TIP).origin
	if start_tip.distance_to(target) > MAX_REACH:
		return

	for iteration in ITERATIONS:
		for joint in JOINTS:
			var joint_pose := skeleton.get_bone_global_pose(joint)
			var tip_pos := skeleton.get_bone_global_pose(INDEX_TIP).origin
			var from_tip := tip_pos - joint_pose.origin
			var to_target := target - joint_pose.origin
			if from_tip.length_squared() < 1e-10 or to_target.length_squared() < 1e-10:
				continue
			var turn := Quaternion(from_tip.normalized(), to_target.normalized())
			var angle := turn.get_angle()
			if angle > MAX_JOINT_TURN:
				turn = Quaternion.IDENTITY.slerp(turn, MAX_JOINT_TURN / angle)
			joint_pose.basis = Basis(turn) * joint_pose.basis
			# XRHandModifier3D writes a fresh tracked pose before this modifier on the
			# next frame. Only basis changes here; origin and scale are copied verbatim
			# from this frame's runtime result.
			skeleton.set_bone_global_pose(joint, joint_pose)
			skeleton.force_update_bone_child_transform(joint)
