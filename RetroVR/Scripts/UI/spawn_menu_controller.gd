## SpawnMenuController — manages the VR spawn panel.
## Attach as a Node3D in the scene (child of Root).
## Child "SpawnMenuViewport" must be an XRToolsViewport2DIn3D instance
## with "scene" set to spawn_menu.tscn.
##
## Toggle with the left controller's menu_button action.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE   := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE := preload("res://Scenes/Objects/cartridge.tscn")

# Y heights used when spawning each type onto the table
const SPAWN_Y := {
	"tv":         0.95,
	"system":     0.80,
	"cartridge":  0.76,
}

@onready var _viewport_node: XRToolsViewport2DIn3D = $SpawnMenuViewport

## Set to true by VRInputMapper while a system is being controlled, so the
## spawn menu toggle doesn't fire during gameplay.
var disabled: bool = false: set = _set_disabled

func _set_disabled(value: bool) -> void:
	disabled = value
	if disabled:
		_hide_menu()

var _camera:      XRCamera3D    = null
var _left_ctrl:   XRController3D = null
var _right_ctrl:  XRController3D = null
var _menu_connected := false

# Scroll state — driven by whichever stick whose controller points at the menu
var _smoothed_scroll_y: float = 0.0
const _SCROLL_SPEED    := 700.0   # pixels per second at full tilt
const _SCROLL_DEADZONE := 0.25    # stick Y dead zone (0..1)
const _SCROLL_MIN_PX   := 1.5     # discard sub-pixel nudges
const _SMOOTH_FACTOR   := 4.0     # low-pass weight; lower = smoother

# Grab constants
const _GRIP_THRESHOLD := 0.3
const _DEPTH_SPEED    := 0.8    # m/s at full stick
const _DEPTH_MIN      := 0.3    # min distance from camera
const _DEPTH_MAX      := 2.5    # max distance from camera
const _RESIZE_SPEED   := 0.4    # screen_size m/s at full stick
const _SIZE_MIN       := Vector2(0.45, 0.375)  # half default
const _SIZE_MAX       := Vector2(1.8, 1.5)     # double default
const _SCREEN_ASPECT  := 0.9 / 0.75

# Grab state
var _grab_active: bool = false
var _grab_ctrl: XRController3D = null
var _grab_distance: float = 0.0  # distance along pointer ray

# Locomotion nodes — suppressed per-controller while its pointer is on the menu
var _move_turn:     Node = null   # right stick snap-turn
var _func_teleport: Node = null   # right stick teleport aim
var _move_direct:   Node = null   # left stick walking

# FunctionPointer nodes for hit-testing
var _left_pointer:  XRToolsFunctionPointer = null
var _right_pointer: XRToolsFunctionPointer = null


func _ready() -> void:
	_viewport_node.visible = false
	# Remove layer 1 (default physics) so the menu doesn't collide with objects,
	# but keep layers 21 and 23 for pointer interaction.
	$SpawnMenuViewport/StaticBody3D.collision_layer = 5242880
	call_deferred("_deferred_setup")


func _deferred_setup() -> void:
	# Find XRCamera3D
	var cams := get_tree().root.find_children("*", "XRCamera3D", true, false)
	if not cams.is_empty():
		_camera = cams[0] as XRCamera3D

	# Find left-hand XRController3D and hook menu_button
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl.tracker == &"left_hand":
			_left_ctrl = ctrl
			_left_ctrl.button_pressed.connect(_on_controller_button)
			break

	# Find right-hand XRController3D for scroll driving
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl.tracker == &"right_hand":
			_right_ctrl = ctrl
			break

	# Locomotion nodes
	_move_turn     = get_tree().root.find_child("MovementTurn",     true, false)
	_func_teleport = get_tree().root.find_child("FunctionTeleport", true, false)
	_move_direct   = get_tree().root.find_child("MovementDirect",   true, false)

	# FunctionPointer nodes (one per controller) for hit-testing
	for node: Node in get_tree().root.find_children("*", "XRToolsFunctionPointer", true, false):
		var ptr := node as XRToolsFunctionPointer
		var parent_ctrl := ptr.get_parent() as XRController3D
		if parent_ctrl:
			if parent_ctrl.tracker == &"left_hand":
				_left_pointer = ptr
			elif parent_ctrl.tracker == &"right_hand":
				_right_pointer = ptr

	# Give the SubViewport one frame to instantiate the 2D scene
	await get_tree().process_frame
	_connect_menu_signals()


