## RayGun — pickable light-gun that plugs into a RetroSystem controller port.
## While held and plugged in: casts a ray from the barrel to the TV screen each
## frame and reports the hit position as libretro lightgun coordinates.
class_name RayGun
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/controller_cable.tscn")
const RETRO_DEVICE_LIGHTGUN := 7

## libretro.h RETRO_DEVICE_ID_LIGHTGUN_* values (IDs 0/1 are relative X/Y, not buttons).
const LIGHTGUN_TRIGGER    := 2   # RETRO_DEVICE_ID_LIGHTGUN_TRIGGER
const LIGHTGUN_AUX_A      := 3   # RETRO_DEVICE_ID_LIGHTGUN_AUX_A
const LIGHTGUN_AUX_B      := 4   # RETRO_DEVICE_ID_LIGHTGUN_AUX_B
const LIGHTGUN_START      := 6   # RETRO_DEVICE_ID_LIGHTGUN_START
const LIGHTGUN_SELECT     := 7   # RETRO_DEVICE_ID_LIGHTGUN_SELECT

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_LIGHTGUN

## Whether to show the laser-dot aim indicator on the screen.
var show_laser_dot: bool = true

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# Pending port restore (set before cable is ready)
var _pending_port_restore: Dictionary = {}

# Cached screen geometry (set on plug-in, cleared on unplug)
var _screen_mesh: MeshInstance3D = null
var _screen_w: float = 0.0
var _screen_h: float = 0.0

# Toggle-hold state
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null

var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _barrel_tip: Node3D = $BarrelTip
@onready var _laser_dot: MeshInstance3D = $LaserDot


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_laser_dot.visible = false
	_spawn_cable()
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)


# ── Toggle-hold ───────────────────────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		call_deferred("_rehold")
	else:
		_set_model_visible(_holding_ctrl, true)
		_allow_drop = false
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
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
	_allow_drop = true
	_holding_ctrl = null
	_laser_dot.visible = false
	_update_locomotion_block()
	drop()


func _update_locomotion_block() -> void:
	var left_held  := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand"
	var right_held := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand"
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, right_held)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if _cable_plug.is_picked_up() or _connected_system != null:
		return

	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()

	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward_vel := dir.dot(_cable_plug.linear_velocity)
		if outward_vel > 0.0:
			_cable_plug.linear_velocity -= dir * outward_vel


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_laser_dot.visible = true
	print("[RayGun] plugged into system port %d" % port_index)
	_cache_screen_geometry()


func on_unplugged() -> void:
	print("[RayGun] unplugged from port %d" % _port_index)
	_laser_dot.visible = false
	_connected_system = null
	_port_index = -1
	_screen_mesh = null
	_screen_w = 0.0
	_screen_h = 0.0


func _cache_screen_geometry() -> void:
	if _connected_system == null or _connected_system.connected_tv == null:
		return
	var mesh := _connected_system.connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var aabb := mesh.get_aabb()
	_screen_mesh = mesh
	_screen_w = aabb.size.x
	_screen_h = aabb.size.y


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── Input forwarding ──────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	# Drop combo.
	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	if _connected_system == null or _port_index < 0:
		return

	var libretro := _connected_system.get_libretro_node()

	if not is_instance_valid(_holding_ctrl):
		libretro.SetLightgunIsOffscreen(_port_index, true)
		libretro.SetLightgunButton(_port_index, LIGHTGUN_TRIGGER, false)
		libretro.SetLightgunButton(_port_index, LIGHTGUN_START,   false)
		libretro.SetLightgunButton(_port_index, LIGHTGUN_AUX_A,   false)
		libretro.SetLightgunButton(_port_index, LIGHTGUN_AUX_B,   false)
		_laser_dot.visible = false
		return

	var ctrl := _holding_ctrl

	libretro.SetLightgunButton(_port_index, LIGHTGUN_TRIGGER, ctrl.get_float("trigger")       > 0.3)
	libretro.SetLightgunButton(_port_index, LIGHTGUN_START,   ctrl.get_float("primary_click") > 0.5)
	libretro.SetLightgunButton(_port_index, LIGHTGUN_AUX_A,   ctrl.get_float("ax_button")     > 0.5)
	libretro.SetLightgunButton(_port_index, LIGHTGUN_AUX_B,   ctrl.get_float("by_button")     > 0.5)

	_update_aim(libretro)


func _update_aim(libretro: Libretro) -> void:
	if _screen_mesh == null or _screen_w == 0.0:
		libretro.SetLightgunIsOffscreen(_port_index, true)
		_laser_dot.visible = false
		return

	var screen_transform := _screen_mesh.global_transform
	var screen_normal := screen_transform.basis.z
	var plane := Plane(screen_normal, screen_transform.origin)
	var ray_origin := _barrel_tip.global_position
	var ray_dir := -_barrel_tip.global_transform.basis.z

	var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)

	if hit == null:
		libretro.SetLightgunIsOffscreen(_port_index, true)
		_laser_dot.visible = false
		return

	var local: Vector3 = screen_transform.affine_inverse() * (hit as Vector3)

	var u := (local.x / _screen_w) + 0.5
	var v := (-local.y / _screen_h) + 0.5

	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		libretro.SetLightgunIsOffscreen(_port_index, true)
		_laser_dot.visible = false
		return

	var lx := int((u * 2.0 - 1.0) * 32767)
	var ly := int((v * 2.0 - 1.0) * 32767)
	libretro.SetLightgunPosition(_port_index, lx, ly)
	libretro.SetLightgunIsOffscreen(_port_index, false)

	_laser_dot.visible = show_laser_dot
	_laser_dot.global_position = hit + screen_normal * 0.002
