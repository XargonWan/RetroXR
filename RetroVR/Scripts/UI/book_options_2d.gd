## BookOptions2D — 2D UI for a PDF book's settings.
## Loaded into BookOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring VCROptions2D.
##
## Emits:
##   half_page_toggled(enabled) — user toggled half-page (split spread) mode
##   close_requested            — user pressed ✕
class_name BookOptions2D
extends Control

signal half_page_toggled(enabled: bool)
signal close_requested

# ── Palette (matches CoreOptions2D) ─────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

var _half_check: CheckBox = null
var _active_scroll: ScrollContainer = null
# Guard so populate() doesn't re-emit half_page_toggled when it sets the checkbox.
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
	title_lbl.text = "Book Settings"
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

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_vbox.add_child(scroll)
	_active_scroll = scroll

	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	scroll.add_child(rows)

	# Half-page toggle row: [label] [checkbox]
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)
	row.add_theme_constant_override("separation", 8)
	rows.add_child(row)

	var label := Label.new()
	label.text = "Half pages (split two-page scans)"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_half_check = CheckBox.new()
	_half_check.custom_minimum_size = Vector2(48, 48)
	_half_check.add_theme_font_size_override("font_size", 22)
	_half_check.toggled.connect(func(pressed: bool):
		if _suppress_signal:
			return
		half_page_toggled.emit(pressed)
	)
	row.add_child(_half_check)


# ── Public API ─────────────────────────────────────────────────────────────────

## Sync the UI to the book's current state without re-emitting signals.
func populate(half_pages: bool) -> void:
	_suppress_signal = true
	if _half_check:
		_half_check.button_pressed = half_pages
	_suppress_signal = false


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
