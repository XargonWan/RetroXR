## SpawnMenuController — manages the VR spawn panel.
## Attach as a Node3D in the scene (child of Root).
## Child "SpawnMenuViewport" must be an XRToolsViewport2DIn3D instance
## with "scene" set to spawn_menu.tscn.
##
## Toggle with the left controller's menu_button action.
extends Node3D

const SYSTEM_SCENE          := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE              := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE            := preload("res://Scenes/Objects/cartridge.tscn")
const DISC_SCENE            := preload("res://Scenes/Objects/disc.tscn")
const BOOK_SCENE            := preload("res://Scenes/Objects/pdf_book.tscn")
const TRASH_CAN_SCENE       := preload("res://Scenes/Objects/trash_can.tscn")
const RETRO_CONTROLLER_SCENE := preload("res://Scenes/Objects/retro_controller.tscn")
const RAY_GUN_SCENE         := preload("res://Scenes/Objects/ray_gun.tscn")
const VCR_SCENE             := preload("res://Scenes/Objects/vcr_player.tscn")
const MEMCARD_SCENE         := preload("res://Scenes/Objects/memory_card.tscn")
const TAPE_SCENE            := preload("res://Scenes/Objects/vcr_tape.tscn")
const TV_REMOTE_SCENE       := preload("res://Scenes/Objects/tv_remote.tscn")

# Y heights used when spawning each type onto the table
const SPAWN_Y := {
	"tv":               0.95,
	"system":           0.80,
	"cartridge":        0.76,
	"disc":             0.76,
	"book":             0.80,
	"trash_can":        0.90,
	"retro_controller": 0.80,
	"ray_gun":          0.82,
	"vcr_player":       0.80,
	"tape":             0.78,
	"tv_remote":        0.78,
	"memory_card":      0.78,
}

@onready var _viewport_node: XRToolsViewport2DIn3D = $SpawnMenuViewport

## Action name waiting for a key/mouse press during desktop rebinding ("" = none).
var _rebinding_action: String = ""

## RetroPad target waiting for a joypad press during GAME CONTROLLER rebinding ("" = none).
var _pad_rebinding_target: String = ""

## Set to true by VRInputMapper while a system is being controlled, so the
## spawn menu toggle doesn't fire during gameplay.
var disabled: bool = false: set = _set_disabled

func _set_disabled(value: bool) -> void:
	disabled = value
	_apply_menu_locomotion_blocks(false, false)
	if disabled:
		_hide_menu()

var _camera:      XRCamera3D    = null
var _left_ctrl:   XRController3D = null
var _right_ctrl:  XRController3D = null
var _desktop_pointer: XRToolsDesktopFunctionPointer = null
var _menu_connected := false
var _aim_crosshair_enabled := true
var _connect_retry_count: int = 0

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

var _last_fps: int = -1

var _locomotion_manager: LocomotionManager = null
var _move_turn: Node = null
var _player_body: XRToolsPlayerBody = null
var _fps_label: Label3D = null
var _vram_label: Label3D = null

# FunctionPointer nodes for hit-testing
var _left_pointer:  XRToolsFunctionPointer = null
var _right_pointer: XRToolsFunctionPointer = null


func _ready() -> void:
	_viewport_node.visible = false
	# Remove layer 1 (default physics) so the menu doesn't collide with objects,
	# but keep layers 21 and 23 for pointer interaction.
	$SpawnMenuViewport/StaticBody3D.collision_layer = 5242880
	call_deferred("_deferred_setup")


func _exit_tree() -> void:
	_apply_menu_locomotion_blocks(false, false)


