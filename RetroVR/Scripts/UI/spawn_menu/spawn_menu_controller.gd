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

## The "press this for the menu" popup. Lives on the player — by the left hand
## in VR, in the corner of the view on desktop — not on any spawned object.
## One instance, so its use count accumulates instead of resetting per spawn.
var _menu_hint: HeldHint = null
## Seconds after setup before it opens, so it lands on a settled room and a
## tracked hand rather than during the fade-in.
const STARTUP_HINT_DELAY := 2.0

var _locomotion_manager: LocomotionManager = null
var _move_turn: Node = null
var _player_body: XRToolsPlayerBody = null
var _fps_label: Label3D = null
var _vram_label: Label3D = null

# World scale (below 1.0 = player feels smaller / room feels bigger). Applied at
# startup and tunable from the menu's Controls section. Not persisted — resets to
# the default each launch (like the other comfort settings).
const DEFAULT_WORLD_SCALE := 0.8
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
	var sm := get_node_or_null("/root/SceneManager")
	if sm != null:
		sm.scene_ready.connect(_on_scene_ready)
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

	# The bootstrap hint. Every other hint can wait to be provoked by something
	# the player did, but this one cannot: opening the menu is how you spawn
	# anything at all, so teaching it on a spawn is teaching it to somebody who
	# has already worked it out. A beat first, so it does not open underneath
	# the room's own fade-in — and, in VR, so the hand it pins to is being
	# tracked rather than parked at the rig origin.
	await get_tree().create_timer(STARTUP_HINT_DELAY).timeout
	_show_menu_hint()


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

	# Persisted OPTIONS switches that need the rig or the scene tree, so they
	# can't be applied in AppPrefs._ready() the way the static-backed ones are.
	_on_auto_save_changed(AppPrefs.auto_save_scene)
	_on_show_fps_changed(AppPrefs.show_fps)
	_on_aim_crosshair_changed(AppPrefs.aim_crosshair)

	# Auto-load last active slot on startup (arcade only)
	_autoload_slot()


## The rig is carried from room to room, so _deferred_setup and
## _connect_menu_signals never run a second time — everything here that depends
## on WHICH room we are in has to be re-applied when a new one is ready.
func _on_scene_ready(_scene_id: String) -> void:
	_apply_world_scale(_world_scale)
	_autoload_slot()


func _autoload_slot() -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if sm and sm.current_scene_id == "arcade" and sm.active_slot_id != "clean":
		await ScenePersistence.new().load_slot_async(get_tree().current_scene, sm.active_slot_id)


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
				HeldHint.note_on(host, &"options_point")
				host.toggle_options_ui(_camera)
				get_viewport().set_input_as_handled()
				return
		if not disabled:
			_note_menu_verb_used()
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
			HeldHint.note_on(host, &"options_point")
			host.toggle_options_ui(_camera)
			return
		if not disabled:
			_note_menu_verb_used()
			_toggle_menu()


## Count one use of the menu verb, so its row eventually retires.
func _note_menu_verb_used() -> void:
	if _menu_hint != null and is_instance_valid(_menu_hint):
		_menu_hint.note_used(&"menu_open")


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
	CurvedPanel.set_screen_size(_viewport_node, Vector2(new_w, new_h))


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

	if is_instance_valid(obj):
		_teach_verbs(obj)


## Both verbs on the left thumbstick (Tab on desktop), taught on the object the
## player just made: how to get the menu back, and — for anything with an
## options panel — that pointing at it opens that panel.
##
## Declared here rather than in each object's own script because it is one
## funnel and they are the same two rows every time. HeldHint counts uses and
## stops showing a row once it is learned, so this is not a permanent tax on
## every spawn.
func _teach_verbs(obj: Node3D) -> void:
	var has_options: bool = obj.has_method("toggle_options_ui")
	if not has_options:
		return
	var hint := HeldHint.for_node(obj)
	if hint == null:
		return
	hint.add_row(&"options_point", HeldHint.PLATFORM_BOTH,
		["quest_stick_l_press"] if _is_vr_runtime() else ["keyboard_tab_outline"],
		"Point and press {g} for options", HeldHint.WHEN_PLACED, true)

	# Over the object itself, clear of its own geometry — a TV or a console is
	# far taller than the hand-sized default offset, and the popup would open
	# inside it.
	hint.fit_above()

	# In hand: its own hint shows on the grab, and these rows ride along. Left
	# standing: show now, and again each time it is put down, which is when
	# "point at it" first means anything.
	if obj is XRToolsPickable:
		var pickable := obj as XRToolsPickable
		if not pickable.dropped.is_connected(_on_taught_object_dropped):
			pickable.dropped.connect(_on_taught_object_dropped)
		if not pickable.is_picked_up():
			hint.show_unheld()
	else:
		hint.show_unheld()


