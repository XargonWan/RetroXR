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
const UMD_DISC_SCENE        := preload("res://Scenes/Objects/umd_disc.tscn")
const BOOK_SCENE            := preload("res://Scenes/Objects/pdf_book.tscn")
const TRASH_CAN_SCENE       := preload("res://Scenes/Objects/trash_can.tscn")
const RETRO_CONTROLLER_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
# Stand-in Virtual Boy pad: carries the console POWER switch, like the real one.
const VB_CONTROLLER_SCENE   := preload("res://Scenes/Objects/controllers/vb_controller.tscn")
const RETRO_MOUSE_SCENE     := preload("res://Scenes/Objects/retro_mouse.tscn")
const RETRO_KEYBOARD_SCENE  := preload("res://Scenes/Objects/retro_keyboard.tscn")
const RETRO_MULTITAP_SCENE  := preload("res://Scenes/Objects/controllers/retro_multitap.tscn")
const RAY_GUN_SCENE         := preload("res://Scenes/Objects/ray_gun.tscn")
const VCR_SCENE             := preload("res://Scenes/Objects/vcr_player.tscn")
const MEMCARD_SCENE         := preload("res://Scenes/Objects/memory_card.tscn")
const GAMECUBE_MEMCARD_SCENE := preload("res://Scenes/Objects/gamecube_memory_card.tscn")
const TAPE_SCENE            := preload("res://Scenes/Objects/vcr_tape.tscn")
const TV_REMOTE_SCENE       := preload("res://Scenes/Objects/tv_remote.tscn")
const DVD_PLAYER_SCENE      := preload("res://Scenes/Objects/dvd_player.tscn")
const DVD_DISC_SCENE        := preload("res://Scenes/Objects/dvd_disc.tscn")
const CD_PLAYER_SCENE       := preload("res://Scenes/Objects/cd_player.tscn")
const CASSETTE_PLAYER_SCENE := preload("res://Scenes/Objects/cassette_player.tscn")
const AUDIO_DISC_SCENE      := preload("res://Scenes/Objects/audio_disc.tscn")
const AUDIO_CASSETTE_SCENE  := preload("res://Scenes/Objects/audio_cassette.tscn")