func _deferred_setup() -> void:
	# Find XRCamera3D
	var cams := get_tree().root.find_children("*", "XRCamera3D", true, false)
	if not cams.is_empty():
		_camera = cams[0] as XRCamera3D
	if _camera:
		_desktop_pointer = _camera.get_node_or_null("FunctionDesktopPointer") as XRToolsDesktopFunctionPointer

	# Find left and right XRController3D in a single pass
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl.tracker == &"left_hand":
			_left_ctrl = ctrl
			_left_ctrl.button_pressed.connect(_on_controller_button)
		elif ctrl.tracker == &"right_hand":
			_right_ctrl = ctrl
		if _left_ctrl and _right_ctrl:
			break

	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_move_turn = get_tree().root.find_child("MovementTurn", true, false)
	_player_body = get_tree().root.find_child("PlayerBody", true, false) as XRToolsPlayerBody

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
		if _connect_retry_count >= 30:
			push_error("SpawnMenuController: menu scene failed to load after 30 frames")
			return
		_connect_retry_count += 1
		await get_tree().process_frame
		_connect_menu_signals()
		return
	var menu := vp.get_child(0) as SpawnMenu2D
	if not menu:
		return
	menu.spawn_requested.connect(_on_spawn_requested)
	menu.close_requested.connect(_hide_menu)
	menu.spawn_cartridge_requested.connect(_on_spawn_cartridge_requested)
	menu.spawn_manual_requested.connect(_on_spawn_manual_requested)
	menu.spawn_video_requested.connect(_on_spawn_video_requested)
	menu.turn_style_changed.connect(_on_turn_style_changed)
	menu.scene_change_requested.connect(_on_scene_change_requested)
	menu.scene_slot_load_requested.connect(_on_slot_load)
	menu.scene_slot_save_requested.connect(_on_slot_save)
	menu.scene_slot_delete_requested.connect(_on_slot_delete)
	menu.scene_slot_create_requested.connect(_on_slot_create)
	menu.scene_slot_rename_requested.connect(_on_slot_rename)
	menu.auto_save_changed.connect(_on_auto_save_changed)
	menu.show_fps_changed.connect(_on_show_fps_changed)
	menu.aim_crosshair_changed.connect(_on_aim_crosshair_changed)
	menu.snap_angle_changed.connect(_on_snap_angle_changed)
	menu.height_offset_changed.connect(_on_height_offset_changed)
	menu.fov_changed.connect(_on_fov_changed)
	menu.controller_bindings_changed.connect(_on_controller_bindings_changed)
	menu.rebind_started.connect(_on_rebind_started)
	menu.pad_rebind_started.connect(_on_pad_rebind_started)
	_menu_connected = true

	# Auto-load last active slot on startup (arcade only)
	var sm := get_node_or_null("/root/SceneManager")
	if sm and sm.current_scene_id == "arcade":
		if sm.active_slot_id != "clean":
			ScenePersistence.new().load_slot(get_tree().current_scene, sm.active_slot_id)


# ── Rebinding ─────────────────────────────────────────────────────────────────

func _on_rebind_started(action: String) -> void:
	_rebinding_action = action


func _on_pad_rebind_started(target: String) -> void:
	_pad_rebinding_target = target
	# Suspend live polling so the capture press can't drive a running game.
	GamepadBindings.suspend_polling = true


func _finish_pad_rebind(target: String, binding: String) -> void:
	_pad_rebinding_target = ""
	GamepadBindings.suspend_polling = false
	var menu := _get_menu()
	if menu:
		menu.on_pad_rebind_complete(target, binding)


# ── Button handler ────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	# Gamepad rebinding: capture the next joypad button / axis push.
	if _pad_rebinding_target != "":
		var target := _pad_rebinding_target
		# Escape (keyboard) cancels.
		if event is InputEventKey and (event as InputEventKey).pressed \
				and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
			_finish_pad_rebind(target, "")
			get_viewport().set_input_as_handled()
			return
		var binding := ""
		if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
			binding = GamepadBindings.encode_event(event)
		elif event is InputEventJoypadMotion \
				and absf((event as InputEventJoypadMotion).axis_value) > 0.6:
			binding = GamepadBindings.encode_event(event)
		if binding != "":
			_finish_pad_rebind(target, binding)
			get_viewport().set_input_as_handled()
		return

	# Desktop key rebinding: capture the next key or mouse button press.
	if _rebinding_action != "":
		var is_key   := event is InputEventKey
		var is_mouse := event is InputEventMouseButton
		if not (is_key or is_mouse):
			return
		# Only act on press, not release.
		if is_key   and not (event as InputEventKey).pressed:          return
		if is_mouse and not (event as InputEventMouseButton).pressed:   return
		var action := _rebinding_action
		_rebinding_action = ""
		var cancelled := is_key \
			and (event as InputEventKey).physical_keycode == KEY_ESCAPE
		if not cancelled:
			InputMap.action_erase_events(action)
			InputMap.action_add_event(action, event)
		var menu := _get_menu()
		if menu:
			menu.on_rebind_complete(action, null if cancelled else event)
		get_viewport().set_input_as_handled()
		return

	# Desktop: Tab toggles the spawn menu (or core options when pointing at a system)
	if event.is_action_pressed("desktop_spawn_menu"):
		if not get_viewport().use_xr:
			# The desktop InteractionResolver only reports interactable targets
			# (buttons/pickables), not a system/VCR's plain PointerArea body, so
			# raycast the pointable layer straight down the camera's aim instead.
			var host := _raycast_options_host()
			if host:
				host.toggle_options_ui(_camera)
				get_viewport().set_input_as_handled()
				return
		if not disabled:
			_toggle_menu()
		get_viewport().set_input_as_handled()
		return

	# Desktop: scroll wheel scrolls the visible spawn menu (when no object is held)
	if _viewport_node.visible and event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		var scroll_px := 0.0
		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_px = -_SCROLL_SPEED * 0.016
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_px =  _SCROLL_SPEED * 0.016
		if scroll_px != 0.0:
			var menu := _get_menu()
			if menu:
				menu.scroll_active(scroll_px)
			get_viewport().set_input_as_handled()


