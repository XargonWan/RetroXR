## CoreOptions2D — 2D UI for libretro core options and controller port configuration.
## Loaded into CoreOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Builds its entire UI programmatically (same pattern as SpawnMenu2D).
##
## Two tabs:
##   Options   — cycle < / > through each core option value
##   Controllers — OptionButton per port to choose the active device type
##
## Emits:
##   option_changed(key, value)     — user changed a core option
##   port_device_changed(port, id)  — user changed a port's device type
##   close_requested                — user pressed ✕
class_name CoreOptions2D
extends Control

signal option_changed(key: String, value: String)
signal port_device_changed(port: int, device_id: int)
## System-tab toggle: show/hide the console's video-out cables.
signal video_out_toggled(enabled: bool)
## System-tab toggle: float in place where dropped (no gravity).
signal ignore_gravity_toggled(enabled: bool)
signal close_requested

# ── Palette ────────────────────────────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

# ── State ──────────────────────────────────────────────────────────────────────
var _options_scroll: ScrollContainer
var _options_rows: VBoxContainer
var _controllers_scroll: ScrollContainer
var _controllers_rows: VBoxContainer
var _system_scroll: ScrollContainer
var _video_out_row: HBoxContainer = null
var _video_out_check: CheckBox = null
var _ignore_grav_check: CheckBox = null
var _tabs: TabContainer = null
var _system_tab_idx := -1
var _active_scroll: ScrollContainer = null
# Guard so populate_system() doesn't re-emit when it sets control values.
var _suppress_signal := false

var _definitions: Dictionary = {}
var _values: Dictionary = {}
# Array of Dictionaries: [{port, controllers: [{name, id}], current_id}]
var _controller_info: Array = []


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
	title_lbl.text = "System Settings"
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

	# Options tab
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
	_options_rows.add_theme_constant_override("separation", 2)
	_options_scroll.add_child(_options_rows)

	# Controllers tab
	var ctrl_outer := VBoxContainer.new()
	ctrl_outer.name = "Controllers"
	tabs.add_child(ctrl_outer)

	_controllers_scroll = ScrollContainer.new()
	_controllers_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_controllers_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_controllers_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_controllers_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	ctrl_outer.add_child(_controllers_scroll)

	_controllers_rows = VBoxContainer.new()
	_controllers_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_controllers_rows.add_theme_constant_override("separation", 4)
	_controllers_scroll.add_child(_controllers_rows)

	# System tab (device-level settings, not core options). The video-out row
	# only shows for handhelds — consoles' cables are always on.
	_tabs = tabs
	var sys_outer := VBoxContainer.new()
	sys_outer.name = "System"
	tabs.add_child(sys_outer)
	_system_tab_idx = tabs.get_tab_count() - 1

	_system_scroll = ScrollContainer.new()
	_system_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_system_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_system_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_system_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	sys_outer.add_child(_system_scroll)

	var sys_rows := VBoxContainer.new()
	sys_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sys_rows.add_theme_constant_override("separation", 4)
	_system_scroll.add_child(sys_rows)

	_video_out_row = HBoxContainer.new()
	_video_out_row.custom_minimum_size = Vector2(0, 56)
	_video_out_row.add_theme_constant_override("separation", 8)
	sys_rows.add_child(_video_out_row)

	var vo_lbl := Label.new()
	vo_lbl.text = "Enable Video Out"
	vo_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vo_lbl.add_theme_font_size_override("font_size", 18)
	vo_lbl.add_theme_color_override("font_color", COLOR_ROW)
	vo_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_video_out_row.add_child(vo_lbl)

	_video_out_check = CheckBox.new()
	_video_out_check.custom_minimum_size = Vector2(48, 48)
	_video_out_check.add_theme_font_size_override("font_size", 22)
	_video_out_check.toggled.connect(func(on: bool):
		if not _suppress_signal:
			video_out_toggled.emit(on)
	)
	_video_out_row.add_child(_video_out_check)

	var grav_row := HBoxContainer.new()
	grav_row.custom_minimum_size = Vector2(0, 56)
	grav_row.add_theme_constant_override("separation", 8)
	sys_rows.add_child(grav_row)

	var grav_lbl := Label.new()
	grav_lbl.text = "Ignore Gravity"
	grav_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grav_lbl.add_theme_font_size_override("font_size", 18)
	grav_lbl.add_theme_color_override("font_color", COLOR_ROW)
	grav_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	grav_row.add_child(grav_lbl)

	_ignore_grav_check = CheckBox.new()
	_ignore_grav_check.custom_minimum_size = Vector2(48, 48)
	_ignore_grav_check.add_theme_font_size_override("font_size", 22)
	_ignore_grav_check.toggled.connect(func(on: bool):
		if not _suppress_signal:
			ignore_gravity_toggled.emit(on)
	)
	grav_row.add_child(_ignore_grav_check)

	# Track which scroll container is active for stick-driven scrolling
	_active_scroll = _options_scroll
	tabs.tab_changed.connect(func(idx: int):
		match idx:
			0: _active_scroll = _options_scroll
			1: _active_scroll = _controllers_scroll
			2: _active_scroll = _system_scroll
	)

	_show_options_placeholder()
	_show_controllers_placeholder()


