## TVRemote — pickable remote control. While held, it raycasts forward from its
## tip; when pointed at a RetroTV or VCRPlayer the target is outlined maroon
## (PickableHighlight.set_remote_target) and a small menu pops up above the
## remote, billboarded to the camera:
##   TV  → POWER / VOL + / VOL −
##   VCR → PLAY / PAUSE / STOP / FF / REW
## VR: thumbstick up/down moves the selection (one flick = one step), primary
## button (A/X) or thumbstick click activates. Desktop: aim follows the camera
## reticle, Arrow Up/Down move the selection, Enter activates.
class_name TVRemote
extends XRToolsPickable


const RAY_LENGTH := 8.0
## Seconds the ray may leave the target before the menu hides (hand jitter).
const TARGET_GRACE := 0.4

# Menu geometry (metres)
const MENU_WIDTH   := 0.17
const ROW_HEIGHT   := 0.03
const MENU_MARGIN  := 0.01
const FLOAT_HEIGHT := 0.16
## Desktop: camera-local menu anchor (right, up, forward) — just above the
## FPS-snapped remote (desktop_pickup.FPS_SNAP_LOCAL is 0.20, -0.22, -0.45),
## fixed in screen space so looking around doesn't move it.
const DESKTOP_MENU_OFFSET := Vector3(0.22, -0.03, -0.55)

# Thumbstick step/latch thresholds
const STICK_STEP  := 0.6
const STICK_REARM := 0.3

const COLOR_ROW_SELECTED := Color(1.0, 1.0, 1.0, 1.0)
const COLOR_ROW_NORMAL   := Color(0.65, 0.65, 0.72, 1.0)
const COLOR_MAROON       := Color(0.5, 0.0, 0.13, 0.9)

const VCR_ROWS: Array[String] = ["PLAY", "PAUSE", "STOP", "FF  »»", "REW  ««"]

## Desktop mode: lock to the camera lower-right pointing straight ahead
## (FPS-style, same as the RayGun — read by desktop_pickup.gd). Drop with
## Ctrl+click while snapped.
var desktop_fps_snap: bool = true

# Toggle-hold state (mirrors RayGun)
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null
var _desktop_held: bool = false

# Reference-counted pointer blocking — prevents multi-instance conflicts.
var _blocking_left: bool = false
var _blocking_right: bool = false

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

# Current aim target (RetroTV or VCRPlayer) and lost-ray grace timer.
var _target: Node3D = null
var _lost_time: float = 0.0

# Menu state
var _selection: int = 0
var _stick_latched := false
var _prev_confirm := false

# Menu nodes (built in code)
var _menu: Node3D = null
var _menu_bg: MeshInstance3D = null
var _menu_bar: MeshInstance3D = null
var _menu_labels: Array[Label3D] = []

@onready var _tip: Marker3D = $Tip
@onready var _pointer_area: StaticBody3D = $PointerArea


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_build_menu()
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			_left_vr_ctrl = ctrl
		elif ctrl.tracker == &"right_hand":
			_right_vr_ctrl = ctrl


# ── Toggle-hold (mirrors RayGun) ──────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		call_deferred("_rehold")
	else:
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		_desktop_held = false
		_clear_target()
		_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


func _set_model_visible(ctrl: XRController3D, show: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", show)


func _is_combo_pressed(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) \
		and ctrl.get_float("grip") > 0.5 \
		and ctrl.get_float("trigger") > 0.5 \
		and ctrl.get_float("primary_click") > 0.5


func _drop_all() -> void:
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_clear_target()
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	_clear_target()
	if _blocking_left and is_instance_valid(_left_vr_ctrl):
		_update_pointer_block(_left_vr_ctrl, false)
	if _blocking_right and is_instance_valid(_right_vr_ctrl):
		_update_pointer_block(_right_vr_ctrl, false)
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT, false)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, false)
	_allow_drop = true
	super._exit_tree()


func _update_locomotion_block() -> void:
	var left_held  := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand"
	var right_held := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand"
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, right_held)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


## Reference-counted pointer blocking (same mechanism as RetroController).
func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var is_left := ctrl.tracker == &"left_hand"
	var currently_blocking: bool = _blocking_left if is_left else _blocking_right
	if should_block == currently_blocking:
		return
	if is_left:
		_blocking_left = should_block
	else:
		_blocking_right = should_block
	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if not pointer:
		return
	var delta_count := 1 if should_block else -1
	var count: int = maxi(0, pointer.get_meta("block_count", 0) + delta_count)
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray:
		ray.enabled = count == 0


