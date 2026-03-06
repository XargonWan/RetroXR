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

# Locomotion nodes — suppressed per-controller while its pointer is on the menu
var _move_turn:     Node = null   # right stick snap-turn
var _func_teleport: Node = null   # right stick teleport aim
var _move_direct:   Node = null   # left stick walking

# FunctionPointer nodes for hit-testing
var _left_pointer:  XRToolsFunctionPointer = null
var _right_pointer: XRToolsFunctionPointer = null


func _ready() -> void:
	_viewport_node.visible = false
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

	# When menu is closed, don't touch locomotion nodes — VRInputMapper owns them
	if not menu_visible:
		_smoothed_scroll_y = 0.0
		return

	# Determine which pointers are currently aimed at the menu panel
	var right_over: bool = _pointer_over_menu(_right_pointer)
	var left_over:  bool = _pointer_over_menu(_left_pointer)

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
	_viewport_node.visible = false
	_smoothed_scroll_y = 0.0
	# Only restore locomotion if VRInputMapper hasn't taken control.
	# When disabled=true, VRInputMapper owns those nodes — don't touch them.
	if not disabled:
		_set_node_enabled(_move_turn,     true)
		_set_node_enabled(_func_teleport, true)
		_set_node_enabled(_move_direct,   true)


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