# ── Public API ─────────────────────────────────────────────────────────────────

## Fill or refresh all tabs.
## controller_info: Array of Dicts [{port, controllers:[{name,id}], current_id}]
func populate(definitions: Dictionary, current_values: Dictionary, controller_info: Array) -> void:
	_definitions = definitions
	_values = current_values
	_controller_info = controller_info
	print("[CoreOptions2D] populate() — %d options, %d ports" % [definitions.size(), controller_info.size()])
	_refresh_options()
	_refresh_controllers()


## Sync the System tab to the device's current state (no signal re-emit).
## `show_video_out` false (consoles) hides just that row — their cable is
## always on; the tab stays for the other device toggles.
func populate_system(video_out: bool, show_video_out: bool, ignore_grav: bool) -> void:
	_suppress_signal = true
	if _video_out_row:
		_video_out_row.visible = show_video_out
	if _video_out_check:
		_video_out_check.button_pressed = video_out
	if _ignore_grav_check:
		_ignore_grav_check.button_pressed = ignore_grav
	_suppress_signal = false


## Drive the active scroll container from an external stick input (pixels > 0 = down).
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)


# ── Options tab ────────────────────────────────────────────────────────────────

func _show_options_placeholder() -> void:
	for c in _options_rows.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = "No options available.\n(Start emulation first.)"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(0, 80)
	_options_rows.add_child(lbl)


func _refresh_options() -> void:
	for c in _options_rows.get_children():
		c.queue_free()

	if _definitions.is_empty():
		_show_options_placeholder()
		return

	var keys: Array = _definitions.keys()
	keys.sort()
	for key in keys:
		_add_option_row(key, _definitions[key], _values.get(key, ""))

	print("[CoreOptions2D] %d option rows built" % keys.size())


## Build a single option row: [description label] [<] [current value] [>]
## defn is a LibretroOptionDefinition (untyped to allow dynamic ClassDB dispatch).
func _add_option_row(key: String, defn, current_val: String) -> void:
	var desc: String = defn.GetDescriptionCategorized()
	if desc.is_empty():
		desc = defn.GetDescription()
	if desc.is_empty():
		desc = key

	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 52)
	row.add_theme_constant_override("separation", 4)
	_options_rows.add_child(row)

	var label := Label.new()
	label.text = desc
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	row.add_child(label)

	# values_arr elements are LibretroOptionValue objects (RefCounted from C++).
	# Kept untyped so GDScript uses dynamic ClassDB dispatch for GetValue/GetLabel.
	var values_arr: Array = defn.GetValues()
	if values_arr.is_empty():
		return

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


## Return a LibretroOptionValue's display label, falling back to the raw value.
## Parameter intentionally untyped — see _add_option_row note.
func _value_label(v) -> String:
	var lbl: String = v.GetLabel()
	return lbl if not lbl.is_empty() else v.GetValue()


# ── Controllers tab ────────────────────────────────────────────────────────────

func _show_controllers_placeholder() -> void:
	for c in _controllers_rows.get_children():
		c.queue_free()
	var lbl := Label.new()
	lbl.text = "No controller info available.\n(Start emulation first.)"
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.custom_minimum_size = Vector2(0, 80)
	_controllers_rows.add_child(lbl)


func _refresh_controllers() -> void:
	for c in _controllers_rows.get_children():
		c.queue_free()

	if _controller_info.is_empty():
		_show_controllers_placeholder()
		return

	for entry in _controller_info:
		_add_controller_row(entry)

	print("[CoreOptions2D] %d controller port rows built" % _controller_info.size())


## Build one row per port: [Port N] [inline dropdown of device types].
## Uses VRDropdown rather than OptionButton — an OptionButton's PopupMenu is a
## Window, and the VR viewport's duplicated press dismisses it on the same click
## it opens on (see vr_dropdown.gd).
func _add_controller_row(entry: Dictionary) -> void:
	var port: int = entry["port"]
	var controllers: Array = entry["controllers"]
	var current_id: int = entry["current_id"]

	if controllers.is_empty():
		return

	var options: Array = []
	for ctrl: Dictionary in controllers:
		options.append([str(ctrl["name"]), int(ctrl["id"])])

	var drop := VRDropdown.create("Port %d" % (port + 1), options, current_id,
		1, Vector2(300, 48), 16)
	drop.set_placeholder("(device %d)" % current_id)
	drop.item_selected.connect(func(device_id: Variant) -> void:
		print("[CoreOptions2D] port %d → device %d" % [port, int(device_id)])
		port_device_changed.emit(port, int(device_id))
	)

	_controllers_rows.add_child(drop)
	_controllers_rows.add_child(HSeparator.new())