# ── Aiming / target management ────────────────────────────────────────────────

func _process(delta: float) -> void:
	# VR drop combo (desktop drop is handled by desktop_pickup via left click)
	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	var held := is_instance_valid(_holding_ctrl) or _desktop_held
	if not held:
		if _target != null:
			_clear_target()
		return

	_update_target(delta)
	_update_menu_transform()

	if _target != null and is_instance_valid(_holding_ctrl):
		_process_vr_selection()


func _update_target(delta: float) -> void:
	var host := _scan_for_target()
	if host == _target and host != null:
		_lost_time = 0.0
		return
	if host != null:
		# New target — switch highlight and rebuild the menu.
		_set_target_highlight(_target, false)
		_target = host
		_lost_time = 0.0
		_selection = 0
		_set_target_highlight(_target, true)
		_rebuild_menu_rows()
		_menu.visible = true
		return
	# Ray off-target: keep the menu through brief hand jitter.
	if _target != null:
		if not is_instance_valid(_target):
			_clear_target()
			return
		_lost_time += delta
		if _lost_time > TARGET_GRACE:
			_clear_target()


## Raycast from the tip (VR) or camera centre (desktop) on the pointable layer,
## then walk ancestors to the owning RetroTV / VCRPlayer.
func _scan_for_target() -> Node3D:
	var from: Vector3
	var dir: Vector3
	if _desktop_held:
		var cam := get_viewport().get_camera_3d()
		if not is_instance_valid(cam):
			return null
		from = cam.global_position
		dir = -cam.global_transform.basis.z
	else:
		from = _tip.global_position
		dir = -_tip.global_transform.basis.z

	var q := PhysicsRayQueryParameters3D.create(from, from + dir * RAY_LENGTH)
	q.collision_mask = 1 << 20   # 21: pointable (PointerArea bodies)
	q.exclude = [_pointer_area.get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null

	var n := hit["collider"] as Node
	while n:
		if n is RetroTV or n is VCRPlayer:
			return n as Node3D
		n = n.get_parent()
	return null


func _clear_target() -> void:
	_set_target_highlight(_target, false)
	_target = null
	_lost_time = 0.0
	if _menu:
		_menu.visible = false


func _set_target_highlight(target: Node3D, active: bool) -> void:
	if not is_instance_valid(target):
		return
	var hl := target.find_child("PickableHighlight", false, false)
	if hl and hl.has_method("set_remote_target"):
		hl.call("set_remote_target", active)


# ── Selection input ───────────────────────────────────────────────────────────

func _process_vr_selection() -> void:
	var ctrl := _holding_ctrl
	var y := ctrl.get_vector2("primary").y

	if _stick_latched:
		if absf(y) < STICK_REARM:
			_stick_latched = false
	elif y > STICK_STEP:
		_move_selection(-1)
		_stick_latched = true
	elif y < -STICK_STEP:
		_move_selection(1)
		_stick_latched = true

	var confirm := ctrl.get_float("ax_button") > 0.5 or ctrl.get_float("primary_click") > 0.5
	if confirm and not _prev_confirm:
		_activate_selection()
	_prev_confirm = confirm


## Desktop: Arrow Up/Down move the selection, Enter activates (left-click is
## already taken by desktop_pickup's drop).
func _unhandled_input(event: InputEvent) -> void:
	if not _desktop_held or _target == null:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.physical_keycode:
		KEY_UP:
			_move_selection(-1)
			get_viewport().set_input_as_handled()
		KEY_DOWN:
			_move_selection(1)
			get_viewport().set_input_as_handled()
		KEY_ENTER, KEY_KP_ENTER:
			_activate_selection()
			get_viewport().set_input_as_handled()


func _move_selection(step: int) -> void:
	var count := _menu_labels.size()
	if count == 0:
		return
	_selection = clampi(_selection + step, 0, count - 1)
	_refresh_menu_labels()


func _activate_selection() -> void:
	if not is_instance_valid(_target):
		return
	if _target is RetroTV:
		var tv := _target as RetroTV
		match _selection:
			0: tv.remote_power_toggle()
			1: tv.remote_volume_up()
			2: tv.remote_volume_down()
	elif _target is VCRPlayer:
		var vcr := _target as VCRPlayer
		match _selection:
			0: vcr.remote_play()
			1: vcr.remote_pause()
			2: vcr.remote_stop()
			3: vcr.remote_ff()
			4: vcr.remote_rewind()
	# POWER [ON]/[OFF] state may have changed.
	_refresh_menu_labels()


# ── Menu widget ───────────────────────────────────────────────────────────────

func _build_menu() -> void:
	_menu = Node3D.new()
	_menu.top_level = true
	_menu.visible = false
	add_child(_menu)

	var bg_mat := StandardMaterial3D.new()
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.albedo_color = Color(0.05, 0.05, 0.1, 0.85)
	bg_mat.no_depth_test = true
	bg_mat.render_priority = 10
	_menu_bg = MeshInstance3D.new()
	_menu_bg.mesh = QuadMesh.new()
	_menu_bg.material_override = bg_mat
	_menu_bg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Keep the menu out of PickableHighlight's outline overlays: a highlighted
	# quad this size draws a huge hull AND its stencil mask pass suppresses
	# other objects' outlines (e.g. the target TV's maroon) behind it.
	_menu_bg.add_to_group("outline_exclude")
	_menu.add_child(_menu_bg)

	var bar_mat := StandardMaterial3D.new()
	bar_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bar_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bar_mat.albedo_color = COLOR_MAROON
	bar_mat.no_depth_test = true
	bar_mat.render_priority = 11
	var bar_mesh := QuadMesh.new()
	bar_mesh.size = Vector2(MENU_WIDTH - 0.006, ROW_HEIGHT)
	_menu_bar = MeshInstance3D.new()
	_menu_bar.mesh = bar_mesh
	_menu_bar.material_override = bar_mat
	_menu_bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_menu_bar.add_to_group("outline_exclude")
	_menu.add_child(_menu_bar)


func _row_texts() -> Array[String]:
	if _target is RetroTV:
		var on: bool = (_target as RetroTV).is_powered_on()
		var rows: Array[String] = ["POWER   [%s]" % ("ON" if on else "OFF"), "VOL +", "VOL −"]
		return rows
	if _target is VCRPlayer:
		return VCR_ROWS.duplicate()
	var empty: Array[String] = []
	return empty


func _rebuild_menu_rows() -> void:
	for lbl in _menu_labels:
		if is_instance_valid(lbl):
			lbl.queue_free()
	_menu_labels.clear()

	var rows := _row_texts()
	var count := rows.size()
	var height := count * ROW_HEIGHT + MENU_MARGIN * 2.0

	(_menu_bg.mesh as QuadMesh).size = Vector2(MENU_WIDTH, height)

	for i in count:
		var lbl := Label3D.new()
		lbl.pixel_size = 0.0006
		lbl.font_size = 30
		lbl.outline_size = 8
		lbl.no_depth_test = true
		lbl.render_priority = 12
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		lbl.position = Vector3(-MENU_WIDTH * 0.5 + MENU_MARGIN, _row_y(i, count), 0.002)
		_menu.add_child(lbl)
		_menu_labels.append(lbl)

	_refresh_menu_labels()


## Local Y of row i's centre (row 0 on top).
func _row_y(i: int, count: int) -> float:
	var top := count * ROW_HEIGHT * 0.5
	return top - (float(i) + 0.5) * ROW_HEIGHT


func _refresh_menu_labels() -> void:
	var rows := _row_texts()
	var count := mini(rows.size(), _menu_labels.size())
	for i in count:
		var lbl := _menu_labels[i]
		if not is_instance_valid(lbl):
			continue
		if i == _selection:
			lbl.text = "▶ " + rows[i]
			lbl.modulate = COLOR_ROW_SELECTED
		else:
			lbl.text = "   " + rows[i]
			lbl.modulate = COLOR_ROW_NORMAL
	if count > 0:
		_menu_bar.position = Vector3(0.0, _row_y(_selection, count), 0.001)
		_menu_bar.visible = true
	else:
		_menu_bar.visible = false


## Position the menu. VR: float above the remote and billboard to the camera
## (VCROptionsPanel pattern). Desktop: fixed camera-local anchor — the remote
## itself is FPS-snapped to the camera, so anchoring to the remote would make
## the menu wander as the player looks up/down.
func _update_menu_transform() -> void:
	if _menu == null or not _menu.visible:
		return
	var cam := get_viewport().get_camera_3d()

	if _desktop_held:
		if is_instance_valid(cam):
			_menu.global_transform = Transform3D(
				cam.global_transform.basis,
				cam.global_transform * DESKTOP_MENU_OFFSET)
		return

	_menu.global_position = global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if is_instance_valid(cam):
		var to_cam := cam.global_position - _menu.global_position
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.0001:
			_menu.look_at(cam.global_position, Vector3.UP)
			_menu.rotate_object_local(Vector3.UP, PI)
