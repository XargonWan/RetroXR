## VRInputMapper — Phase 9: VR controller → libretro input routing.
##
## Attach combo: point right controller at a RetroSystem then press
## left X + right A simultaneously. A "CONTROLLED" label appears above
## the system and all non-menu controller input routes to libretro.
##
## Detach combo: press left X + right A simultaneously again.
##
## While attached:
##   Left  stick      → RETRO D-pad
##   Right stick      → RETRO analog right
##   Right A          → RETRO_JOYPAD_A
##   Right B          → RETRO_JOYPAD_B
##   Left  X          → RETRO_JOYPAD_X
##   Left  Y          → RETRO_JOYPAD_Y
##   Right trigger    → RETRO_JOYPAD_R2
##   Left  trigger    → RETRO_JOYPAD_L2
##   Right grip       → RETRO_JOYPAD_R
##   Left  grip       → RETRO_JOYPAD_L
##   Right stick click→ RETRO_JOYPAD_START
##   Left  stick click→ RETRO_JOYPAD_SELECT
class_name VRInputMapper
extends Node3D

const DPAD_THRESHOLD   := 0.4
const ANALOG_THRESHOLD := 0.15

@onready var _label_offset := Vector3(0, 0.3, 0)

var _left_ctrl:  XRController3D = null
var _right_ctrl: XRController3D = null

var _locomotion_manager: LocomotionManager = null

# Nodes to disable while in game mode
var _pointer_nodes: Array[Node] = []
var _pickup_nodes: Array[Node] = []
var _extra_disable_nodes: Array[Node] = []  # SpawnMenuController etc.

# Controlled state
var _controlled_system: RetroSystem = null
var _label: Label3D = null

# Virtual gamepad placeholder & cord (visible while attached)
var _gamepad_anchor: Node3D = null   # parent Node3D on right controller
var _controller_cord: VerletRope = null   # rope from gamepad top to system

# Combo tracking
var _left_ax_held  := false
var _right_ax_held := false
var _combo_triggered := false  # prevent re-fire while both held

# Cache of which RETRO actions are currently injected
var _action_states: Dictionary = {}


func _ready() -> void:
	call_deferred("_deferred_setup")


func _deferred_setup() -> void:
	# Find both XRController3D nodes
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl.tracker == &"left_hand":
			_left_ctrl = ctrl
			ctrl.button_pressed.connect(_on_left_button_pressed)
			ctrl.button_released.connect(_on_left_button_released)
		elif ctrl.tracker == &"right_hand":
			_right_ctrl = ctrl
			ctrl.button_pressed.connect(_on_right_button_pressed)
			ctrl.button_released.connect(_on_right_button_released)

	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager

	# Collect pointer nodes
	for node: Node in get_tree().root.find_children("*", "XRToolsFunctionPointer", true, false):
		_pointer_nodes.append(node)

	# Collect pickup nodes (no enabled prop → use process_mode)
	for node: Node in get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false):
		_pickup_nodes.append(node)

	# Suppress the spawn menu controller while in-game
	var spawn_ctl := get_tree().root.find_child("SpawnMenuController", true, false)
	if spawn_ctl:
		_extra_disable_nodes.append(spawn_ctl)


# ── Button signals ────────────────────────────────────────────────────────────

func _on_left_button_pressed(action: String) -> void:
	if action == "ax_button":
		_left_ax_held = true
		_check_combo()


func _on_left_button_released(action: String) -> void:
	if action == "ax_button":
		_left_ax_held = false
		_combo_triggered = false


func _on_right_button_pressed(action: String) -> void:
	if action == "ax_button":
		_right_ax_held = true
		_check_combo()


func _on_right_button_released(action: String) -> void:
	if action == "ax_button":
		_right_ax_held = false
		_combo_triggered = false


func _check_combo() -> void:
	if not (_left_ax_held and _right_ax_held):
		return
	if _combo_triggered:
		return
	_combo_triggered = true

	if _controlled_system:
		_detach()
	else:
		_try_attach()


