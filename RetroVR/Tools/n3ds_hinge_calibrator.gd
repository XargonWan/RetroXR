extends Node3D
## Interactive 3DS hinge-pivot calibrator (v3) — X-axis only, matching what
## dual_screen_handheld_model.gd actually does in production (a single
## rotation.x on LidPivot — no axis tilt).
##
## How to use:
##   1. Run this scene (F6).
##   2. Fly the camera yourself: hold RIGHT MOUSE and move to look around,
##      WASD to move, Q/E down/up, hold SHIFT to move faster. No need to use
##      the editor's Remote scene tree for the camera.
##   3. Nudge the marker with the ARROW KEYS — Up/Down = Y, Left/Right = Z.
##      Hold CTRL for fine control (0.2mm/s) to dial in ten-thousandths;
##      without Ctrl it moves faster (5mm/s) for coarse positioning. (You can
##      also still select HingeMarker in the Scene dock's "Remote" tab and
##      drag it with the gizmo or type into the Inspector, but the Inspector's
##      spin-box step is coarser than this — the arrow keys are the precise
##      way to do it.)
##   4. The lid auto-cycles: 2s closed, 0.6s at the authored rest pose (a
##      sanity checkpoint — always correct, doesn't move no matter where the
##      marker is), 2s flat-open (180°), then rest again.
##   5. Once BOTH the closed and open ends look right, read HingeMarker's Y/Z
##      off the Output panel (prints on every move) and send them back.

const CLOSED_HOLD := 2.0
const REST_HOLD := 0.6
const OPEN_HOLD := 2.0

const CAM_MOVE_SPEED := 0.18
const CAM_MOVE_SPEED_FAST := 0.6
const CAM_MOUSE_SENS := 0.0025

const MARKER_NUDGE_RATE := 0.005        # m/s, coarse (no modifier)
const MARKER_NUDGE_RATE_FINE := 0.0002  # m/s, fine (Ctrl held) — ~0.1mm per 0.5s

## Everything n3ds_model.gd reparents onto LidPivot (see its _lid_mesh_names()),
## plus the live TopScreen quad — all of these need re-seating when the test
## hinge moves, or they desync from the shell / from each other.
const LID_CHILD_NAMES: PackedStringArray = ["top", "GlasTop", "Slider3DKnob", "VolumeKnob", "TopScreen"]

var _model: Node3D
var _lid_pivot: Node3D
var _marker: Node3D
var _last_marker_pos := Vector3.INF
var _t := 0.0
var _base_half_z := 0.0
var _rest_open_deg := 155.0

## The TRUE authored-pose global position of each lid child's local origin —
## captured once, right after production builds the shell, before this tool
## touches anything. Invariant to hinge choice (see script header math), so
## it's the reference every re-seat below derives from.
var _raw_global: Dictionary = {}
var _hinge_original := Vector3.ZERO
var _rest_rot_deg := 0.0

var _cam: Camera3D
var _cam_yaw := 0.0
var _cam_pitch := 0.0
var _mouselook_active := false
var _profile_view := false
var _p_was_pressed := false

var _bottom_mesh: MeshInstance3D
var _top_mesh: MeshInstance3D
var _glastop_mesh: MeshInstance3D


func _ready() -> void:
	var scene := load("res://Scenes/Objects/system_models/n3ds.tscn") as PackedScene
	_model = scene.instantiate()
	add_child(_model)

	_marker = Node3D.new()
	_marker.name = "HingeMarker"
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.005
	sphere.height = 0.01
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material_override = mat
	_marker.add_child(mesh)
	add_child(_marker)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.55, 0.6)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -30, 0)
	light.light_energy = 1.4
	add_child(light)

	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_cam.position = Vector3(0.15, 0.2, 0.3)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	var fwd := -_cam.global_transform.basis.z
	_cam_yaw = atan2(-fwd.x, -fwd.z)
	_cam_pitch = asin(clampf(fwd.y, -1.0, 1.0))

	await get_tree().process_frame
	await get_tree().process_frame
	_lid_pivot = _model.get_node_or_null("LidPivot") as Node3D
	if _lid_pivot:
		_marker.position = _lid_pivot.position
		_hinge_original = _lid_pivot.position
		_rest_rot_deg = rad_to_deg(_lid_pivot.rotation.x)
		var rest_basis := Basis(Vector3.RIGHT, deg_to_rad(_rest_rot_deg))
		for nm in LID_CHILD_NAMES:
			var child := _lid_pivot.find_child(nm, true, false) as Node3D
			if child:
				_raw_global[nm] = _hinge_original + rest_basis * child.position
	if _model.has_method("get_lid_angle_deg"):
		_rest_open_deg = _model.get_lid_angle_deg()
	_bottom_mesh = _model.find_child("bottom", true, false) as MeshInstance3D
	_top_mesh = _model.find_child("top", true, false) as MeshInstance3D
	_glastop_mesh = _model.find_child("GlasTop", true, false) as MeshInstance3D
	if _bottom_mesh:
		_base_half_z = _bottom_mesh.get_aabb().size.z * 0.5
	print("[calibrator] base half-depth (z) = %.6f — naive hinge z was -%.6f" % [_base_half_z, _base_half_z])
	print("[calibrator] RIGHT-MOUSE + WASD/QE to fly the camera. Arrow keys nudge HingeMarker.")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_mouselook_active = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _mouselook_active else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _mouselook_active:
		_cam_yaw -= event.relative.x * CAM_MOUSE_SENS
		_cam_pitch -= event.relative.y * CAM_MOUSE_SENS
		_cam_pitch = clampf(_cam_pitch, -1.5, 1.5)