func _connect_menu_signals() -> void:
	if _menu_connected:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		# Scene hasn't loaded yet — retry next frame
		await get_tree().process_frame
		_connect_menu_signals()
		return
	var menu := vp.get_child(0)
	if menu.has_signal("spawn_requested"):
		menu.spawn_requested.connect(_on_spawn_requested)
	if menu.has_signal("close_requested"):
		menu.close_requested.connect(_hide_menu)
	if menu.has_signal("spawn_cartridge_requested"):
		menu.spawn_cartridge_requested.connect(_on_spawn_cartridge_requested)
	if menu.has_signal("turn_style_changed"):
		menu.turn_style_changed.connect(_on_turn_style_changed)
	_menu_connected = true


# ── Button handler ────────────────────────────────────────────────────────────

func _on_controller_button(action_name: String) -> void:
	if action_name == "primary_click":
		var sys := _get_pointed_system(_left_pointer)
		if sys:
			sys.toggle_options_ui(_camera)
			return
		if not disabled:
			_toggle_menu()


# ── Scroll driving ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var menu_visible: bool = _viewport_node.visible

	# When menu is closed, handle core options panel scroll instead.
	# VRInputMapper owns locomotion nodes when disabled — only touch them here
	# if a pointer is actually aimed at a core options panel.
	if not menu_visible:
		_process_core_options_scroll(delta)
		return

	# Determine which pointers are currently aimed at the menu panel
	var right_over: bool = _pointer_over_menu(_right_pointer)
	var left_over:  bool = _pointer_over_menu(_left_pointer)

	# Process grab (start, sustain, or end)
	_process_grab(delta, right_over, left_over)
	if _grab_active:
		# Suppress locomotion for the grabbing controller only
		if _grab_ctrl == _right_ctrl:
			_set_node_enabled(_move_turn,     false)
			_set_node_enabled(_func_teleport, false)
		elif _grab_ctrl == _left_ctrl:
			_set_node_enabled(_move_direct, false)
		return

	# Suppress right-stick locomotion only when right controller points at menu
	_set_node_enabled(_move_turn,     not right_over)
	_set_node_enabled(_func_teleport, not right_over)
	# Suppress left-stick walking only when left controller points at menu
	_set_node_enabled(_move_direct,   not left_over)

	if not (right_over or left_over):
		_smoothed_scroll_y = 0.0
		return

	# Combine stick inputs — whichever controller(s) are pointing contribute
	var raw_y: float = 0.0
	if right_over and _right_ctrl:
		raw_y += _right_ctrl.get_vector2("primary").y
	if left_over and _left_ctrl:
		raw_y += _left_ctrl.get_vector2("primary").y
	raw_y = clampf(raw_y, -1.0, 1.0)

	_smoothed_scroll_y = lerpf(_smoothed_scroll_y, raw_y, clampf(_SMOOTH_FACTOR * delta, 0.0, 1.0))
	if abs(_smoothed_scroll_y) < _SCROLL_DEADZONE:
		return

	var t: float = (abs(_smoothed_scroll_y) - _SCROLL_DEADZONE) / (1.0 - _SCROLL_DEADZONE)
	# Negate: stick up (negative Y in OpenXR) → scroll up (decrease scroll_vertical)
	var pixels: float = -_smoothed_scroll_y * t * _SCROLL_SPEED * delta
	if abs(pixels) < _SCROLL_MIN_PX:
		return

	var menu := _get_menu()
	if menu:
		menu.scroll_active(pixels)