# ── Attach / Detach ───────────────────────────────────────────────────────────

func _try_attach() -> void:
	if not _right_ctrl:
		return

	# Raycast from right controller forward (aim_pose direction) up to 6 m
	var from := _right_ctrl.global_position
	var fwd  := -_right_ctrl.global_transform.basis.z
	var to   := from + fwd * 6.0

	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit   := get_world_3d().direct_space_state.intersect_ray(query)

	var system: RetroSystem = null

	if hit:
		# Walk up the collision body's ancestry to find a RetroSystem
		var node: Node = hit["collider"] as Node
		while node:
			if node is RetroSystem:
				system = node as RetroSystem
				break
			node = node.get_parent()

	if not system:
		# Fallback: nearest RetroSystem in the "retro_system" group within 6 m
		for s: Node in get_tree().get_nodes_in_group("retro_system"):
			if s is RetroSystem:
				var dist := _right_ctrl.global_position.distance_to(
					(s as Node3D).global_position)
				if dist < 6.0:
					system = s as RetroSystem
					break

	if not system:
		return

	_controlled_system = system

	# Show floating label
	_label = Label3D.new()
	_label.text = "CONTROLLED"
	_label.font_size = 20
	_label.modulate = Color(0.2, 1.0, 0.3)
	_label.position = _label_offset
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_controlled_system.add_child(_label)

	system.set_input_enabled(true)
	_set_player_input_enabled(false)
	_spawn_gamepad_visuals()


func _detach() -> void:
	_release_all_retro_actions()
	_destroy_gamepad_visuals()

	if is_instance_valid(_label):
		_label.queue_free()
	_label = null

	if is_instance_valid(_controlled_system):
		_controlled_system.set_input_enabled(false)
	_controlled_system = null
	_set_player_input_enabled(true)


## Spawn a placeholder gamepad mesh on the right controller and a VerletRope
## cord connecting it to the system's CableAttachPoint.
func _spawn_gamepad_visuals() -> void:
	if not _right_ctrl:
		return

	# Hide the XRController3D visual models on both hands
	for ctrl: Node in [_left_ctrl, _right_ctrl]:
		if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
			ctrl.call("set_model_visible", false)

	# Build a dark-grey box mesh as the placeholder gamepad
	_gamepad_anchor = Node3D.new()
	_gamepad_anchor.name = "GamepadAnchor"
	# Offset so it sits naturally in the palm (forward and slightly down)
	_gamepad_anchor.position = Vector3(0.0, -0.02, -0.04)
	_right_ctrl.add_child(_gamepad_anchor)

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.06, 0.025)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.15, 0.15)
	mesh_inst.set_surface_override_material(0, mat)
	_gamepad_anchor.add_child(mesh_inst)

	# Cord exit point at the top-centre of the gamepad box
	var cord_start := Node3D.new()
	cord_start.name = "CordStart"
	cord_start.position = Vector3(0.0, 0.04, 0.0)
	_gamepad_anchor.add_child(cord_start)

	# Controller cord attaches to the front of the system (opposite side from the video port)
	var system_attach: Node3D = _controlled_system.get_node_or_null("ControllerCordAttach") as Node3D
	if not system_attach:
		system_attach = _controlled_system.get_node_or_null("CableAttachPoint") as Node3D
	if not system_attach:
		return

	# Create VerletRope: 12 segments × 0.08 m ≈ 1 m total, enough to reach nearby systems
	_controller_cord = VerletRope.new()
	_controller_cord.segment_count = 12
	_controller_cord.segment_length = 0.08
	_controller_cord.damping = 0.05
	_controller_cord.top_level = true
	get_tree().current_scene.add_child(_controller_cord)
	_controller_cord.start_node = cord_start
	_controller_cord.end_node = system_attach
	_controller_cord._init_points()


