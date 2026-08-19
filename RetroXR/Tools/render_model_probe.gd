## render_model_probe — what the runtime-supplied controller art does when there
## is no runtime: it must resolve to nothing, quietly, and every contract the room
## depends on must still hold over an empty model.
##
## Also pins the two pieces of arithmetic that a headset would otherwise be the
## only way to check: the aim-to-grip correction, and re-applying a fade to
## geometry that arrived after the fade started.
##
## Run: godot --headless --path RetroXR res://Tools/render_model_probe.tscn
extends Node3D

var _fail := false
var _tracker: XRControllerTracker = null


func _check(c: bool, m: String) -> void:
	print("[probe] %s: %s" % ["PASS" if c else "FAIL", m])
	if not c:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void: get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	var origin := XROrigin3D.new()
	add_child(origin)
	var ctrl := XRController3D.new()
	ctrl.set_script(load("res://Scripts/XR/controller_model.gd"))
	ctrl.tracker = &"left_hand"
	# Deliberately no FunctionPickup: _check_hold_state exists to undo a fade that
	# was left hanging with nothing in hand, so with a pickup present every
	# set_model_visible(false) here would be reversed on the next frame. What a
	# grab does to the art is grab_feel_probe's subject; this one is about what
	# the art layer does with a fade level.
	origin.add_child(ctrl)

	_tracker = XRControllerTracker.new()
	_tracker.name = &"left_hand"
	_tracker.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(_tracker)
	_set_poses()
	for i in 8:
		await get_tree().process_frame

	var art := ctrl.get_node_or_null("ModelArt") as ControllerArt
	_check(art != null, "the controller builds a ControllerArt child")
	if art == null:
		_finish()
		return

	# ── No runtime ────────────────────────────────────────────────────────
	_check(art.source == ControllerArt.Source.NONE,
		"no OpenXR session resolves to no art source (got %d)" % art.source)
	_check(art.get_child_count() == 0,
		"nothing is instantiated without a session (%d children)" % art.get_child_count())
	_check(art.fade_materials.is_empty(), "no materials are claimed")

	# A profile arriving is what drives the retry; it must not throw where the
	# runtime classes are absent or idle.
	_tracker.profile = "/interaction_profiles/oculus/touch_controller"
	for i in 4:
		await get_tree().process_frame
	_check(art.source == ControllerArt.Source.NONE,
		"a controller profile alone does not conjure a model")

	# ── The fade contract over an empty model ─────────────────────────────
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	_check(not art.visible, "fading out hides the art node")
	ctrl.call("set_model_visible", true)
	for i in 12:
		await get_tree().process_frame
	_check(art.visible, "fading back in shows it again")

	# ── Aim-to-grip correction ────────────────────────────────────────────
	# The controller follows the pose its `pose` property names, which this
	# project's action map binds to /input/aim/pose; a runtime model is authored
	# in grip space. Getting this wrong puts the controller in front of the hand.
	var aim := Transform3D(Basis.from_euler(Vector3(-0.5, 0.2, 0.1)), Vector3(0.0, 1.2, 0.0))
	var grip := Transform3D(Basis.from_euler(Vector3(-1.1, 0.05, -0.2)), Vector3(0.01, 1.17, 0.03))
	art.call("_ensure_grip_anchor")
	art.call("_update_grip_anchor")
	var anchor := art.get_node_or_null("GripAnchor") as Node3D
	_check(anchor != null, "the grip anchor is built on demand")
	if anchor != null:
		var want := aim.affine_inverse() * grip
		var got := anchor.transform
		_check(got.origin.distance_to(want.origin) < 0.0005,
			"grip anchor origin %.4f mm off" % (got.origin.distance_to(want.origin) * 1000.0))
		var dot: float = absf(got.basis.get_rotation_quaternion().dot(
			want.basis.get_rotation_quaternion()))
		_check(dot > 0.9999, "grip anchor rotation matches (dot %.5f)" % dot)
		# Composed back through the controller it must land on the grip pose.
		_check((aim * got).origin.distance_to(grip.origin) < 0.0005,
			"the art ends up at the grip pose, not the aim pose")

	# ── Geometry that arrives mid-fade ────────────────────────────────────
	# A runtime hands models over on its own schedule, and a grab in progress
	# must not be left with an opaque controller inside the held object.
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	var src := StandardMaterial3D.new()
	src.albedo_color = Color(0.8, 0.2, 0.1, 1.0)
	mesh.set_surface_override_material(0, src)
	art.add_child(mesh)
	art.call("_mark_dirty")
	for i in 6:
		await get_tree().process_frame

	var active := mesh.get_active_material(0) as BaseMaterial3D
	_check(active != null and active != src,
		"a runtime surface gets a material of our own, not the one it came with")
	if active != null:
		_check(active.albedo_color.a < 0.01,
			"late geometry inherits the current fade (alpha %.3f)" % active.albedo_color.a)
		_check(active.albedo_color.r > 0.7, "the duplicate keeps the original colour")
		_check(active.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA,
			"and is switched to alpha blending")
	_check(art.fade_materials.size() == 1,
		"one material is claimed, not one per walk (%d)" % art.fade_materials.size())

	ctrl.call("set_model_visible", true)
	for i in 12:
		await get_tree().process_frame
	var back := mesh.get_active_material(0) as BaseMaterial3D
	_check(back != null and back.albedo_color.a > 0.99, "and comes back opaque")
	_check(back != null and back.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED,
		"with alpha blending switched back off")

	# A surface the runtime shaded itself cannot take an alpha; it must be hidden
	# for the whole of a partial fade rather than left standing opaque.
	var shaded := MeshInstance3D.new()
	shaded.mesh = BoxMesh.new()
	shaded.set_surface_override_material(0, ShaderMaterial.new())
	art.add_child(shaded)
	art.call("_mark_dirty")
	ctrl.call("set_model_visible", false)
	for i in 12:
		await get_tree().process_frame
	_check(art.opaque_only.has(shaded), "an unfadeable surface is listed")
	_check(not shaded.visible, "and hidden instead of faded")

	_finish()


func _set_poses() -> void:
	_tracker.set_pose(&"default",
		Transform3D(Basis.from_euler(Vector3(-0.5, 0.2, 0.1)), Vector3(0.0, 1.2, 0.0)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	_tracker.set_pose(&"grip",
		Transform3D(Basis.from_euler(Vector3(-1.1, 0.05, -0.2)), Vector3(0.01, 1.17, 0.03)),
		Vector3.ZERO, Vector3.ZERO, XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _finish() -> void:
	print("[probe] %s" % ("FAILURES" if _fail else "all passed"))
	get_tree().quit(1 if _fail else 0)
