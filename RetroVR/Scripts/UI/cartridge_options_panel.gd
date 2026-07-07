## CartridgeOptionsPanel — floating 3D panel for a cartridge's battery saves.
##
## Parented to a RetroCartridge but top_level so it inherits no transform;
## floats above the cartridge facing the camera. Mirrors BookOptionsPanel.
## Selecting a save re-binds the cartridge's save_id ("recovery"); a new
## blank id means a fresh save. .srm files are never deleted here.
class_name CartridgeOptionsPanel
extends Node3D

const FLOAT_HEIGHT := 0.25

var _cart: RetroCartridge = null
var _camera: Node3D = null
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $CartOptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _cart and is_instance_valid(_cart):
		global_position = _cart.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


func show_for(cart: RetroCartridge, camera: Node3D) -> void:
	_cart = cart
	_camera = camera
	if _cart:
		global_position = _cart.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


func hide_panel() -> void:
	visible = false


func _get_ui() -> CartridgeOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as CartridgeOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.save_selected.connect(_on_save_selected)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _cart:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	var core := SramPaths.core_for_systemid(_cart.systemid)
	var saves: Array = SramPaths.list_saves(core, _cart.rom_path) if not core.is_empty() else []
	ui.populate(_cart.game_label, saves, _cart.save_id, not core.is_empty())


func _on_save_selected(save_id: String) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	if save_id.is_empty():
		# New blank save: mint a fresh identity — the first flush creates it.
		_cart.save_id = "%08x%08x" % [randi(), randi()]
	else:
		_cart.save_id = save_id
	print("[CartridgeOptions] %s bound to save %s" % [_cart.game_label, _cart.save_id])
	_populate()