## Drive scroll on any visible CoreOptionsPanel whose viewport the pointer is over.
func _process_core_options_scroll(delta: float) -> void:
	var right_vp := _find_core_options_viewport(_right_pointer)
	var left_vp  := _find_core_options_viewport(_left_pointer)

	if not disabled:
		_set_node_enabled(_move_turn,     right_vp == null)
		_set_node_enabled(_func_teleport, right_vp == null)
		_set_node_enabled(_move_direct,   left_vp  == null)

	if not right_vp and not left_vp:
		_smoothed_scroll_y = 0.0
		return

	var any_vp := right_vp if right_vp else left_vp

	var raw_y: float = 0.0
	if right_vp and _right_ctrl:
		raw_y += _right_ctrl.get_vector2("primary").y
	if left_vp and _left_ctrl:
		raw_y += _left_ctrl.get_vector2("primary").y
	raw_y = clampf(raw_y, -1.0, 1.0)

	_smoothed_scroll_y = lerpf(_smoothed_scroll_y, raw_y, clampf(_SMOOTH_FACTOR * delta, 0.0, 1.0))
	if abs(_smoothed_scroll_y) < _SCROLL_DEADZONE:
		return

	var t: float = (abs(_smoothed_scroll_y) - _SCROLL_DEADZONE) / (1.0 - _SCROLL_DEADZONE)
	var pixels: float = -_smoothed_scroll_y * t * _SCROLL_SPEED * delta
	if abs(pixels) < _SCROLL_MIN_PX:
		return

	var opts_ui := _get_core_options_ui(any_vp)
	if opts_ui:
		opts_ui.scroll_active(pixels)


## Returns the RetroSystem the pointer is aimed at, or null if not pointing at one.
## Each RetroSystem has a PointerArea (StaticBody3D on layer 21) that the pointer
## raycast can hit. We walk up from last_target looking for a RetroSystem ancestor.
## We return null early if we encounter an XRToolsViewport2DIn3D, so clicking on
## the spawn menu or core options panel is never misread as a system click.
func _get_pointed_system(pointer: XRToolsFunctionPointer) -> RetroSystem:
	if not pointer:
		return null
	var tgt: Node3D = pointer.last_target
	if not tgt:
		return null
	var node: Node = tgt
	while node:
		# If the pointer is inside any viewport, it's a UI click — not a system click
		if node is XRToolsViewport2DIn3D:
			return null
		if node is RetroSystem:
			return node as RetroSystem
		node = node.get_parent()
	return null


## Returns true if pointer's last_target is a node inside the spawn menu viewport.
func _pointer_over_menu(pointer: XRToolsFunctionPointer) -> bool:
	if not pointer:
		return false
	var tgt: Node3D = pointer.last_target
	if not tgt:
		return false
	var node: Node = tgt
	while node:
		if node == _viewport_node:
			return true
		node = node.get_parent()
	return false


## Returns the XRToolsViewport2DIn3D belonging to a CoreOptionsPanel that the
## pointer is currently aimed at, or null if not pointing at one.
func _find_core_options_viewport(pointer: XRToolsFunctionPointer) -> XRToolsViewport2DIn3D:
	if not pointer:
		return null
	var tgt: Node3D = pointer.last_target
	if not tgt:
		return null
	var node: Node = tgt
	while node:
		if node is XRToolsViewport2DIn3D:
			# Walk up to see if this viewport lives inside a CoreOptionsPanel
			var ancestor: Node = node.get_parent()
			while ancestor:
				if ancestor is CoreOptionsPanel:
					return node as XRToolsViewport2DIn3D
				ancestor = ancestor.get_parent()
			return null
		node = node.get_parent()
	return null


## Get the CoreOptions2D UI scene from a CoreOptionsPanel viewport node.
func _get_core_options_ui(viewport_node: XRToolsViewport2DIn3D) -> CoreOptions2D:
	var vp := viewport_node.get_node_or_null("Viewport") as SubViewport
	if vp and vp.get_child_count() > 0:
		var ui := vp.get_child(0)
		if ui is CoreOptions2D:
			return ui as CoreOptions2D
	return null


func _set_node_enabled(node: Node, value: bool) -> void:
	if node and "enabled" in node:
		node.set("enabled", value)



func _get_menu() -> SpawnMenu2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if vp and vp.get_child_count() > 0:
		var m := vp.get_child(0)
		if m is SpawnMenu2D:
			return m as SpawnMenu2D
	return null


# ── Visibility ────────────────────────────────────────────────────────────────

func _toggle_menu() -> void:
	if _viewport_node.visible:
		_hide_menu()
	else:
		_show_menu()


func _show_menu() -> void:
	if _camera:
		var forward := -_camera.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() < 0.001:
			forward = Vector3.FORWARD
		forward = forward.normalized()
		global_position = _camera.global_position + forward * 0.9 + Vector3(0, -0.05, 0)
		# look_at makes -Z face the camera; rotate 180° so +Z (the UV face) faces the player
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)
	_viewport_node.visible = true


