## PosterOptionsPanel — floating 3D panel with a Poster's fit mode, size and peel.
##
## Parented to a Poster but top_level, so it inherits no transform. Mirrors
## MouseOptionsPanel / BookOptionsPanel.
class_name PosterOptionsPanel
extends Node3D

## Clear of the sheet, measured along the surface it is stuck to rather than
## straight up: a poster on the ceiling would otherwise open its panel inside the
## ceiling, and one on the floor would bury it.
const STANDOFF := 0.12
const RISE := 0.22

var _poster: Poster = null
var _camera: Node3D = null
var _ui_connected := false

@onready var _viewport_node: XRToolsViewport2DIn3D = $PosterOptionsViewport


func _ready() -> void:
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	if _poster and is_instance_valid(_poster):
		global_position = _anchor_point()
	if _camera and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


func _anchor_point() -> Vector3:
	# +Z is out of the sheet's face, so this steps off the surface whatever the
	# surface happens to be, then lifts a little for the common wall case.
	var out := _poster.global_transform.basis.z.normalized()
	return _poster.global_position + out * STANDOFF + Vector3.UP * RISE


func show_for(poster: Poster, camera: Node3D) -> void:
	_poster = poster
	_camera = camera
	if _poster:
		global_position = _anchor_point()
	visible = true
	_ensure_ui_connected()
	_populate()


func hide_panel() -> void:
	visible = false


# ── Internal helpers ───────────────────────────────────────────────────────────

func _get_ui() -> PosterOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as PosterOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.fit_selected.connect(_on_fit_selected)
	ui.size_changed.connect(_on_size_changed)
	ui.size_committed.connect(_on_size_committed)
	ui.peel_requested.connect(_on_peel)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _poster:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	ui.populate(int(_poster.fit_mode), _poster.size_scale, _poster.is_stuck())


func _on_fit_selected(mode: int) -> void:
	if _poster and is_instance_valid(_poster):
		_poster.set_fit_mode(mode as Poster.FitMode)
		_populate()


## Live while the slider moves: the sheet resizes flat, which is cheap.
func _on_size_changed(value: float) -> void:
	if _poster and is_instance_valid(_poster):
		_poster.size_scale = value


## Drag finished — now pay for the wrap once, the way the curved menu panel only
## re-cooks its collision when the tween stops.
func _on_size_committed(value: float) -> void:
	if _poster and is_instance_valid(_poster):
		_poster.size_scale = value
		_poster.apply_fit()


func _on_peel() -> void:
	if _poster and is_instance_valid(_poster):
		_poster.peel()
		_populate()