## Licence-pending peripherals: spawn token → [GLB, bespoke scene].
##
## Each GLB lives in imported-assets/, which a default (placeholder) build
## excludes. Only a build that explicitly asked for the unbundled models spawns
## the bespoke scene; every other build spawns the procedural RetroController in
## its place. See _instantiate_peripheral, and RetroModelPolicy for the switch.
##
## Kept as a table rather than twelve near-identical match arms so the licence
## probe can walk the same list the spawn menu uses, instead of a copy of it.
const PERIPHERAL_MODELS: Dictionary = {
	"dualshock":           ["res://unbundled-models/controllers/dualshock.glb",           "res://unbundled-models/scenes/dualshock.tscn"],
	"dualshock2":          ["res://unbundled-models/controllers/dualshock2.glb",          "res://unbundled-models/scenes/dualshock2.tscn"],
	"gamecube_controller": ["res://unbundled-models/controllers/gamecube_controller.glb", "res://unbundled-models/scenes/gamecube_controller.tscn"],
	"dreamcast_controller":["res://unbundled-models/controllers/dreamcast_controller.glb","res://unbundled-models/scenes/dreamcast_controller.tscn"],
	"nes_controller":      ["res://unbundled-models/controllers/nes_controller.glb",      "res://unbundled-models/scenes/nes_controller.tscn"],
	"genesis_controller":  ["res://unbundled-models/controllers/genesis_controller.glb",  "res://unbundled-models/scenes/genesis_controller.tscn"],
	"megadrive_controller":["res://unbundled-models/controllers/megadrive_controller.glb","res://unbundled-models/scenes/megadrive_controller.tscn"],
	"saturn_controller":   ["res://unbundled-models/controllers/saturn_controller.glb",   "res://unbundled-models/scenes/saturn_controller.tscn"],
	"snes_controller":     ["res://unbundled-models/controllers/snes_controller.glb",     "res://unbundled-models/scenes/snes_controller.tscn"],
	"atari_joystick":      ["res://unbundled-models/controllers/atari_joystick.glb",      "res://unbundled-models/scenes/atari_joystick.tscn"],
	"n64_controller":      ["res://unbundled-models/controllers/n64_controller.glb",      "res://unbundled-models/scenes/n64_controller.tscn"],
	"psx_controller":      ["res://unbundled-models/controllers/psx_controller.glb",      "res://unbundled-models/scenes/psx_controller.tscn"],
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

# World scale (below 1.0 = player feels smaller / room feels bigger). Applied at
# startup and tunable from the menu's Controls section. Not persisted — resets to
# the default each launch (like the other comfort settings).
const DEFAULT_WORLD_SCALE := 0.7
var _world_scale := 1.0
var _base_eye_height := 1.65   # desktop XRCamera3D rest eye height; cached at setup

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
		# Cache the un-scaled desktop eye height, then apply the default world scale.
		_base_eye_height = _camera.transform.origin.y
		_apply_world_scale(DEFAULT_WORLD_SCALE)

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
	menu.spawn_dvd_requested.connect(_on_spawn_dvd_requested)
	menu.spawn_cd_requested.connect(_on_spawn_cd_requested)
	menu.spawn_cassette_requested.connect(_on_spawn_cassette_requested)
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
	menu.controller_hands_changed.connect(_on_controller_hands_changed)
	menu.snap_angle_changed.connect(_on_snap_angle_changed)
	menu.height_offset_changed.connect(_on_height_offset_changed)
	menu.fov_changed.connect(_on_fov_changed)
	menu.world_scale_changed.connect(_on_world_scale_changed)
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

	# Desktop: scroll wheel scrolls the options panel under the reticle, or falls
	# back to the visible spawn menu (when no object is held — pickup's push/pull
	# consumes the wheel first while holding).
	if event is InputEventMouseButton:
		var mbe := event as InputEventMouseButton
		var scroll_px := 0.0
		if mbe.button_index == MOUSE_BUTTON_WHEEL_UP:
			scroll_px = -_SCROLL_SPEED * 0.016
		elif mbe.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_px =  _SCROLL_SPEED * 0.016
		if scroll_px != 0.0:
			# While a desktop hand is holding an object the wheel is its push/pull
			# (desktop_pickup). Bail WITHOUT consuming so that handler still gets
			# it — otherwise, with the spawn menu open, the menu ate the wheel and
			# the held object couldn't be pulled closer. (This is the "pickup
			# consumes the wheel first while holding" the comment above assumes,
			# which tree order does not actually guarantee.)
			if not get_viewport().use_xr and _grabber_busy(_spawn_grabber()):
				return
			var ui := _raycast_scrollable_ui()
			if ui:
				ui.scroll_active(scroll_px)
				get_viewport().set_input_as_handled()
			elif _viewport_node.visible:
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

	# Remember which hand STARTS a trigger press while its laser is on the
	# menu — UI buttons emit `pressed` on trigger RELEASE, so by the time a
	# spawn handler runs the clicking hand's trigger already reads up, and
	# with both lasers on the menu the spawn used to fall back to the wrong
	# hand (left click -> right hand).
	_track_menu_press(_left_ctrl, left_over)
	_track_menu_press(_right_ctrl, right_over)

	# Process grab (start, sustain, or end)
	_process_grab(delta, right_over, left_over)
	if _grab_active:
		_apply_menu_locomotion_blocks(_grab_ctrl == _left_ctrl, _grab_ctrl == _right_ctrl)
		return

	_apply_menu_locomotion_blocks(left_over, right_over)

	if not (right_over or left_over):
		# Menu is open but neither laser is on it — a floating options panel
		# (system/TV/VCR/…) may still be under a pointer, so let it scroll.
		_process_core_options_scroll(delta)
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


## Drive stick scroll on any visible options panel whose viewport a pointer is over.
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
		var opts_ui := _get_scrollable_ui(any_vp)
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
		if node is RetroSystem or node is VCRPlayer or node is DVDPlayer or node is PDFBook or node is RetroCartridge or node is RetroTV or node is RetroMouse:
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
		if node is RetroSystem or node is VCRPlayer or node is DVDPlayer or node is PDFBook or node is RetroCartridge or node is RetroTV or node is RetroMouse:
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


## Returns the XRToolsViewport2DIn3D of an options panel the pointer is currently
## aimed at (any panel whose 2D UI exposes scroll_active — system, VCR, TV,
## cartridge, book, …), or null. The spawn menu has its own scroll path.
func _find_core_options_viewport(pointer: XRToolsFunctionPointer) -> XRToolsViewport2DIn3D:
	if not pointer:
		return null
	var tgt: Node3D = pointer.last_target
	if not tgt:
		return null
	var node: Node = tgt
	while node:
		if node is XRToolsViewport2DIn3D:
			if node == _viewport_node:
				return null
			if _get_scrollable_ui(node as XRToolsViewport2DIn3D):
				return node as XRToolsViewport2DIn3D
			return null
		node = node.get_parent()
	return null


## Get the scrollable options UI from a panel viewport node — the 2D root of any
## panel that exposes scroll_active(pixels) (CoreOptions2D, TVOptions2D,
## SpawnMenu2D, …). Null if the viewport is hidden or its UI can't scroll.
func _get_scrollable_ui(viewport_node: XRToolsViewport2DIn3D) -> Control:
	if not viewport_node.is_visible_in_tree():
		return null
	var vp := viewport_node.get_node_or_null("Viewport") as SubViewport
	if vp and vp.get_child_count() > 0:
		var ui := vp.get_child(0)
		if ui is Control and ui.has_method("scroll_active"):
			return ui as Control
	return null


## Desktop wheel support: raycast the pointable layer (21) straight down the
## camera's aim and return the scrollable 2D UI of whatever panel viewport the
## reticle is over (spawn menu included), or null.
func _raycast_scrollable_ui() -> Control:
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
	var node: Node = hit["collider"] as Node3D
	while node:
		if node is XRToolsViewport2DIn3D:
			return _get_scrollable_ui(node as XRToolsViewport2DIn3D)
		node = node.get_parent()
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
		# This is a teleport, not motion — clear the interpolation history so the
		# menu doesn't visibly slide from its previous transform (very noticeable
		# on the first open, where it starts at the scene-default position) with
		# common/physics_interpolation enabled.
		reset_physics_interpolation()
	_viewport_node.visible = true
	# The menu Control itself is always visible; it's this 3D node that gets
	# toggled. Tell the menu so it can flush notifications that happened while
	# it was hidden and do its cheap library change-check.
	var menu := _get_menu()
	if menu:
		menu.on_menu_shown()


func _hide_menu() -> void:
	_end_grab()
	_viewport_node.visible = false
	var menu := _get_menu()
	if menu:
		menu.on_menu_hidden()
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

# The hand that most recently STARTED a trigger press with its laser on the
# menu (sampled per frame in _process) — the authoritative "who clicked".
var _menu_press_ctrl: XRController3D = null
var _menu_press_ms := 0
var _trigger_was_down: Dictionary = {}


## Rising-edge sampler: record the hand the moment its trigger goes down while
## pointing at the menu. UI buttons fire on RELEASE, so this is captured
## frames before any spawn handler runs.
func _track_menu_press(ctrl: XRController3D, over_menu: bool) -> void:
	if ctrl == null:
		return
	var down := ctrl.is_button_pressed("trigger_click")
	var was: bool = _trigger_was_down.get(ctrl.tracker, false)
	_trigger_was_down[ctrl.tracker] = down
	if down and not was and over_menu:
		_menu_press_ctrl = ctrl
		_menu_press_ms = Time.get_ticks_msec()


## The "hand" that clicked the spawn button: the hand whose trigger press on
## the menu was recorded last (VR), or the DesktopPickup in desktop mode.
## Null when it can't be determined.
func _spawn_grabber() -> Node:
	if not get_viewport().use_xr:
		var pivot := get_tree().get_first_node_in_group("desktop_hand")
		if pivot:
			var ref: Variant = pivot.get("_owner_pickup")
			if ref is WeakRef:
				return (ref as WeakRef).get_ref()
		return null
	return _spawn_grabber_xr()


func _spawn_grabber_xr() -> Node:
	# The recorded press-on-menu is the click that fired this spawn (UI
	# buttons emit on release, so live trigger state can't be trusted here).
	if is_instance_valid(_menu_press_ctrl) \
			and Time.get_ticks_msec() - _menu_press_ms < 1500:
		return XRToolsFunctionPickup.find_instance(_menu_press_ctrl)
	# Fallbacks: a hand still holding its trigger, then whoever points at the
	# menu.
	for ctrl: XRController3D in [_left_ctrl, _right_ctrl]:
		if ctrl and ctrl.is_button_pressed("trigger_click"):
			return XRToolsFunctionPickup.find_instance(ctrl)
	for ptr: XRToolsFunctionPointer in [_right_pointer, _left_pointer]:
		if ptr and _pointer_over_menu(ptr):
			var ctrl := ptr.get_parent() as XRController3D
			if ctrl:
				return XRToolsFunctionPickup.find_instance(ctrl)
	return null


## True when that hand already holds something.
func _grabber_busy(grabber: Node) -> bool:
	if grabber is XRToolsFunctionPickup:
		return is_instance_valid((grabber as XRToolsFunctionPickup).picked_up_object)
	if grabber != null and grabber.has_method("is_holding"):
		return grabber.is_holding()
	return false


## Put a freshly spawned pickable into that hand.
func _give_to_grabber(grabber: Node, obj: XRToolsPickable) -> void:
	if grabber is XRToolsFunctionPickup:
		(grabber as XRToolsFunctionPickup)._pick_up_object(obj)
	elif grabber != null and grabber.has_method("grab_spawned"):
		grabber.grab_spawned(obj)


## Add obj to the scene, place it 0.5 m in front of the menu, then hand it to
## whichever hand clicked the spawn button. A full hand
## blocks the spawn ("Drop Item From Hand First" in the menu's status bar).
func _place_spawned(obj: Node3D, _type: String) -> void:
	var grabber := _spawn_grabber()
	if grabber != null and _grabber_busy(grabber):
		obj.queue_free()
		var menu := _get_menu()
		if menu:
			menu.show_notice("Drop Item From Hand First")
		return
	get_tree().current_scene.add_child(obj)
	obj.add_to_group("spawned")
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	obj.global_position = global_position + fwd * 0.5
	# In a multiplayer session the host registers + broadcasts; a client's
	# local copy is converted into a spawn request the host executes (the copy
	# is freed, so a client can't receive it in hand — it spawns placed).
	NetworkManager.on_local_spawn(obj)
	# Hand it over — except on a netplay client, whose local copy was just
	# queue_freed by on_local_spawn (the host mints the real one, placed).
	if grabber != null and not NetworkManager.is_client() \
			and is_instance_valid(obj) and obj is XRToolsPickable:
		_give_to_grabber(grabber, obj as XRToolsPickable)


func _on_spawn_requested(type: String) -> void:
	var obj: Node3D
	# Variant token "system:<systemid>:<variant>" (from SpawnCatalog) — checked
	# BEFORE the match below, since `match` only does literal string equality and
	# would never hit a "system" case against a string that starts with "system:".
	# It silently fell to the `_:` default, spawning the default model with the
	# whole token as a garbage systemid (e.g. "Mega Drive", "DS Lite" and
	# "Console (Original)" all landed on their default shell instead of the variant).
	if type.begins_with("system:"):
		var sys := SYSTEM_SCENE.instantiate() as RetroSystem
		var parts := type.split(":")
		sys.systemid = parts[1] if parts.size() > 1 else ""
		sys.model_variant = parts[2] if parts.size() > 2 else ""
		_place_spawned(sys, type)
		return
	match type:
		"tv":
			obj = TV_SCENE.instantiate() as Node3D
		"cartridge":
			obj = CART_SCENE.instantiate() as Node3D
		"trash_can":
			obj = TRASH_CAN_SCENE.instantiate() as Node3D
		"vcr_player":
			obj = VCR_SCENE.instantiate() as Node3D
		"dvd_player":
			obj = DVD_PLAYER_SCENE.instantiate() as Node3D
		"cd_player":
			obj = CD_PLAYER_SCENE.instantiate() as Node3D
		"cassette_player":
			obj = CASSETTE_PLAYER_SCENE.instantiate() as Node3D
		"tv_remote":
			obj = TV_REMOTE_SCENE.instantiate() as Node3D
		"memory_card":
			obj = MEMCARD_SCENE.instantiate() as Node3D
		"gamecube_memory_card":
			obj = GAMECUBE_MEMCARD_SCENE.instantiate() as Node3D
		"retro_controller":
			obj = RETRO_CONTROLLER_SCENE.instantiate() as Node3D
		# Every bespoke peripheral below is licence-pending: its GLB lives in
		# imported-assets/, which a store build excludes. _instantiate_peripheral
		# loads it at runtime when they were asked for, and hands back the procedural
		# RetroController otherwise, so the menu item always spawns SOMETHING.
		"dualshock":
			obj = _instantiate_peripheral("dualshock")
		"dualshock2":
			obj = _instantiate_peripheral("dualshock2")
		"gamecube_controller":
			obj = _instantiate_peripheral("gamecube_controller")
		"dreamcast_controller":
			obj = _instantiate_peripheral("dreamcast_controller")
		"nes_controller":
			obj = _instantiate_peripheral("nes_controller")
		"genesis_controller":
			obj = _instantiate_peripheral("genesis_controller")
		"megadrive_controller":
			obj = _instantiate_peripheral("megadrive_controller")
		"saturn_controller":
			obj = _instantiate_peripheral("saturn_controller")
		"snes_controller":
			obj = _instantiate_peripheral("snes_controller")
		"atari_joystick":
			obj = _instantiate_peripheral("atari_joystick")
		"vb_controller":
			obj = VB_CONTROLLER_SCENE.instantiate() as Node3D
		"n64_controller":
			obj = _instantiate_peripheral("n64_controller")
		"psx_controller":
			obj = _instantiate_peripheral("psx_controller")
		"retro_mouse":
			obj = RETRO_MOUSE_SCENE.instantiate() as Node3D
		"retro_keyboard":
			obj = RETRO_KEYBOARD_SCENE.instantiate() as Node3D
		"retro_multitap":
			obj = RETRO_MULTITAP_SCENE.instantiate() as Node3D
		"ray_gun":
			var gun := RAY_GUN_SCENE.instantiate() as RayGun
			gun.show_laser_dot = _aim_crosshair_enabled
			obj = gun
		_:
			# Any other type is treated as a bare systemid (default model).
			var sys := SYSTEM_SCENE.instantiate() as RetroSystem
			sys.systemid = type
			obj = sys
	if obj:
		_place_spawned(obj, type)


## Spawn a licence-pending peripheral, or the procedural RetroPad standing in for
## it. Preloading the bespoke scene would break any build that omits its GLB, so
## it is loaded at runtime.
##
## This used to return null and spawn NOTHING when the model was unavailable, so
## a store build answered "give me a DualShock" by silently doing nothing. The
## generic RetroController is the peripheral-side equivalent of the console grey
## box — a fully procedural pad, no imported geometry — so hand that back instead
## and the menu keeps working everywhere.
func _instantiate_peripheral(token: String) -> Node3D:
	var spec: Array = PERIPHERAL_MODELS.get(token, [])
	if spec.size() == 2:
		var glb_path: String = spec[0]
		var scene_path: String = spec[1]
		if RetroModelPolicy.may_use(glb_path) and ResourceLoader.exists(scene_path):
			var ps := load(scene_path) as PackedScene
			if ps != null:
				return ps.instantiate() as Node3D
			push_warning("[spawn] failed to load %s — using the generic pad" % scene_path)
	return RETRO_CONTROLLER_SCENE.instantiate() as Node3D


func _on_spawn_cartridge_requested(rom_path: String, game_label: String, systemid := "") -> void:
	# Disc-based systems get a RetroDisc (same contract, disc-shaped body).
	# The PSP UMD is the one non-round disc — its own RetroUMD subclass/scene.
	var is_disc := MediaDimensions.is_disc_system(systemid)
	var disc_scene := UMD_DISC_SCENE if systemid == "playstation_portable" else DISC_SCENE
	var cart := (disc_scene if is_disc else CART_SCENE).instantiate() as RetroCartridge
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


func _on_spawn_dvd_requested(dvd_path: String) -> void:
	var disc := DVD_DISC_SCENE.instantiate() as DVDDisc
	disc.dvd_path = dvd_path
	disc.dvd_label = dvd_path.get_file().get_basename()
	_place_spawned(disc, "dvd_disc")


func _on_spawn_cd_requested(album_path: String) -> void:
	var disc := AUDIO_DISC_SCENE.instantiate() as AudioDisc
	disc.album_path = album_path
	disc.album_label = album_path.get_file().get_basename()
	_place_spawned(disc, "audio_disc")


func _on_spawn_cassette_requested(album_path: String) -> void:
	var tape := AUDIO_CASSETTE_SCENE.instantiate() as AudioCassette
	tape.album_path = album_path
	tape.album_label = album_path.get_file().get_basename()
	_place_spawned(tape, "audio_cassette")


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


func _on_world_scale_changed(scale: float) -> void:
	_apply_world_scale(scale)


## Apply the world scale to both play modes. VR scales the tracked eye height +
## IPD natively via XRServer.world_scale (so the room towers over you). Desktop
## has a fixed camera that world_scale does NOT move, so scale its rest eye height
## directly — in VR the HMD overwrites the camera transform each frame, so setting
## it there is harmless.
func _apply_world_scale(scale: float) -> void:
	_world_scale = scale
	XRServer.world_scale = scale
	if _camera:
		_camera.transform.origin.y = _base_eye_height * scale


func _on_aim_crosshair_changed(enabled: bool) -> void:
	_aim_crosshair_enabled = enabled
	for node in get_tree().get_nodes_in_group("spawned"):
		var gun := node as RayGun
		if gun:
			gun.show_laser_dot = enabled


func _on_controller_hands_changed(enabled: bool) -> void:
	ControllerModel.draw_hands = enabled
	# Reflect the change on the rig controllers now: turning hands off brings the
	# controller art straight back; turning them on re-hides it (and shows the
	# device hand) the next time a peripheral is grabbed.
	for ctrl in get_tree().root.find_children("*", "XRController3D", true, false):
		if ctrl is ControllerModel:
			ctrl.set_model_visible(true)


func _on_controller_bindings_changed() -> void:
	for node in get_tree().get_nodes_in_group(ControllerBindings.CONSUMER_GROUP):
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
