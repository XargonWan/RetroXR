## VCROptions2D — 2D UI for the VCR player's settings.
## Loaded into VCROptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring CoreOptions2D.
##
## One tab:
##   Options — toggles for the VCR player (currently just the VHS effect shader)
##
## Emits:
##   effect_toggled(enabled) — user toggled the VHS effect checkbox
##   close_requested         — user pressed ✕
class_name VCROptions2D
extends Control

signal effect_toggled(enabled: bool)
signal scan_speed_changed(value: float)
signal close_requested

# ── Palette (matches CoreOptions2D) ─────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

# Fast-forward / rewind scan-rate presets (×).
const SCAN_SPEEDS: Array[float] = [2.0, 4.0, 8.0, 16.0, 32.0]

# ── State ──────────────────────────────────────────────────────────────────────
var _options_scroll: ScrollContainer
var _options_rows: VBoxContainer
var _active_scroll: ScrollContainer = null
var _effect_check: CheckBox = null
var _scan_idx: int = 2   # default 8×
var _scan_val_lbl: Label = null
# Guard so populate() doesn't re-emit effect_toggled when it sets the checkbox.
var _suppress_signal := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	print("[VCROptions2D] UI built")


# ── UI construction ────────────────────────────────────────────────────────────

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

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	margin.add_child(root_vbox)

	# ── Title row ──────────────────────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "VCR Settings"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 26)
	title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(title_lbl)

	var close_btn := Button.new()
	close_btn.text = "  ✕  "
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# ── Tab container ──────────────────────────────────────────────────────────
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_font_size_override("font_size", 18)
	root_vbox.add_child(tabs)

	var opts_outer := VBoxContainer.new()
	opts_outer.name = "Options"
	tabs.add_child(opts_outer)

	_options_scroll = ScrollContainer.new()
	_options_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_options_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_options_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	opts_outer.add_child(_options_scroll)

	_options_rows = VBoxContainer.new()
	_options_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_options_rows.add_theme_constant_override("separation", 4)
	_options_scroll.add_child(_options_rows)

	_active_scroll = _options_scroll

	_build_option_rows()


func _build_option_rows() -> void:
	# VHS effect toggle row: [label] [checkbox]
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)
	row.add_theme_constant_override("separation", 8)
	_options_rows.add_child(row)

	var label := Label.new()
	label.text = "Enable VCR shader"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_effect_check = CheckBox.new()
	_effect_check.button_pressed = true
	_effect_check.custom_minimum_size = Vector2(48, 48)
	_effect_check.add_theme_font_size_override("font_size", 22)
	_effect_check.toggled.connect(func(pressed: bool):
		if _suppress_signal:
			return
		print("[VCROptions2D] VCR shader → ", pressed)
		effect_toggled.emit(pressed)
	)
	row.add_child(_effect_check)

	# Scan speed stepper row: [label] [<] [value] [>]
	var srow := HBoxContainer.new()
	srow.custom_minimum_size = Vector2(0, 56)
	srow.add_theme_constant_override("separation", 8)
	_options_rows.add_child(srow)

	var slabel := Label.new()
	slabel.text = "FF / REW scan speed"
	slabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slabel.add_theme_font_size_override("font_size", 18)
	slabel.add_theme_color_override("font_color", COLOR_ROW)
	slabel.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	srow.add_child(slabel)

	var prev_btn := Button.new()
	prev_btn.text = " < "
	prev_btn.custom_minimum_size = Vector2(48, 48)
	srow.add_child(prev_btn)

	_scan_val_lbl = Label.new()
	_scan_val_lbl.custom_minimum_size = Vector2(80, 0)
	_scan_val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scan_val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_scan_val_lbl.add_theme_font_size_override("font_size", 18)
	_scan_val_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	_scan_val_lbl.text = _scan_text()
	srow.add_child(_scan_val_lbl)

	var next_btn := Button.new()
	next_btn.text = " > "
	next_btn.custom_minimum_size = Vector2(48, 48)
	srow.add_child(next_btn)

	prev_btn.pressed.connect(func(): _step_scan(-1))
	next_btn.pressed.connect(func(): _step_scan(1))


func _step_scan(dir: int) -> void:
	_scan_idx = clampi(_scan_idx + dir, 0, SCAN_SPEEDS.size() - 1)
	_scan_val_lbl.text = _scan_text()
	if not _suppress_signal:
		scan_speed_changed.emit(SCAN_SPEEDS[_scan_idx])


func _scan_text() -> String:
	return "%d×" % int(SCAN_SPEEDS[_scan_idx])


func _nearest_scan_idx(value: float) -> int:
	var best := 0
	var best_d := INF
	for i in SCAN_SPEEDS.size():
		var d: float = absf(SCAN_SPEEDS[i] - value)
		if d < best_d:
			best_d = d
			best = i
	return best


# ── Public API ─────────────────────────────────────────────────────────────────

## Sync the UI to the VCR player's current state without re-emitting signals.
func populate(effect_enabled: bool, scan_speed: float) -> void:
	_suppress_signal = true
	if _effect_check:
		_effect_check.button_pressed = effect_enabled
	_scan_idx = _nearest_scan_idx(scan_speed)
	if _scan_val_lbl:
		_scan_val_lbl.text = _scan_text()
	_suppress_signal = false


## Drive the active scroll container from an external stick input (pixels > 0 = down).
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
