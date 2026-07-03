## VCROptionsPanel — floating 3D panel that displays settings for a VCRPlayer.
##
## Parented to a VCRPlayer node but uses top_level=true so it inherits no transform.
## Each frame it repositions itself above the owning VCR and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕ close button.
## Mirrors CoreOptionsPanel.
class_name VCROptionsPanel
extends Node3D

## Height above the VCR's origin at which the panel floats.
const FLOAT_HEIGHT := 0.42

var _vcr: VCRPlayer = null
var _camera: Node3D = null
# Guard so we only wire the 2D UI signals once (the SubViewport persists).
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $VCROptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _vcr and is_instance_valid(_vcr):
		global_position = _vcr.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


# ── Public API ─────────────────────────────────────────────────────────────────

## Show the panel for the given VCR, looking toward the given camera.
func show_for(vcr: VCRPlayer, camera: Node3D) -> void:
	_vcr = vcr
	_camera = camera
	if _vcr:
		global_position = _vcr.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


## Hide the panel without destroying it.
func hide_panel() -> void:
	visible = false


# ── Internal helpers ───────────────────────────────────────────────────────────

func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		call_deferred("_ensure_ui_connected")
		return
	var ui := vp.get_child(0) as VCROptions2D
	if not ui:
		push_warning("[VCROptionsPanel] SubViewport child is not VCROptions2D")
		return
	ui.effect_toggled.connect(_on_effect_toggled)
	ui.scan_speed_changed.connect(_on_scan_speed_changed)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _vcr:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		call_deferred("_populate")
		return
	var ui := vp.get_child(0) as VCROptions2D
	if not ui:
		return
	ui.populate(_vcr.vcr_effect_enabled, _vcr.scan_speed)


func _on_effect_toggled(enabled: bool) -> void:
	if _vcr and is_instance_valid(_vcr):
		_vcr.set_vcr_effect_enabled(enabled)


func _on_scan_speed_changed(value: float) -> void:
	if _vcr and is_instance_valid(_vcr):
		_vcr.scan_speed = value