func _on_controller_button(action_name: String) -> void:
	if action_name == "primary_click":
		var host := _get_pointed_options_host(_left_pointer)
		if host:
			host.toggle_options_ui(_camera)
			return
		if not disabled:
			_toggle_menu()


# ── Scroll driving ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _fps_label:
		var fps := Engine.get_frames_per_second()
		if fps != _last_fps:
			_fps_label.text = "FPS: %d" % fps
			_last_fps = fps
	if _vram_label:
		var vram_mb := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1_048_576)
		_vram_label.text = "VRAM: %d MB" % vram_mb

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
		_apply_menu_locomotion_blocks(_grab_ctrl == _left_ctrl, _grab_ctrl == _right_ctrl)
		return

	_apply_menu_locomotion_blocks(left_over, right_over)

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

	var pixels := _compute_scroll_pixels(delta, raw_y)
	if pixels != 0.0:
		var menu := _get_menu()
		if menu:
			menu.scroll_active(pixels)


## Drive scroll on any visible CoreOptionsPanel whose viewport the pointer is over.
func _process_core_options_scroll(delta: float) -> void:
	var right_vp := _find_core_options_viewport(_right_pointer)
	var left_vp  := _find_core_options_viewport(_left_pointer)

	if disabled:
		_apply_menu_locomotion_blocks(false, false)
	else:
		_apply_menu_locomotion_blocks(left_vp != null, right_vp != null)

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

	var pixels := _compute_scroll_pixels(delta, raw_y)
	if pixels != 0.0:
		var opts_ui := _get_core_options_ui(any_vp)
		if opts_ui:
			opts_ui.scroll_active(pixels)


## Shared scroll-pixel calculation used by both menu and core-options scroll paths.
## Updates _smoothed_scroll_y and returns the pixel delta (0.0 if below threshold).
func _compute_scroll_pixels(delta: float, raw_y: float) -> float:
	_smoothed_scroll_y = lerpf(_smoothed_scroll_y, raw_y, clampf(_SMOOTH_FACTOR * delta, 0.0, 1.0))
	if abs(_smoothed_scroll_y) < _SCROLL_DEADZONE:
		return 0.0
	var t: float = (abs(_smoothed_scroll_y) - _SCROLL_DEADZONE) / (1.0 - _SCROLL_DEADZONE)
	var pixels := -_smoothed_scroll_y * t * _SCROLL_SPEED * delta
	return 0.0 if abs(pixels) < _SCROLL_MIN_PX else pixels


## Returns the RetroSystem the pointer is aimed at, or null if not pointing at one.
## Each RetroSystem has a PointerArea (StaticBody3D on layer 21) that the pointer
## raycast can hit. We walk up from last_target looking for a RetroSystem ancestor.
## We return null early if we encounter an XRToolsViewport2DIn3D, so clicking on
## the spawn menu or core options panel is never misread as a system click.
func _get_pointed_options_host(pointer: XRToolsFunctionPointer) -> Node3D:
	if not pointer:
		return null
	var tgt: Node3D = pointer.last_target
	if not tgt:
		return null
	var node: Node = tgt
	while node:
		# If the pointer is inside any viewport, it's a UI click — not an object click
		if node is XRToolsViewport2DIn3D:
			return null
		if node is RetroSystem or node is VCRPlayer or node is PDFBook or node is RetroCartridge or node is RetroTV:
			return node as Node3D
		node = node.get_parent()
	return null


## Raycast forward from the camera against the pointable layer (21) and return the
## RetroSystem / VCRPlayer / PDFBook / RetroCartridge the reticle is aimed at, or
## null. Used on desktop where the InteractionResolver won't report a bare
## PointerArea body.
func _raycast_options_host() -> Node3D:
	if not is_instance_valid(_camera):
		return null
	var space := _camera.get_world_3d().direct_space_state
	var from := _camera.global_position
	var to := from - _camera.global_transform.basis.z * 10.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 << 20   # 21: pointable
	q.collide_with_areas = true
	q.collide_with_bodies = true
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return null
	return _options_host_from_target(hit["collider"] as Node3D)