## Where the menu is, taught on the player rather than on the thing they just
## made — it is not that object's verb, and following the object put it on a
## console across the room. Pinned by the left hand in VR, which is the hand the
## button is on, and parked in the lower right of the view on desktop.
##
## One instance, reused: the row retires after HeldHint.LEARNED_AFTER uses, and
## a fresh popup per spawn would never accumulate the count.
func _show_menu_hint() -> void:
	var vr := _is_vr_runtime()
	var host: Node3D = _left_ctrl if vr else _camera
	if not is_instance_valid(host):
		return
	if _menu_hint == null or not is_instance_valid(_menu_hint):
		_menu_hint = HeldHint.for_node(host)
		if _menu_hint == null:
			return
		_menu_hint.add_row(&"menu_open", HeldHint.PLATFORM_BOTH,
			["quest_stick_l_press"] if vr else ["keyboard_tab_outline"], "Menu",
			HeldHint.WHEN_PLACED)
		# Just above and ahead of the hand. On desktop, the lower-right corner of
		# the view: measured at 78% across and 80% down at the default 75 deg
		# FOV, where the first guess sat at 63/65 — in view, but the middle of
		# the screen rather than out of the way.
		_menu_hint.pin_to_host(
			Vector3(0.0, 0.10, -0.06) if vr else Vector3(0.72, -0.44, -0.95))
	_menu_hint.show_unheld()


## Re-measure on every drop, not just at spawn: a console's lid can be open, a
## cartridge can be seated in a slot, and the silhouette that the popup has to
## clear is whatever it is now.
func _on_taught_object_dropped(pickable: Variant) -> void:
	var node := pickable as Node3D
	if not is_instance_valid(node):
		return
	var hint := node.get_node_or_null("HeldHint") as HeldHint
	if hint == null:
		return
	hint.fit_above()
	hint.show_unheld.call_deferred()


func _is_vr_runtime() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


func _on_spawn_requested(type: String) -> void:
	var obj: Node3D
	# Model token "model:<systemid>:<model_id>" (from SpawnCatalog) — checked BEFORE
	# the match below, since `match` only does literal string equality and would
	# never hit a case against a string that merely starts with "model:". The
	# predecessor of this branch silently fell to the `_:` default, spawning the
	# default model with the whole token as a garbage systemid (e.g. "Mega Drive",
	# "DS Lite" and "Console (Original)" all landed on their default shell).
	if type.begins_with("model:"):
		var sys := SYSTEM_SCENE.instantiate() as RetroSystem
		var parts := type.split(":")
		var model_id: String = parts[2] if parts.size() > 2 else ""
		# The row is the authority on which platform it belongs to, so the model and
		# the core cannot disagree. Only the placeholder — which belongs to no
		# platform — falls back to the systemid carried in the token.
		var platform := SystemModelRegistry.platform_of(model_id)
		sys.systemid = platform if not platform.is_empty() else (parts[1] if parts.size() > 1 else "")
		sys.model_id = model_id
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
		"dualshock":
			# GLB lives in export-excluded imported-assets/ while its licence is
			# pending, so load at runtime and skip gracefully if absent (e.g. Quest).
			obj = _instantiate_optional("res://imported-assets/dualshock.glb", "res://Scenes/Objects/controllers/dualshock.tscn")
			if obj == null:
				return
		"dualshock2":
			obj = _instantiate_optional("res://imported-assets/dualshock2.glb", "res://Scenes/Objects/controllers/dualshock2.tscn")
			if obj == null:
				return
		"gamecube_controller":
			obj = _instantiate_optional("res://imported-assets/gamecube_controller.glb", "res://Scenes/Objects/controllers/gamecube_controller.tscn")
			if obj == null:
				return
		"dreamcast_controller":
			obj = _instantiate_optional("res://imported-assets/dreamcast_controller.glb", "res://Scenes/Objects/controllers/dreamcast_controller.tscn")
			if obj == null:
				return
		"nes_controller":
			obj = _instantiate_optional("res://imported-assets/nes_controller.glb", "res://Scenes/Objects/controllers/nes_controller.tscn")
			if obj == null:
				return
		"genesis_controller":
			obj = _instantiate_optional("res://imported-assets/genesis_controller.glb", "res://Scenes/Objects/controllers/genesis_controller.tscn")
			if obj == null:
				return
		"megadrive_controller":
			obj = _instantiate_optional("res://imported-assets/megadrive_controller.glb", "res://Scenes/Objects/controllers/megadrive_controller.tscn")
			if obj == null:
				return
		"saturn_controller":
			obj = _instantiate_optional("res://imported-assets/saturn_controller.glb", "res://Scenes/Objects/controllers/saturn_controller.tscn")
			if obj == null:
				return
		"snes_controller":
			obj = _instantiate_optional("res://imported-assets/snes_controller.glb", "res://Scenes/Objects/controllers/snes_controller.tscn")
			if obj == null:
				return
		"atari_joystick":
			obj = _instantiate_optional("res://imported-assets/atari_joystick.glb", "res://Scenes/Objects/controllers/atari_joystick.tscn")
			if obj == null:
				return
		"vb_controller":
			obj = VB_CONTROLLER_SCENE.instantiate() as Node3D
		"n64_controller":
			obj = _instantiate_optional("res://imported-assets/n64_controller.glb", "res://Scenes/Objects/controllers/n64_controller.tscn")
			if obj == null:
				return
		"psx_controller":
			obj = _instantiate_optional("res://imported-assets/psx_controller.glb", "res://Scenes/Objects/controllers/psx_controller.tscn")
			if obj == null:
				return
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


