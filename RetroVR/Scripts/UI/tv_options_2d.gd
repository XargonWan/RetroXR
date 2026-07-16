## TVOptions2D — 2D UI for a TV's settings.
## Loaded into TVOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring BookOptions2D.
##
## Emits:
##   scale_changed(scale)   — size slider moved (fires live while dragging)
##   scale_committed(scale) — size slider drag finished (for net replication)
##   close_requested        — user pressed ✕
class_name TVOptions2D
extends Control

signal scale_changed(scale: float)
signal scale_committed(scale: float)
## A CRT display-stage uniform was changed (pname, value). Applied live.
signal crt_param_changed(pname, value)
signal close_requested

# ── Palette (matches BookOptions2D / CoreOptions2D) ──────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

const MIN_SCALE := 0.2
const MAX_SCALE := 5.0

var _size_slider: HSlider = null
var _size_val: Label = null
var _options_scroll: ScrollContainer = null
var _crt_scroll: ScrollContainer = null
var _active_scroll: ScrollContainer = null
# CRT controls, keyed by shader uniform name → {slider, val_label, fmt}.
var _crt_sliders: Dictionary = {}
var _crt_mask_opt: OptionButton = null
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

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	margin.add_child(root_vbox)

	# ── Title row ──────────────────────────────────────────────────────────────
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "TV Settings"
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

	# ── Tab container (mirrors VCROptions2D): Options | CRT ────────────────────
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
	_active_scroll = _options_scroll

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	_options_scroll.add_child(rows)

	# Size slider row: [label + value] then a full-width slider under it.
	var size_header := HBoxContainer.new()
	size_header.add_theme_constant_override("separation", 8)
	rows.add_child(size_header)

	var size_lbl := Label.new()
	size_lbl.text = "TV size"
	size_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_lbl.add_theme_font_size_override("font_size", 18)
	size_lbl.add_theme_color_override("font_color", COLOR_ROW)
	size_header.add_child(size_lbl)

	_size_val = Label.new()
	_size_val.text = "1.0×"
	_size_val.add_theme_font_size_override("font_size", 18)
	_size_val.add_theme_color_override("font_color", COLOR_TITLE)
	_size_val.custom_minimum_size = Vector2(70, 0)
	_size_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	size_header.add_child(_size_val)

	_size_slider = HSlider.new()
	_size_slider.min_value = MIN_SCALE
	_size_slider.max_value = MAX_SCALE
	_size_slider.step = 0.1
	_size_slider.value = 1.0
	_size_slider.custom_minimum_size = Vector2(0, 48)
	_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(_size_slider)

	# value_changed fires continuously while dragging → live resize; the
	# commit signal on drag end is what gets replicated to other players.
	_size_slider.value_changed.connect(func(v: float):
		_size_val.text = "%.1f×" % v
		if not _suppress_signal:
			scale_changed.emit(v)
	)
	_size_slider.drag_ended.connect(func(value_changed_flag: bool):
		if not _suppress_signal and value_changed_flag:
			scale_committed.emit(_size_slider.value)
	)

	_build_crt_tab(tabs)

	# Stick-scroll drives whichever tab is visible.
	tabs.tab_changed.connect(func(idx: int) -> void:
		_active_scroll = _options_scroll if idx == 0 else _crt_scroll)


# ── CRT filter controls (own tab, like the VCR panel's VHS tab) ───────────────

func _build_crt_tab(tabs: TabContainer) -> void:
	var outer := VBoxContainer.new()
	outer.name = "CRT"
	tabs.add_child(outer)

	_crt_scroll = ScrollContainer.new()
	_crt_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_crt_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_crt_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_crt_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	outer.add_child(_crt_scroll)

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	_crt_scroll.add_child(rows)

	# Mask mode dropdown (Off / Grid / Slot).
	var mask_row := HBoxContainer.new()
	mask_row.add_theme_constant_override("separation", 8)
	rows.add_child(mask_row)
	var mask_lbl := Label.new()
	mask_lbl.text = "RGB mask"
	mask_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mask_lbl.add_theme_font_size_override("font_size", 18)
	mask_lbl.add_theme_color_override("font_color", COLOR_ROW)
	mask_row.add_child(mask_lbl)
	_crt_mask_opt = OptionButton.new()
	_crt_mask_opt.add_item("Off", 0)
	_crt_mask_opt.add_item("Grid", 1)
	_crt_mask_opt.add_item("Slot", 2)
	_crt_mask_opt.item_selected.connect(func(idx: int):
		if not _suppress_signal:
			crt_param_changed.emit("crt_mask_mode", idx)
	)
	mask_row.add_child(_crt_mask_opt)

	# Sliders: [uniform, label, min, max, step, value-format].
	var specs := [
		["crt_mask_strength",     "Mask strength",    0.0, 1.0,  0.05, "%.2f"],
		["crt_pixel_size",        "Mask size",        2.0, 8.0,  1.0,  "%.0f"],
		["crt_scanline_strength", "Scanlines",        0.0, 1.0,  0.05, "%.2f"],
		["crt_scanline_thickness","Scanline width",   0.0, 8.0,  1.0,  "%.0f"],
		["crt_curvature",         "Curvature",        0.0, 0.3,  0.01, "%.2f"],
		["crt_grain",             "Grain",            0.0, 1.0,  0.02, "%.2f"],
		["crt_smear",             "Smear",            0.0, 1.0,  0.05, "%.2f"],
		["crt_wiggle",            "Wiggle",           0.0, 0.2,  0.02, "%.2f"],
		["crt_vignette",          "Vignette",         0.0, 1.0,  0.05, "%.2f"],
		["crt_brightness",        "Brightness",       0.5, 2.0,  0.05, "%.2f"],
	]
	for s: Array in specs:
		_add_crt_slider(rows, s[0], s[1], s[2], s[3], s[4], s[5])


func _add_crt_slider(rows: VBoxContainer, key: String, label: String,
		minv: float, maxv: float, step: float, fmt: String) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	rows.add_child(head)

	var name_lbl := Label.new()
	name_lbl.text = label
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", COLOR_ROW)
	head.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.add_theme_font_size_override("font_size", 18)
	val_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	val_lbl.custom_minimum_size = Vector2(70, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(val_lbl)

	var slider := HSlider.new()
	slider.min_value = minv
	slider.max_value = maxv
	slider.step = step
	slider.custom_minimum_size = Vector2(0, 44)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_child(slider)

	slider.value_changed.connect(func(v: float):
		val_lbl.text = fmt % v
		if not _suppress_signal:
			crt_param_changed.emit(key, v)
	)
	_crt_sliders[key] = {"slider": slider, "val": val_lbl, "fmt": fmt}


# ── Public API ─────────────────────────────────────────────────────────────────

## Sync the UI to the TV's current state without re-emitting signals.
func populate(scale_factor := 1.0) -> void:
	_suppress_signal = true
	if _size_slider:
		_size_slider.value = scale_factor
		_size_val.text = "%.1f×" % scale_factor
	_suppress_signal = false


## Sync the CRT controls to the TV's current uniform values (no signal re-emit).
func populate_crt(params: Dictionary) -> void:
	_suppress_signal = true
	if _crt_mask_opt and params.has("crt_mask_mode"):
		_crt_mask_opt.select(_crt_mask_opt.get_item_index(int(params["crt_mask_mode"])))
	for key: String in _crt_sliders:
		if not params.has(key):
			continue
		var entry: Dictionary = _crt_sliders[key]
		var v := float(params[key])
		(entry["slider"] as HSlider).value = v
		(entry["val"] as Label).text = str(entry["fmt"]) % v
	_suppress_signal = false


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