func _hide_menu() -> void:
	_end_grab()
	_viewport_node.visible = false
	_smoothed_scroll_y = 0.0
	# Only restore locomotion if VRInputMapper hasn't taken control.
	# When disabled=true, VRInputMapper owns those nodes — don't touch them.
	if not disabled:
		_set_node_enabled(_move_turn,     true)
		_set_node_enabled(_func_teleport, true)
		_set_node_enabled(_move_direct,   true)


# ── Grab / Move / Resize ──────────────────────────────────────────────────────

func _process_grab(delta: float, right_over: bool, left_over: bool) -> void:
	if _grab_active:
		# Check grip still held
		if _grab_ctrl.get_float("grip") < _GRIP_THRESHOLD:
			_end_grab()
			return
		_update_grab_position()
		var stick := _grab_ctrl.get_vector2("primary")
		_process_grab_depth(delta, stick.y)
		_process_grab_resize(delta, stick.x)
	else:
		# Try to start grab — right controller first, then left
		if right_over and _right_ctrl:
			_try_start_grab(_right_ctrl, _right_pointer, true)
		if not _grab_active and left_over and _left_ctrl:
			_try_start_grab(_left_ctrl, _left_pointer, true)


func _try_start_grab(ctrl: XRController3D, _pointer: XRToolsFunctionPointer, over_menu: bool) -> void:
	if not over_menu:
		return
	if ctrl.get_float("grip") < _GRIP_THRESHOLD:
		return
	_grab_active = true
	_grab_ctrl = ctrl
	_grab_distance = ctrl.global_position.distance_to(global_position)
	_smoothed_scroll_y = 0.0


func _end_grab() -> void:
	_grab_active = false
	_grab_ctrl = null
	_grab_distance = 0.0


func _update_grab_position() -> void:
	# Place menu along controller's pointing direction at the stored distance
	var ray_dir := -_grab_ctrl.global_transform.basis.z
	global_position = _grab_ctrl.global_position + ray_dir * _grab_distance
	if _camera:
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


func _process_grab_depth(delta: float, stick_y: float) -> void:
	if abs(stick_y) < _SCROLL_DEADZONE:
		return
	# Stick up (positive Y) pushes menu further along the ray
	var change := stick_y * _DEPTH_SPEED * delta
	_grab_distance = clampf(_grab_distance + change, _DEPTH_MIN, _DEPTH_MAX)


func _process_grab_resize(delta: float, stick_x: float) -> void:
	if abs(stick_x) < _SCROLL_DEADZONE:
		return
	var current_size: Vector2 = _viewport_node.screen_size
	var change := stick_x * _RESIZE_SPEED * delta
	var new_w := clampf(current_size.x + change * _SCREEN_ASPECT, _SIZE_MIN.x, _SIZE_MAX.x)
	var new_h := new_w / _SCREEN_ASPECT
	new_h = clampf(new_h, _SIZE_MIN.y, _SIZE_MAX.y)
	_viewport_node.screen_size = Vector2(new_w, new_h)


# ── Spawning ──────────────────────────────────────────────────────────────────

func _on_spawn_requested(type: String) -> void:
	var obj: Node3D
	match type:
		"tv":
			obj = TV_SCENE.instantiate() as Node3D
		"cartridge":
			obj = CART_SCENE.instantiate() as Node3D
		_:
			# Any other type is treated as a systemid — spawn the generic system and assign it
			var sys := SYSTEM_SCENE.instantiate() as Node3D
			sys.set("systemid", type)
			obj = sys

	if not obj:
		return

	get_tree().current_scene.add_child(obj)

	# Place the new object 0.5 m in front of the menu at table height
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()

	obj.global_position = global_position + fwd * 0.5
	obj.global_position.y = SPAWN_Y.get(type, SPAWN_Y.get("system", 0.80))


func _on_spawn_cartridge_requested(rom_path: String, game_label: String) -> void:
	var obj := CART_SCENE.instantiate() as Node3D
	obj.set("rom_path", rom_path)
	obj.set("game_label", game_label)
	get_tree().current_scene.add_child(obj)

	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()

	obj.global_position = global_position + fwd * 0.5
	obj.global_position.y = SPAWN_Y.get("cartridge", 0.76)


func _on_turn_style_changed(value: String) -> void:
	if not _move_turn:
		return
	# XRToolsMovementTurn.TurnMode: SNAP = 1, SMOOTH = 2
	_move_turn.set("turn_mode", 1 if value == "SNAP" else 2)
