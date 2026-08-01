## CoreOptionsPanel — floating 3D panel that displays libretro core options for a RetroSystem.
##
## Parented to a RetroSystem node but uses top_level=true so it inherits no transform.
## Each frame it repositions itself above the owning system and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕ close button.
class_name CoreOptionsPanel
extends Node3D

## Height above the system's origin at which the panel floats.
const FLOAT_HEIGHT := 0.42

## Built on first open, not with the panel. A SubViewport and the whole control
## tree inside it is the most expensive part of a system, and a room pays it once
## per system while it is being built — main-thread time spent on a UI nobody has
## asked for yet, at the one moment the headset has nothing new to draw.
const UI_SCENE := preload("res://Scenes/UI/core_options_2d.tscn")

var _system: RetroSystem = null
var _camera: Node3D = null
# Guard so we only wire the 2D UI signals once (the SubViewport persists).
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $CoreOptionsViewport


func _ready() -> void:
	# top_level = true: this node is in the system's scene tree but ignores
	# the parent's transform, letting us position it freely in world space.
	top_level = true
	visible = false
	print("[CoreOptionsPanel] ready — attached to ", get_parent().name)


func _process(_delta: float) -> void:
	if not visible:
		return
	# Keep panel hovering above the system even when the system moves or is picked up
	if _system and is_instance_valid(_system):
		global_position = _system.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	# Face the camera: look_at points -Z toward target, then flip 180° so the
	# UV/front face (+Z) faces the player — same trick used by spawn_menu_controller.
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


# ── Public API ─────────────────────────────────────────────────────────────────

## Show the panel for the given system, looking toward the given camera.
func show_for(system: RetroSystem, camera: Node3D) -> void:
	_system = system
	_camera = camera
	# Pre-position before making visible to avoid a one-frame flash at the wrong spot
	if _system:
		global_position = _system.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	print("[CoreOptionsPanel] showing for system '%s'" % system.name)
	if _viewport_node.scene == null:
		_viewport_node.scene = UI_SCENE
	_ensure_ui_connected()
	_populate()


## Hide the panel without destroying it.
func hide_panel() -> void:
	visible = false
	print("[CoreOptionsPanel] hidden")


## Called by the system when fresh options data arrives and the panel is already open.
func refresh() -> void:
	print("[CoreOptionsPanel] refreshing options display")
	_populate()


# ── Internal helpers ───────────────────────────────────────────────────────────

## Wire signals from the 2D UI scene exactly once.
## The SubViewport may not have finished loading on the first call, so we defer
## and retry if the child scene isn't ready yet.
func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		# SubViewport hasn't instantiated its scene yet — retry next frame
		call_deferred("_ensure_ui_connected")
		return
	var ui := vp.get_child(0) as CoreOptions2D
	if not ui:
		push_warning("[CoreOptionsPanel] SubViewport child is not CoreOptions2D")
		return
	ui.option_changed.connect(_on_option_changed)
	ui.port_device_changed.connect(_on_port_device_changed)
	ui.video_out_toggled.connect(_on_video_out_toggled)
	ui.ignore_gravity_toggled.connect(_on_ignore_gravity_toggled)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true
	print("[CoreOptionsPanel] 2D UI signals connected")


## Push the system's cached option data into the 2D UI.
## Defers if the SubViewport scene isn't ready yet.
func _populate() -> void:
	if not _system:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		call_deferred("_populate")
		return
	var ui := vp.get_child(0) as CoreOptions2D
	if not ui:
		return
	ui.populate(_system._options_definitions, _system._options_values, _system._controller_info)
	ui.populate_system(_system.video_out_enabled, _system.supports_video_out_toggle(),
		_system.ignore_gravity)


## Relay the user's option change from the 2D UI back to the system.
func _on_option_changed(key: String, value: String) -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] option changed: '%s' = '%s'" % [key, value])
		_system.set_core_option(key, value)


## System-tab toggle: show/hide the console's video-out cables.
func _on_video_out_toggled(enabled: bool) -> void:
	if _system and is_instance_valid(_system):
		_system.set_video_out_enabled(enabled)


## System-tab toggle: float in place where dropped.
func _on_ignore_gravity_toggled(enabled: bool) -> void:
	if _system and is_instance_valid(_system):
		_system.set_ignore_gravity(enabled)


func _on_port_device_changed(port: int, device_id: int) -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] port %d device → %d" % [port, device_id])
		_system.set_controller_port_device(port, device_id)
