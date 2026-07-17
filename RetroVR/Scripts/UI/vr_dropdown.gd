## VRDropdown — a label + inline expanding option list, for use inside the
## XRToolsViewport2DIn3D panels.
##
## Why this exists instead of OptionButton — two separate hazards, both caused
## by viewport_2d_in_3d_body.gd pushing BOTH an InputEventScreenTouch AND an
## InputEventMouseButton for every pointer press (touch is then emulated into a
## second mouse press), so one VR click arrives as TWO presses:
##
##  1. OptionButton opens a PopupMenu — a separate embedded Window. The first
##     press opens it; the second lands outside the popup's rect and reads as
##     click-away, dismissing it on the same click. It never appears.
##  2. ACTION_MODE_BUTTON_PRESS makes a Button fire `pressed` TWICE per click
##     (measured), so any toggle built that way opens and closes instantly.
##
## So this control keeps the list inline (an ordinary PanelContainer in the
## Control tree — no Window), leaves every button on the default
## ACTION_MODE_BUTTON_RELEASE, and drops any second activation that lands in the
## SAME process frame. Both duplicate presses are measured to arrive in one
## frame, and a user cannot physically click twice in a single frame, so the
## guard is exact. Do NOT set ACTION_MODE_BUTTON_PRESS on these buttons — it
## makes the duplicate fire `pressed` twice instead of once.
##
## Usage:
##   var d := VRDropdown.create("Port 1", [["Gamepad", 1], ["Zapper", 258]], 1)
##   d.item_selected.connect(func(id: Variant) -> void: ...)
##   row.add_child(d)
class_name VRDropdown
extends VBoxContainer

## Emitted only on real user selection, never from set_options()/select_id().
signal item_selected(id: Variant)

const COLOR_TITLE := Color(0.9, 0.9, 1.0)

## Only one dropdown may be expanded at a time, across every panel.
static var _open_dropdown: VRDropdown = null

var _label: Label
var _toggle: Button
var _panel: PanelContainer
var _list: GridContainer
var _opt_btns: Array[Button] = []
var _ids: Array = []
var _options: Array = []
var _current_id: Variant = null
var _grid_cols := 1
var _font_size := 18
var _placeholder := ""
# Frame of the last accepted activation, to swallow the duplicate press that
# xr-tools delivers in the same frame.
var _last_activate_frame := -1


## options: Array of [display_name: String, id: Variant].
static func create(
		label_text: String,
		options: Array,
		current_id: Variant,
		grid_cols: int = 1,
		toggle_min_size: Vector2 = Vector2(220, 52),
		font_size: int = 18) -> VRDropdown:
	var d := VRDropdown.new()
	d._grid_cols = maxi(1, grid_cols)
	d._font_size = font_size
	d._build(label_text, toggle_min_size)
	d.set_options(options, current_id)
	return d


func _build(label_text: String, toggle_min_size: Vector2) -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	add_child(row)

	_label = Label.new()
	_label.text = label_text
	_label.add_theme_font_size_override("font_size", _font_size)
	_label.add_theme_color_override("font_color", COLOR_TITLE)
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_label)

	_toggle = Button.new()
	_toggle.custom_minimum_size = toggle_min_size
	_toggle.add_theme_font_size_override("font_size", _font_size)
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_on_toggle_pressed)
	row.add_child(_toggle)

	_panel = PanelContainer.new()
	_panel.visible = false
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.10, 0.10, 0.22, 0.97)
	ps.border_color = Color(0.35, 0.35, 0.65)
	for side in ["border_width_left", "border_width_right",
			"border_width_top", "border_width_bottom"]:
		ps.set(side, 2)
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		ps.set(corner, 6)
	_panel.add_theme_stylebox_override("panel", ps)
	add_child(_panel)

	_list = GridContainer.new()
	_list.columns = _grid_cols
	_list.add_theme_constant_override("h_separation", 4)
	_list.add_theme_constant_override("v_separation", 2)
	_panel.add_child(_list)


# ── Public API ─────────────────────────────────────────────────────────────────

## Rebuild the option list. Does not emit item_selected.
func set_options(options: Array, current_id: Variant) -> void:
	_options = options
	_current_id = current_id
	_ids.clear()
	_opt_btns.clear()
	for c in _list.get_children():
		c.queue_free()
		_list.remove_child(c)

	for entry: Array in _options:
		var opt_label := entry[0] as String
		var opt_id: Variant = entry[1]
		_ids.append(opt_id)

		var btn := Button.new()
		btn.text = _tick(opt_id) + opt_label
		btn.custom_minimum_size = Vector2(0, 40 if _grid_cols > 1 else 48)
		btn.add_theme_font_size_override("font_size", 16 if _grid_cols > 1 else _font_size)
		btn.focus_mode = Control.FOCUS_NONE
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var captured: Variant = opt_id
		btn.pressed.connect(func() -> void: _on_item_pressed(captured))
		_list.add_child(btn)
		_opt_btns.append(btn)

	_refresh_labels()
	close()


## Select by id without emitting item_selected (for populate()-style calls).
func select_id(current_id: Variant) -> void:
	_current_id = current_id
	_refresh_labels()


func get_selected_id() -> Variant:
	return _current_id


## Shown on the toggle when no option matches the current id.
func set_placeholder(text: String) -> void:
	_placeholder = text
	_refresh_labels()


func set_label(text: String) -> void:
	_label.text = text


func close() -> void:
	_panel.visible = false
	if _open_dropdown == self:
		_open_dropdown = null
	_refresh_toggle_arrow()


func is_open() -> bool:
	return _panel.visible


# ── Internals ──────────────────────────────────────────────────────────────────

func _tick(id: Variant) -> String:
	return "✓  " if id == _current_id else "    "


func _current_label() -> String:
	for entry: Array in _options:
		if entry[1] == _current_id:
			return entry[0] as String
	return _placeholder


func _refresh_labels() -> void:
	for i in range(_opt_btns.size()):
		_opt_btns[i].text = _tick(_ids[i]) + (_options[i][0] as String)
	_refresh_toggle_arrow()


func _refresh_toggle_arrow() -> void:
	_toggle.text = _current_label() + (" ▴" if _panel.visible else " ▾")


## True for the first activation in a frame; false for xr-tools' duplicate.
func _accept_activation() -> bool:
	var frame := Engine.get_process_frames()
	if frame == _last_activate_frame:
		return false
	_last_activate_frame = frame
	return true


func _on_toggle_pressed() -> void:
	if not _accept_activation():
		return
	var opening := not _panel.visible
	if _open_dropdown != null and _open_dropdown != self \
			and is_instance_valid(_open_dropdown):
		_open_dropdown.close()
	_panel.visible = opening
	_open_dropdown = self if opening else null
	_refresh_toggle_arrow()


func _on_item_pressed(id: Variant) -> void:
	if not _accept_activation():
		return
	_current_id = id
	_refresh_labels()
	close()
	item_selected.emit(id)


func _exit_tree() -> void:
	if _open_dropdown == self:
		_open_dropdown = null
