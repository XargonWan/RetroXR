## MouseOptions2D — 2D UI for a RetroMouse's settings.
## Loaded into MouseOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring TVOptions2D.
##
## Emits:
##   sensitivity_changed(value)   — slider moved (fires live while dragging)
##   sensitivity_committed(value) — slider drag finished (persisted by owner)
##   close_requested              — user pressed ✕
class_name MouseOptions2D
extends Control

signal sensitivity_changed(value: float)
signal sensitivity_committed(value: float)
signal close_requested

# ── Palette (matches TVOptions2D / BookOptions2D) ────────────────────────────
const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)

const MIN_SENS := 400.0
const MAX_SENS := 6000.0

var _sens_slider: HSlider = null
var _sens_val: Label = null
# Guard so populate() doesn't re-emit signals when it sets control values.
var _suppress_signal := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = COLOR_BG
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(corner, 10)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title row with ✕.
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "Mouse"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.add_theme_font_override("font", MenuIcons.symbols())
	close_btn.text = String.chr(MenuIcons.CLOSE)
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	title_row.add_child(close_btn)

	# Sensitivity row: label + slider + value.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)
	var lbl := Label.new()
	lbl.text = "Sensitivity"
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.add_theme_font_size_override("font_size", 18)
	row.add_child(lbl)
	_sens_slider = HSlider.new()
	_sens_slider.min_value = MIN_SENS
	_sens_slider.max_value = MAX_SENS
	_sens_slider.step = 100.0
	_sens_slider.custom_minimum_size = Vector2(200, 32)
	_sens_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sens_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_sens_slider.value_changed.connect(_on_sens_changed)
	_sens_slider.drag_ended.connect(_on_sens_drag_ended)
	row.add_child(_sens_slider)
	_sens_val = Label.new()
	_sens_val.custom_minimum_size = Vector2(64, 0)
	_sens_val.add_theme_color_override("font_color", COLOR_TITLE)
	_sens_val.add_theme_font_size_override("font_size", 18)
	row.add_child(_sens_val)


## Fill the controls from the mouse's current state (no signals fired).
func populate(sensitivity: float) -> void:
	_suppress_signal = true
	_sens_slider.value = clampf(sensitivity, MIN_SENS, MAX_SENS)
	_sens_val.text = str(int(_sens_slider.value))
	_suppress_signal = false


func _on_sens_changed(value: float) -> void:
	_sens_val.text = str(int(value))
	if not _suppress_signal:
		sensitivity_changed.emit(value)


func _on_sens_drag_ended(changed: bool) -> void:
	if changed and not _suppress_signal:
		sensitivity_committed.emit(_sens_slider.value)
