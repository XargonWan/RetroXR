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
var _menu_connected := false


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
