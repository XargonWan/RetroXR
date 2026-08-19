## quest_render_model_probe — which controller-art tier a real headset serves,
## and what it hands over.
##
## Answers the questions no desktop run can: whether the runtime supplies a model
## at all, whether it arrives rigged (the core tier animates its own buttons, the
## Meta vendor tier hands back a plain glTF), where it sits relative to the
## controller's aim pose, and what it looks like.
##
## Ships as its own package (QuestRenderModelProbe preset, custom feature
## "rendermodelprobe") so the installed RetroXR is never disturbed. Read the
## [rmprobe] lines with: adb logcat -s 'godot:*'
extends Node3D

## Seconds at which the loaded model is re-described. A controller that is asleep
## when the session begins only turns up on a later pass.
const SAMPLES: Array[float] = [2.0, 6.0, 12.0, 20.0, 30.0]
const SHOT_PATH := "user://render_model.png"

var _frames := 0
var _elapsed := 0.0
var _controllers: Array[XRController3D] = []


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func() -> void: get_tree().quit(0))

	var xri: XRInterface = XRServer.find_interface("OpenXR")
	var initialized: bool = xri != null and xri.is_initialized()
	print("[rmprobe] OpenXR interface=%s initialized=%s" % [xri != null, initialized])
	if initialized:
		xri.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		get_viewport().use_xr = true

	print("[rmprobe] settings core=%s meta=%s" % [
		ProjectSettings.get_setting("xr/openxr/extensions/render_model", false),
		ProjectSettings.get_setting("xr/openxr/extensions/meta/render_model", false)])
	_report_classes()

	var origin := XROrigin3D.new()
	add_child(origin)
	var cam := XRCamera3D.new()
	origin.add_child(cam)
	for hand: StringName in [&"left_hand", &"right_hand"]:
		var ctrl := XRController3D.new()
		ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
		ctrl.tracker = hand
		origin.add_child(ctrl)
		_controllers.append(ctrl)

	_run.call_deferred()


func _process(delta: float) -> void:
	_frames += 1
	_elapsed += delta


func _run() -> void:
	for t: float in SAMPLES:
		await get_tree().create_timer(maxf(0.1, t - _elapsed)).timeout
		print("[rmprobe] alive t=%.1fs frames=%d" % [_elapsed, _frames])
		for ctrl in _controllers:
			_describe(ctrl)
	await _shoot()
	print("[rmprobe] ===== done =====")
	get_tree().quit(0)


func _report_classes() -> void:
	for name: String in ["OpenXRRenderModelExtension", "OpenXRRenderModelManager",
			"OpenXRFbRenderModel", "OpenXRFbRenderModelExtension"]:
		print("[rmprobe] class %s exists=%s" % [name, ClassDB.class_exists(name)])
	var has_core := Engine.has_singleton("OpenXRRenderModelExtension")
	var ext: Object = Engine.get_singleton("OpenXRRenderModelExtension") if has_core else null
	print("[rmprobe] core singleton=%s is_active=%s" % [
		ext != null, ext != null and ext.call("is_active")])