func _process(delta: float) -> void:
	_update_camera(delta)
	_update_marker_nudge(delta)

	if not is_instance_valid(_marker) or not is_instance_valid(_lid_pivot):
		return

	if not _marker.position.is_equal_approx(_last_marker_pos):
		_last_marker_pos = _marker.position
		print("[calibrator] hinge (y, z) = (%.6f, %.6f)   z-offset-from-naive = %.6f" %
			[_marker.position.y, _marker.position.z, _marker.position.z - (-_base_half_z)])
		_reseat_lid_children()

	_t += delta
	var total := CLOSED_HOLD + REST_HOLD + OPEN_HOLD + REST_HOLD
	var phase := fmod(_t, total)
	var open_deg: float
	if phase < CLOSED_HOLD:
		open_deg = 0.0
	elif phase < CLOSED_HOLD + REST_HOLD:
		open_deg = _rest_open_deg   # authored pose — sanity checkpoint, always correct
	elif phase < CLOSED_HOLD + REST_HOLD + OPEN_HOLD:
		open_deg = 180.0
	else:
		open_deg = _rest_open_deg

	if _model.has_method("set_lid_angle_deg"):
		_model.set_lid_angle_deg(open_deg)


## Re-derive every lid child's LOCAL position under LidPivot for the marker's
## CURRENT (y, z) — not just translate the pivot and reuse production's old
## local offsets (that just drags the whole rigid lid along for the ride,
## which is what you were seeing: "moving Y down also brings the top shell
## down"). Each child's local position becomes what it WOULD have been if
## production had built the shell with this hinge instead of its own
## estimate: L = R(rest_rot)^-1 @ (raw_global - hinge_test). Position only —
## rotation is still driven purely by rotation.x each frame, X-axis only.
func _reseat_lid_children() -> void:
	if _lid_pivot == null:
		return
	var inv_rest := Basis(Vector3.RIGHT, deg_to_rad(_rest_rot_deg)).inverse()
	for nm in LID_CHILD_NAMES:
		if not _raw_global.has(nm):
			continue
		var child := _lid_pivot.find_child(nm, true, false) as Node3D
		if child == null:
			continue
		child.position = inv_rest * ((_raw_global[nm] as Vector3) - _marker.position)
	_lid_pivot.position = Vector3(0.0, _marker.position.y, _marker.position.z)


## Keyboard-driven fine control, since the Inspector's spin-box step is too
## coarse to dial in ten-thousandths reliably. Up/Down = Y, Left/Right = Z.
func _update_marker_nudge(delta: float) -> void:
	if not is_instance_valid(_marker):
		return
	var fine := Input.is_key_pressed(KEY_CTRL)
	var rate := MARKER_NUDGE_RATE_FINE if fine else MARKER_NUDGE_RATE
	var dy := 0.0
	var dz := 0.0
	if Input.is_key_pressed(KEY_UP):
		dy += rate * delta
	if Input.is_key_pressed(KEY_DOWN):
		dy -= rate * delta
	if Input.is_key_pressed(KEY_RIGHT):
		dz += rate * delta
	if Input.is_key_pressed(KEY_LEFT):
		dz -= rate * delta
	if dy != 0.0 or dz != 0.0:
		_marker.position.y += dy
		_marker.position.z += dz


func _update_camera(delta: float) -> void:
	var speed := CAM_MOVE_SPEED_FAST if Input.is_key_pressed(KEY_SHIFT) else CAM_MOVE_SPEED
	var basis := Basis(Vector3.UP, _cam_yaw) * Basis(Vector3.RIGHT, _cam_pitch)
	_cam.transform.basis = basis
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= basis.z
	if Input.is_key_pressed(KEY_S):
		move += basis.z
	if Input.is_key_pressed(KEY_A):
		move -= basis.x
	if Input.is_key_pressed(KEY_D):
		move += basis.x
	if Input.is_key_pressed(KEY_E):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_Q):
		move -= Vector3.UP
	if move.length() > 0.0:
		_cam.position += move.normalized() * speed * delta
