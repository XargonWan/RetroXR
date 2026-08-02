## DVDOptionsPanel — floating 3D panel that displays settings for a DVDPlayer.
##
## Parented to a DVDPlayer node but uses top_level=true so it inherits no transform.
## Each frame it repositions itself above the owning player and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕ close button.
## Mirrors VCROptionsPanel.
class_name DVDOptionsPanel
extends Node3D

## Height above the DVD player's origin at which the panel floats.
const FLOAT_HEIGHT := 0.42

var _dvd: DVDPlayer = null
var _camera: Node3D = null
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $DVDOptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _dvd and is_instance_valid(_dvd):
		global_position = _dvd.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


# ── Public API ─────────────────────────────────────────────────────────────────

func show_for(dvd: DVDPlayer, camera: Node3D) -> void:
	_dvd = dvd
	_camera = camera
	if _dvd:
		global_position = _dvd.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


func hide_panel() -> void:
	visible = false


# ── Internal ───────────────────────────────────────────────────────────────────

func _get_ui() -> DVDOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as DVDOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.audio_track_selected.connect(_on_audio_selected)
	ui.subtitle_selected.connect(_on_subtitle_selected)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _dvd:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	ui.populate(_dvd.get_audio_tracks(), _dvd.get_audio_track(),
		_dvd.get_subtitle_tracks(), _dvd.get_subtitle())


func _on_audio_selected(id: int) -> void:
	if _dvd and is_instance_valid(_dvd):
		_dvd.set_audio_track(id)


func _on_subtitle_selected(id: int) -> void:
	if _dvd and is_instance_valid(_dvd):
		_dvd.set_subtitle(id)