## Walk up from a raw target node to find an enclosing options host — a RetroSystem
## or VCRPlayer (desktop variant of _get_pointed_options_host — works without an
## XRToolsFunctionPointer).
func _options_host_from_target(tgt: Node3D) -> Node3D:
	var node: Node = tgt
	while node:
		if node is XRToolsViewport2DIn3D:
			return null
		if node is RetroSystem or node is VCRPlayer or node is PDFBook or node is RetroCartridge or node is RetroTV:
			return node as Node3D
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
			# Walk up to see if this viewport lives inside an options panel
			var ancestor: Node = node.get_parent()
			while ancestor:
				if ancestor is CoreOptionsPanel or ancestor is VCROptionsPanel:
					return node as XRToolsViewport2DIn3D
				ancestor = ancestor.get_parent()
			return null
		node = node.get_parent()
	return null


## Get the scrollable options UI (CoreOptions2D or VCROptions2D) from a panel
## viewport node. Both expose scroll_active(pixels).
func _get_core_options_ui(viewport_node: XRToolsViewport2DIn3D) -> Control:
	var vp := viewport_node.get_node_or_null("Viewport") as SubViewport
	if vp and vp.get_child_count() > 0:
		var ui := vp.get_child(0)
		if ui is CoreOptions2D or ui is VCROptions2D:
			return ui as Control
	return null


func _apply_menu_locomotion_blocks(left_blocked: bool, right_blocked: bool) -> void:
	if not _locomotion_manager:
		return
	_locomotion_manager.set_block(&"spawn_menu_left", LocomotionManager.CHANNEL_LEFT, left_blocked and not disabled)
	_locomotion_manager.set_block(&"spawn_menu_right", LocomotionManager.CHANNEL_RIGHT, right_blocked and not disabled)



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
	_apply_menu_locomotion_blocks(false, false)


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
	# Don't steal the grip if the controller's FunctionPickup is already ray-grabbing an object
	for child in ctrl.get_children():
		if child is XRToolsFunctionPickup and child.is_ray_grabbing():
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

## Add obj to the scene, place it 0.5 m in front of the menu at the type's table height.
func _place_spawned(obj: Node3D, type: String) -> void:
	get_tree().current_scene.add_child(obj)
	obj.add_to_group("spawned")
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	obj.global_position = global_position + fwd * 0.5
	obj.global_position.y = SPAWN_Y.get(type, SPAWN_Y.get("system", 0.80))
	# In a multiplayer session the host registers + broadcasts; a client's
	# local copy is converted into a spawn request the host executes.
	NetworkManager.on_local_spawn(obj)


func _on_spawn_requested(type: String) -> void:
	var obj: Node3D
	match type:
		"tv":
			obj = TV_SCENE.instantiate() as Node3D
		"cartridge":
			obj = CART_SCENE.instantiate() as Node3D
		"trash_can":
			obj = TRASH_CAN_SCENE.instantiate() as Node3D
		"vcr_player":
			obj = VCR_SCENE.instantiate() as Node3D
		"tv_remote":
			obj = TV_REMOTE_SCENE.instantiate() as Node3D
		"memory_card":
			obj = MEMCARD_SCENE.instantiate() as Node3D
		"retro_controller":
			obj = RETRO_CONTROLLER_SCENE.instantiate() as Node3D
		"ray_gun":
			var gun := RAY_GUN_SCENE.instantiate() as RayGun
			gun.show_laser_dot = _aim_crosshair_enabled
			obj = gun
		_:
			# Any other type is treated as a systemid
			var sys := SYSTEM_SCENE.instantiate() as RetroSystem
			sys.systemid = type
			obj = sys
	if obj:
		_place_spawned(obj, type)


func _on_spawn_cartridge_requested(rom_path: String, game_label: String, systemid := "") -> void:
	# Disc-based systems get a RetroDisc (same contract, disc-shaped body).
	var is_disc := MediaDimensions.is_disc_system(systemid)
	var cart := (DISC_SCENE if is_disc else CART_SCENE).instantiate() as RetroCartridge
	cart.rom_path = rom_path
	cart.game_label = game_label
	cart.systemid = systemid
	_place_spawned(cart, "disc" if is_disc else "cartridge")


