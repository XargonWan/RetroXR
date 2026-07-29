## Option list rendered inside a DropdownPanel's viewport.
##
## Buttons stay on ACTION_MODE_BUTTON_RELEASE and swallow a second activation
## in the same frame, for the same reason VRDropdown does: xr-tools delivers
## both a touch and a mouse press for every VR click.
class_name DropdownOptions2D
extends Control

signal option_chosen(id: Variant)

const COLOR_BG    := Color(0.16, 0.16, 0.32, 1.0)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)

const ROW_H := 56
const PAD := 10

var _list: GridContainer = null
var _last_activate_frame := -1


func _ready() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_BG
	sb.border_color = Color(0.55, 0.55, 0.90)
	for side in ["border_width_left", "border_width_right",
			"border_width_top", "border_width_bottom"]:
		sb.set(side, 3)
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		sb.set(corner, 8)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, PAD)
	panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_theme_constant_override("scrollbar_v_width", 24)
	margin.add_child(scroll)

	_list = GridContainer.new()
	_list.columns = 1
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("h_separation", 4)
	_list.add_theme_constant_override("v_separation", 4)
	scroll.add_child(_list)


## options: Array of [display_name: String, id: Variant, (Texture2D)].
func set_options(options: Array, current_id: Variant, font: Font = null,
				 font_size: int = 22, columns: int = 1) -> void:
	if _list == null:
		await ready
	_list.columns = maxi(1, columns)
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()

	for entry: Array in options:
		var btn := Button.new()
		btn.text = ("✓ " if _same(entry[1], current_id) else "   ") + str(entry[0])
		btn.custom_minimum_size = Vector2(0, ROW_H)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", font_size)
		btn.add_theme_color_override("font_color", COLOR_TITLE)
		if font != null:
			btn.add_theme_font_override("font", font)
		if entry.size() > 2 and entry[2] is Texture2D:
			btn.icon = entry[2]
			btn.add_theme_constant_override("icon_max_width", 32)
		var captured: Variant = entry[1]
		btn.pressed.connect(func() -> void: _choose(captured))
		_list.add_child(btn)


## Pixel size this list wants, so the panel can size itself to fit. A grid
## dropdown (render scale, MSAA) must keep its columns or it becomes a very
## long single column.
static func wanted_size(option_count: int, columns: int, col_px: float = 300.0) -> Vector2:
	var cols := maxi(1, columns)
	var rows := int(ceil(float(option_count) / float(cols)))
	return Vector2(PAD * 2 + cols * col_px, PAD * 2 + rows * (ROW_H + 4))


func _choose(id: Variant) -> void:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return
	_last_activate_frame = frame
	option_chosen.emit(id)


static func _same(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b
