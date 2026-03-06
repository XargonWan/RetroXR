## SpawnMenuController — manages the VR spawn panel.
## Attach as a Node3D in the scene (child of Root).
## Child "SpawnMenuViewport" must be an XRToolsViewport2DIn3D instance
## with "scene" set to spawn_menu.tscn.
##
## Toggle with the left controller's menu_button action.
extends Node3D

const NES_SCENE  := preload("res://Scenes/Objects/system_nes.tscn")
const TV_SCENE   := preload("res://Scenes/Objects/tv.tscn")
const CART_SCENE := preload("res://Scenes/Objects/cartridge.tscn")

# Y heights used when spawning each type onto the table
const SPAWN_Y := {
	"tv":         0.95,
	"nes":        0.80,
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

# Scroll state
var _right_trigger_held := false
var _smoothed_aim_y:    float = 0.0   # low-pass filtered aim direction
const _SCROLL_SPEED    := 700.0   # pixels per second at full tilt
const _SCROLL_DEADZONE := 25.0    # ignore controller tilts below this
const _SCROLL_MIN_PX   := 1.5     # discard sub-pixel nudges to prevent micro-jitter
const _SMOOTH_FACTOR   := 4.0     # lower = smoother / slower to respond


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
			_right_ctrl.button_pressed.connect(_on_right_button_pressed)
			_right_ctrl.button_released.connect(_on_right_button_released)
			break

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
	_menu_connected = true


# ── Button handler ────────────────────────────────────────────────────────────

func _on_controller_button(action_name: String) -> void:
	if disabled:
		return
	if action_name == "primary_click":
		_toggle_menu()


func _on_right_button_pressed(action_name: String) -> void:
	if action_name == "trigger_click" or action_name == "trigger":
		_right_trigger_held = true


func _on_right_button_released(action_name: String) -> void:
	if action_name == "trigger_click" or action_name == "trigger":
		_right_trigger_held = false
		_smoothed_aim_y = 0.0   # reset so scroll stops immediately on release


# ── Scroll driving ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _viewport_node.visible:
		return
	if not _right_ctrl:
		return
	# Accept either digital button state or analog trigger pull > 50 %
	var trigger_active := _right_trigger_held or _right_ctrl.get_float("trigger") > 0.5
	if not trigger_active:
		_smoothed_aim_y = 0.0
		return
	# Forward vector of the right controller (-Z in local space)
	var raw_aim_y: float = -_right_ctrl.global_transform.basis.z.y
	# Exponential low-pass: smooths out hand tremor
	_smoothed_aim_y = lerpf(_smoothed_aim_y, raw_aim_y, clampf(_SMOOTH_FACTOR * delta, 0.0, 1.0))
	if abs(_smoothed_aim_y) < _SCROLL_DEADZONE:
		return
	# Remap: outside deadzone, scale to [0..1]
	var t: float = (abs(_smoothed_aim_y) - _SCROLL_DEADZONE) / (1.0 - _SCROLL_DEADZONE)
	var pixels: float = -sign(_smoothed_aim_y) * t * _SCROLL_SPEED * delta
	if abs(pixels) < _SCROLL_MIN_PX:
		return
	var menu := _get_menu()
	if menu:
		menu.scroll_active(pixels)


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


# ── Spawning ──────────────────────────────────────────────────────────────────

func _on_spawn_requested(type: String) -> void:
	var scene: PackedScene
	match type:
		"tv":        scene = TV_SCENE
		"nes":       scene = NES_SCENE
		"cartridge": scene = CART_SCENE
		_: return

	var obj := scene.instantiate() as Node3D
	get_tree().current_scene.add_child(obj)

	# Place the new object 0.5 m in front of the menu at table height
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()

	obj.global_position = global_position + fwd * 0.5
	obj.global_position.y = SPAWN_Y.get(type, 0.85)