func _describe(ctrl: XRController3D) -> void:
	var art := ctrl.get_node_or_null("ModelArt") as ControllerArt
	if art == null:
		print("[rmprobe] %s: no ModelArt" % ctrl.tracker)
		return
	var tracker := XRServer.get_tracker(ctrl.tracker) as XRPositionalTracker
	var profile: String = tracker.profile if tracker != null else "<no tracker>"
	print("[rmprobe] %s: source=%d profile=%s mats=%d unfadeable=%d" % [
		ctrl.tracker, art.source, profile, art.fade_materials.size(), art.opaque_only.size()])

	var anchor := art.get_node_or_null("GripAnchor") as Node3D
	if anchor != null:
		print("[rmprobe] %s: grip anchor origin=%s basis=%s" % [
			ctrl.tracker, anchor.transform.origin,
			anchor.transform.basis.get_euler() * (180.0 / PI)])

	# The shape of what arrived: an articulated model brings a Skeleton3D or an
	# AnimationPlayer, a static one is meshes only.
	var counts := {"MeshInstance3D": 0, "Skeleton3D": 0, "AnimationPlayer": 0, "Node3D": 0}
	var aabb := AABB()
	var first := true
	for node in _walk(art):
		var cls := node.get_class()
		counts[cls] = int(counts.get(cls, 0)) + 1
		var mesh := node as MeshInstance3D
		if mesh != null and mesh.mesh != null:
			var box: AABB = mesh.global_transform * mesh.mesh.get_aabb()
			aabb = box if first else aabb.merge(box)
			first = false
	print("[rmprobe] %s: nodes=%s" % [ctrl.tracker, counts])
	if not first:
		print("[rmprobe] %s: world aabb pos=%s size=%s" % [ctrl.tracker, aabb.position, aabb.size])
	print("[rmprobe] %s: tree=%s" % [ctrl.tracker, _tree_names(art)])
	_describe_rig(ctrl, art)


## What the runtime model can be made to do. The bundled art moved bones named
## left_b_trigger_front and friends; if these match, the same input handlers can
## drive a runtime model.
func _describe_rig(ctrl: XRController3D, art: Node) -> void:
	for node in _walk(art):
		var skel := node as Skeleton3D
		if skel != null:
			var bones: PackedStringArray = []
			for i in skel.get_bone_count():
				bones.append(skel.get_bone_name(i))
			print("[rmprobe] %s: bones=%s" % [ctrl.tracker, ", ".join(bones)])
			# Bone-local units decide how far a button press should travel; the
			# bundled art was authored in centimetres and a metre-scale rig would
			# push a button clean through the shell.
			print("[rmprobe] %s: skel scale=%s motion_scale=%.4f" % [
				ctrl.tracker, skel.global_transform.basis.get_scale(), skel.motion_scale])
			for i in skel.get_bone_count():
				print("[rmprobe] %s:   bone %s rest=%s euler=%s" % [
					ctrl.tracker, skel.get_bone_name(i), skel.get_bone_rest(i).origin,
					skel.get_bone_rest(i).basis.get_euler() * (180.0 / PI)])
		var anim := node as AnimationPlayer
		if anim != null:
			print("[rmprobe] %s: animations=%s" % [ctrl.tracker, anim.get_animation_list()])
		var n3 := node as Node3D
		if n3 != null and node.name in ["root", "grip", "model"]:
			print("[rmprobe] %s: %s local origin=%s euler=%s" % [ctrl.tracker, node.name,
				n3.transform.origin, n3.transform.basis.get_euler() * (180.0 / PI)])


func _walk(node: Node, out: Array[Node] = []) -> Array[Node]:
	for child in node.get_children():
		out.append(child)
		_walk(child, out)
	return out


func _tree_names(art: Node) -> String:
	var parts: PackedStringArray = []
	for node in _walk(art):
		parts.append("%s(%s)" % [node.name, node.get_class()])
	return ", ".join(parts)


## A render of whatever the runtime gave us, taken through a SubViewport sharing
## the live world — the headset's own eye buffers cannot be read back.
func _shoot() -> void:
	var art: Node3D = _controllers[0].get_node_or_null("ModelArt")
	if art == null:
		return
	var sv := SubViewport.new()
	sv.size = Vector2i(720, 540)
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.world_3d = get_viewport().world_3d
	add_child(sv)
	var cam := Camera3D.new()
	sv.add_child(cam)
	cam.global_transform = Transform3D(Basis(), art.global_position + Vector3(0.0, 0.12, 0.28))
	cam.look_at(art.global_position, Vector3.UP)
	cam.current = true
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sv.add_child(light)
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var err := sv.get_texture().get_image().save_png(SHOT_PATH)
	print("[rmprobe] screenshot %s err=%d" % [SHOT_PATH, err])
