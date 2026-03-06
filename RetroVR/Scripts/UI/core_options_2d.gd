## CoreOptions2D — 2D scrollable UI for libretro core options.
## Loaded into CoreOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Builds its entire UI programmatically (same pattern as SpawnMenu2D).
##
## Usage:
##   call populate(definitions, current_values) to fill the option rows.
##   Emits option_changed(key, value) when the user cycles a value.
##   Emits close_requested when the ✕ button is pressed.
class_name CoreOptions2D
extends Control

signal option_changed(key: String, value: String)
signal close_requested

# ── Palette (matches spawn menu style) ────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

# ── State ──────────────────────────────────────────────────────────────────────
var _scroll: ScrollContainer
var _rows_container: VBoxContainer
# Cached from last populate() call; used to re-populate while panel is open.
var _definitions: Dictionary = {}
var _values: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	print("[CoreOptions2D] UI built")


# ── UI construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Rounded panel backdrop — same approach as SpawnMenu2D
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = COLOR_BG
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(corner, 10)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	# Inner margin so content doesn't touch the panel edge
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
	title_lbl.text = "Core Options"
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

	# ── Scrollable option rows ──────────────────────────────────────────────────
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	root_vbox.add_child(_scroll)

	_rows_container = VBoxContainer.new()
	_rows_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_container.add_theme_constant_override("separation", 2)
	_scroll.add_child(_rows_container)

	_show_placeholder()


# ── Public API ─────────────────────────────────────────────────────────────────

## Fill or refresh the option rows.
## definitions: Dictionary[String, LibretroOptionDefinition]
## current_values: Dictionary[String, String]
func populate(definitions: Dictionary, current_values: Dictionary) -> void:
	_definitions = definitions
	_values = current_values
	print("[CoreOptions2D] populate() — %d options" % definitions.size())
	_refresh_rows()


## Drive the scroll container from an external stick input.
## pixels > 0 scrolls down, < 0 scrolls up.
func scroll_active(pixels: float) -> void:
	_scroll.scroll_vertical += int(pixels)


# ── Row building ───────────────────────────────────────────────────────────────

func _show_placeholder() -> void:
	for c in _rows_container.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = "No options available.\n(Start emulation first.)"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(0, 80)
	_rows_container.add_child(lbl)


func _refresh_rows() -> void:
	for c in _rows_container.get_children():
		c.queue_free()

	if _definitions.is_empty():
		_show_placeholder()
		return

	# Sort keys alphabetically for a consistent display order
	var keys: Array = _definitions.keys()
	keys.sort()
	for key in keys:
		_add_row(key, _definitions[key], _values.get(key, ""))

	print("[CoreOptions2D] %d option rows built" % keys.size())


## Build a single option row: [label] [<] [current value] [>]
## defn and values_arr elements are LibretroOptionDefinition / LibretroOptionValue
## RefCounted objects from C++. They must stay untyped (no Object/class annotation)
## so GDScript uses dynamic ClassDB dispatch for method calls like GetLabel().
func _add_row(key: String, defn, current_val: String) -> void:
	# Prefer the shorter "categorized" description if available
	var desc: String = defn.GetDescriptionCategorized()
	if desc.is_empty():
		desc = defn.GetDescription()
	if desc.is_empty():
		desc = key

	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 52)
	row.add_theme_constant_override("separation", 4)
	_rows_container.add_child(row)

	var label := Label.new()
	label.text = desc
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	row.add_child(label)

	# values_arr elements are LibretroOptionValue objects (RefCounted from C++).
	# We keep them untyped (plain Object/Variant) to avoid GDScript cast crashes.
	var values_arr: Array = defn.GetValues()
	if values_arr.is_empty():
		return

	# Find the index of the current value so we can start the cycle there
	var cur_idx := 0
	for i in range(values_arr.size()):
		if values_arr[i].GetValue() == current_val:
			cur_idx = i
			break

	var prev_btn := Button.new()
	prev_btn.text = " < "
	prev_btn.custom_minimum_size = Vector2(48, 48)
	row.add_child(prev_btn)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(140, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", 13)
	val_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	val_lbl.clip_text = true
	var initial_v = values_arr[cur_idx]
	val_lbl.text = _value_label(initial_v)
	row.add_child(val_lbl)

	var next_btn := Button.new()
	next_btn.text = " > "
	next_btn.custom_minimum_size = Vector2(48, 48)
	row.add_child(next_btn)

	row.add_child(HSeparator.new())

	# idx_ref is a one-element Array so the lambdas below can mutate it
	var idx_ref := [cur_idx]

	prev_btn.pressed.connect(func():
		idx_ref[0] = (idx_ref[0] - 1 + values_arr.size()) % values_arr.size()
		var v = values_arr[idx_ref[0]]
		val_lbl.text = _value_label(v)
		var new_val: String = v.GetValue()
		print("[CoreOptions2D] '%s' → '%s' (prev)" % [key, new_val])
		option_changed.emit(key, new_val)
	)
	next_btn.pressed.connect(func():
		idx_ref[0] = (idx_ref[0] + 1) % values_arr.size()
		var v = values_arr[idx_ref[0]]
		val_lbl.text = _value_label(v)
		var new_val: String = v.GetValue()
		print("[CoreOptions2D] '%s' → '%s' (next)" % [key, new_val])
		option_changed.emit(key, new_val)
	)


## Return the human-readable label for a LibretroOptionValue, falling back to
## the raw value string if the label is empty.
## Parameter is intentionally untyped — see _add_row note above.
func _value_label(v) -> String:
	var lbl: String = v.GetLabel()
	return lbl if not lbl.is_empty() else v.GetValue()
