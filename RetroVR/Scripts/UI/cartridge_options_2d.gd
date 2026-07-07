## CartridgeOptions2D — 2D UI for a cartridge's battery-save management.
## Loaded into CartridgeOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
##
## Lists every .srm that exists for this game (save recovery — files are never
## deleted) plus "New blank save". Selecting an entry re-binds this cartridge's
## save_id; nothing on disk is touched until the console next flushes.
##
## Emits:
##   save_selected(save_id) — user picked an existing save ("" = new blank)
##   close_requested        — user pressed ✕
class_name CartridgeOptions2D
extends Control

signal save_selected(save_id: String)
signal close_requested

const COLOR_BG      := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE   := Color(0.9,  0.9,  1.0)
const COLOR_ROW     := Color(0.65, 0.65, 0.80)
const COLOR_CURRENT := Color(0.35, 0.85, 0.45)

var _title_lbl: Label = null
var _rows_box: VBoxContainer = null
var _active_scroll: ScrollContainer = null


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

	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	_title_lbl = Label.new()
	_title_lbl.text = "Battery Save"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.add_theme_font_size_override("font_size", 24)
	_title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(_title_lbl)

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

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_rows_box)


## Rebuild the list. `saves` = SramPaths.list_saves() entries; current_id is
## the cartridge's bound save_id.
func populate(game_label: String, saves: Array, current_id: String, core_known: bool) -> void:
	_title_lbl.text = "Battery Save — %s" % game_label if not game_label.is_empty() else "Battery Save"
	for child in _rows_box.get_children():
		child.queue_free()

	if not core_known:
		var note := Label.new()
		note.text = "Insert this cartridge into a console once\nto discover its saves."
		note.add_theme_font_size_override("font_size", 18)
		note.add_theme_color_override("font_color", COLOR_ROW)
		_rows_box.add_child(note)
		return

	_add_row("＋  New blank save", "", current_id.is_empty() or not _has_id(saves, current_id))
	for s: Variant in saves:
		var d := s as Dictionary
		var save_id := str(d.get("save_id", ""))
		var when := Time.get_datetime_string_from_unix_time(int(d.get("mtime", 0))).replace("T", "  ")
		var text := "%s    %s    %.1f KB" % [save_id.left(8), when, int(d.get("size", 0)) / 1024.0]
		_add_row(text, save_id, save_id == current_id)


func _has_id(saves: Array, id: String) -> bool:
	for s: Variant in saves:
		if str((s as Dictionary).get("save_id", "")) == id:
			return true
	return false


func _add_row(text: String, save_id: String, is_current: bool) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 18)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.text = ("●  " if is_current else "    ") + text
	if is_current:
		btn.add_theme_color_override("font_color", COLOR_CURRENT)
	btn.pressed.connect(func(): save_selected.emit(save_id))
	_rows_box.add_child(btn)


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