## Runtime-load a licence-pending prop whose GLB lives in the export-excluded
## imported-assets/ dir. Preloading would break any build that omits it, so we
## load at runtime and return null gracefully when the asset isn't present.
func _instantiate_optional(glb_path: String, scene_path: String) -> Node3D:
	if not ResourceLoader.exists(glb_path) or not ResourceLoader.exists(scene_path):
		push_warning("[spawn] asset not available in this build; skipping: " + scene_path)
		return null
	var ps := load(scene_path) as PackedScene
	return ps.instantiate() as Node3D if ps else null


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
##
## Passthrough is the exception and is pinned to 1.0. world_scale multiplies the
## tracked head position, so at 0.8 one real metre of walking advances the virtual
## viewpoint only 0.8 m while the real room slides past at a full metre. The two
## disagree by 20% of every step, which reads as the objects on the floor
## drifting along with you. Registration with a room you can see is only possible
## at 1:1.
func _apply_world_scale(scale: float) -> void:
	_world_scale = scale
	XRServer.world_scale = 1.0 if _in_passthrough() else scale
	if _camera:
		_camera.transform.origin.y = _base_eye_height * XRServer.world_scale


## The scene id is claimed before the transition starts, so this is already true
## by the time the rig's deferred setup runs — unlike the interface's blend mode,
## which PassthroughInit only sets afterwards.
func _in_passthrough() -> bool:
	var sm := get_node_or_null("/root/SceneManager")
	return sm != null and sm.current_scene_id == "passthrough"


func _on_aim_crosshair_changed(enabled: bool) -> void:
	_aim_crosshair_enabled = enabled
	for node in get_tree().get_nodes_in_group("spawned"):
		var gun := node as RayGun
		if gun:
			gun.show_laser_dot = enabled


func _on_controller_hands_changed(enabled: bool) -> void:
	ControllerModel.draw_hands = enabled
	# Only the device hand follows this switch — the controller art fades on any
	# grab either way, so forcing it visible here would pop it back mid-hold.
	for ctrl in get_tree().root.find_children("*", "XRController3D", true, false):
		if ctrl is ControllerModel:
			ctrl.refresh_device_hand()


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
	await persistence.load_slot_async(get_tree().current_scene, slot_id)
	var sm := get_node_or_null("/root/SceneManager")
	if sm:
		sm.set_active_slot(slot_id)
	var menu := _get_menu()
	if menu:
		menu.rebuild_states_grid()


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
		menu.rebuild_states_grid()


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
		menu.rebuild_states_grid()


func _on_slot_rename(slot_id: String, new_name: String) -> void:
	ScenePersistence.new().rename_slot(slot_id, new_name)
	var menu := _get_menu()
	if menu:
		menu.rebuild_states_grid()


func _on_auto_save_changed(enabled: bool) -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if sm:
		sm.auto_save_on_switch = enabled