func _on_spawn_manual_requested(pdf_path: String) -> void:
	var book := BOOK_SCENE.instantiate() as PDFBook
	book.pdf_path = pdf_path
	_place_spawned(book, "book")


func _on_spawn_video_requested(video_path: String) -> void:
	var tape := TAPE_SCENE.instantiate() as VCRTape
	tape.video_path = video_path
	tape.video_label = video_path.get_file().get_basename()
	_place_spawned(tape, "tape")


func _on_turn_style_changed(value: String) -> void:
	if not _move_turn:
		return
	# XRToolsMovementTurn.TurnMode: SNAP = 1, SMOOTH = 2
	_move_turn.set("turn_mode", 1 if value == "SNAP" else 2)


func _on_snap_angle_changed(degrees: float) -> void:
	if _move_turn:
		_move_turn.set("step_turn_angle", degrees)


func _on_height_offset_changed(offset: float) -> void:
	if _player_body:
		_player_body.player_height_offset = offset


func _on_fov_changed(degrees: float) -> void:
	if _camera:
		_camera.fov = degrees


func _on_aim_crosshair_changed(enabled: bool) -> void:
	_aim_crosshair_enabled = enabled
	for node in get_tree().get_nodes_in_group("spawned"):
		var gun := node as RayGun
		if gun:
			gun.show_laser_dot = enabled


func _on_controller_bindings_changed() -> void:
	for node in get_tree().get_nodes_in_group("spawned"):
		if node.has_method("reload_bindings"):
			node.call("reload_bindings")


func _on_show_fps_changed(enabled: bool) -> void:
	if enabled:
		if _fps_label == null and _camera:
			_fps_label = Label3D.new()
			_fps_label.text = "FPS: --"
			_fps_label.font_size = 12
			_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			_fps_label.modulate = Color(1.0, 1.0, 0.0)
			_fps_label.no_depth_test = true
			_fps_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			_fps_label.position = Vector3(-0.5, 0.15, -0.8)
			_camera.add_child(_fps_label)
			_vram_label = Label3D.new()
			_vram_label.text = "VRAM: --"
			_vram_label.font_size = 12
			_vram_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			_vram_label.modulate = Color(0.6, 1.0, 0.6)
			_vram_label.no_depth_test = true
			_vram_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			_vram_label.position = Vector3(-0.5, 0.08, -0.8)
			_camera.add_child(_vram_label)
	else:
		if _fps_label:
			_fps_label.queue_free()
			_fps_label = null
			_last_fps = -1
		if _vram_label:
			_vram_label.queue_free()
			_vram_label = null


# ── Scene management ──────────────────────────────────────────────────────────

func _on_scene_change_requested(scene_id: String) -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if not sm:
		return
	_hide_menu()
	sm.change_scene(scene_id)


func _on_slot_load(slot_id: String) -> void:
	var persistence := ScenePersistence.new()
	persistence.load_slot(get_tree().current_scene, slot_id)
	var sm := get_node_or_null("/root/SceneManager")
	if sm:
		sm.set_active_slot(slot_id)
	var menu := _get_menu()
	if menu:
		menu._rebuild_states_grid()


func _on_slot_save(slot_id: String) -> void:
	if slot_id == "clean":
		return
	ScenePersistence.new().save_slot(get_tree().current_scene, slot_id)


func _on_slot_delete(slot_id: String) -> void:
	if slot_id == "clean":
		return
	var persistence := ScenePersistence.new()
	persistence.delete_slot(slot_id)
	var sm := get_node_or_null("/root/SceneManager")
	if sm and sm.active_slot_id == slot_id:
		sm.set_active_slot("clean")
	var menu := _get_menu()
	if menu:
		menu._rebuild_states_grid()


func _on_slot_create() -> void:
	var persistence := ScenePersistence.new()
	var user_count := persistence.get_slots().filter(func(s: Dictionary) -> bool:
		return not s.get("readonly", false)
	).size()
	var name := "State %d" % (user_count + 1)
	var new_id := persistence.create_new_slot(get_tree().current_scene, name)
	var sm := get_node_or_null("/root/SceneManager")
	if sm:
		sm.set_active_slot(new_id)
	var menu := _get_menu()
	if menu:
		menu._rebuild_states_grid()


func _on_slot_rename(slot_id: String, new_name: String) -> void:
	ScenePersistence.new().rename_slot(slot_id, new_name)
	var menu := _get_menu()
	if menu:
		menu._rebuild_states_grid()


func _on_auto_save_changed(enabled: bool) -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if sm:
		sm.auto_save_on_switch = enabled
