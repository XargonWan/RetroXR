## PosterOptions2D — 2D UI for a Poster's settings.
## Loaded into PosterOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D.
##
## Emits:
##   fit_selected(mode)      — Flat / Conform / Decal picked
##   size_changed(value)     — slider moved (fires live while dragging)
##   size_committed(value)   — slider drag finished
##   peel_requested          — take it off the surface
##   close_requested         — user pressed ✕
class_name PosterOptions2D
extends Control

signal fit_selected(mode: int)
signal size_changed(value: float)
signal size_committed(value: float)
signal peel_requested
signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)
const COLOR_ON := Color(0.25, 0.45, 0.85)

const MIN_SIZE := 0.05
const MAX_SIZE := 3.0

var _size_slider: HSlider = null
var _size_val: Label = null
var _fit_buttons: Array[Button] = []
var _peel_btn: Button = null
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

	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "Poster"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(36, 36)
	close_btn.pressed.connect(func() -> void: close_requested.emit())
	title_row.add_child(close_btn)

	# Fit row: three segmented buttons. Reads better than a dropdown at this size,
	# and the whole choice is visible without opening anything.
	var fit_row := HBoxContainer.new()
	fit_row.add_theme_constant_override("separation", 6)
	vbox.add_child(fit_row)
	var fit_lbl := Label.new()
	fit_lbl.text = "Fit"
	fit_lbl.add_theme_color_override("font_color", COLOR_ROW)
	fit_lbl.add_theme_font_size_override("font_size", 18)
	fit_lbl.custom_minimum_size = Vector2(52, 0)
	fit_row.add_child(fit_lbl)
	var names := ["Flat", "Conform", "Decal"]
	for i in range(names.size()):
		var b := Button.new()
		b.text = names[i]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 38)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			if not _suppress_signal:
				fit_selected.emit(i)
		)
		fit_row.add_child(b)
		_fit_buttons.append(b)

	# Size row.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vbox.add_child(row)
	var lbl := Label.new()
	lbl.text = "Size"
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.custom_minimum_size = Vector2(52, 0)
	row.add_child(lbl)
	_size_slider = HSlider.new()
	_size_slider.min_value = MIN_SIZE
	_size_slider.max_value = MAX_SIZE
	_size_slider.step = 0.01
	_size_slider.custom_minimum_size = Vector2(200, 32)
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_size_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_size_slider.value_changed.connect(_on_size_changed)
	_size_slider.drag_ended.connect(_on_size_drag_ended)
	row.add_child(_size_slider)
	_size_val = Label.new()
	_size_val.custom_minimum_size = Vector2(64, 0)
	_size_val.add_theme_color_override("font_color", COLOR_TITLE)
	_size_val.add_theme_font_size_override("font_size", 18)
	row.add_child(_size_val)

	_peel_btn = Button.new()
	_peel_btn.text = "Peel off"
	_peel_btn.custom_minimum_size = Vector2(0, 40)
	_peel_btn.pressed.connect(func() -> void: peel_requested.emit())
	vbox.add_child(_peel_btn)


## Fill the controls from the poster's state, firing nothing.
##
## `stuck` greys the rows that only mean something on a surface: a poster in the
## hand has nothing to conform to and nothing to peel off.
func populate(fit_mode: int, size_scale: float, stuck: bool) -> void:
	_suppress_signal = true
	for i in range(_fit_buttons.size()):
		var b := _fit_buttons[i]
		b.button_pressed = (i == fit_mode)
		b.disabled = not stuck and i != 0
		b.add_theme_color_override("font_color",
			COLOR_ON if i == fit_mode else COLOR_ROW)
	_size_slider.value = clampf(size_scale, MIN_SIZE, MAX_SIZE)
	_size_val.text = "%.2f×" % _size_slider.value
	_peel_btn.disabled = not stuck
	_suppress_signal = false


func _on_size_changed(value: float) -> void:
	_size_val.text = "%.2f×" % value
	if not _suppress_signal:
		size_changed.emit(value)


func _on_size_drag_ended(changed: bool) -> void:
	if changed and not _suppress_signal:
		size_committed.emit(_size_slider.value)