## Free the placeholder gamepad mesh and cord, restore controller models.
func _destroy_gamepad_visuals() -> void:
	if is_instance_valid(_controller_cord):
		_controller_cord.queue_free()
	_controller_cord = null

	if is_instance_valid(_gamepad_anchor):
		_gamepad_anchor.queue_free()
	_gamepad_anchor = null

	# Restore the XRController3D visual models
	for ctrl: Node in [_left_ctrl, _right_ctrl]:
		if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
			ctrl.call("set_model_visible", true)


# Enable or disable locomotion, pointer, and pickup nodes
func _set_player_input_enabled(enabled: bool) -> void:
	if _locomotion_manager:
		_locomotion_manager.set_block(&"retro_control_mode", LocomotionManager.CHANNEL_ALL, not enabled)

	for node: Node in _pointer_nodes:
		if is_instance_valid(node) and "enabled" in node:
			node.set("enabled", enabled)

	for node: Node in _pickup_nodes:
		if is_instance_valid(node):
			node.process_mode = Node.PROCESS_MODE_INHERIT if enabled \
				else Node.PROCESS_MODE_DISABLED

	for node: Node in _extra_disable_nodes:
		if is_instance_valid(node) and "disabled" in node:
			node.set("disabled", not enabled)


# ── Per-frame input routing ───────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if not _controlled_system or not _left_ctrl or not _right_ctrl:
		return

	# Left stick → D-pad
	var ls: Vector2 = _left_ctrl.get_vector2("primary")
	_set_action("RETRO_JOYPAD_UP",    ls.y >  DPAD_THRESHOLD)
	_set_action("RETRO_JOYPAD_DOWN",  ls.y < -DPAD_THRESHOLD)
	_set_action("RETRO_JOYPAD_LEFT",  ls.x < -DPAD_THRESHOLD)
	_set_action("RETRO_JOYPAD_RIGHT", ls.x >  DPAD_THRESHOLD)

	# Right stick → RETRO analog right
	var rs: Vector2 = _right_ctrl.get_vector2("primary")
	_set_action("RETRO_ANALOG_RIGHT_X_NEGATIVE", rs.x < -ANALOG_THRESHOLD)
	_set_action("RETRO_ANALOG_RIGHT_X_POSITIVE", rs.x >  ANALOG_THRESHOLD)
	_set_action("RETRO_ANALOG_RIGHT_Y_NEGATIVE", rs.y < -ANALOG_THRESHOLD)
	_set_action("RETRO_ANALOG_RIGHT_Y_POSITIVE", rs.y >  ANALOG_THRESHOLD)

	# Face buttons
	_set_action("RETRO_JOYPAD_A", _right_ctrl.get_float("ax_button") > 0.5)
	_set_action("RETRO_JOYPAD_B", _right_ctrl.get_float("by_button") > 0.5)
	_set_action("RETRO_JOYPAD_X", _left_ctrl.get_float("ax_button")  > 0.5)
	_set_action("RETRO_JOYPAD_Y", _left_ctrl.get_float("by_button")  > 0.5)

	# Triggers
	_set_action("RETRO_JOYPAD_R2", _right_ctrl.get_float("trigger") > 0.3)
	_set_action("RETRO_JOYPAD_L2", _left_ctrl.get_float("trigger")  > 0.3)

	# Grips
	_set_action("RETRO_JOYPAD_R", _right_ctrl.get_float("grip") > 0.3)
	_set_action("RETRO_JOYPAD_L", _left_ctrl.get_float("grip")  > 0.3)

	# Thumbstick clicks — right = Start, left = Select
	_set_action("RETRO_JOYPAD_START",  _right_ctrl.get_float("primary_click") > 0.5)
	_set_action("RETRO_JOYPAD_SELECT", _left_ctrl.get_float("primary_click")  > 0.5)


# ── Action helpers ────────────────────────────────────────────────────────────

func _set_action(action: String, pressed: bool) -> void:
	var was: bool = _action_states.get(action, false)
	if pressed == was:
		return
	_action_states[action] = pressed
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)


func _release_all_retro_actions() -> void:
	for action: String in _action_states:
		if _action_states[action]:
			Input.action_release(action)
	_action_states.clear()
