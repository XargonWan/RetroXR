## DVDOptions2D — 2D UI for a DVDPlayer's settings (audio track + subtitles).
## Loaded into DVDOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring VCROptions2D.
##
## Emits:
##   audio_track_selected(id) — user picked an audio track (libVLC track id)
##   subtitle_selected(id)    — user picked a subtitle track (-1 = off)
##   close_requested          — user pressed ✕
class_name DVDOptions2D
extends Control

signal audio_track_selected(id: int)
signal subtitle_selected(id: int)
signal close_requested

# ── Palette (matches VCROptions2D) ──────────────────────────────────────────────
const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)
const COLOR_ROW   := Color(0.65, 0.65, 0.80)

var _audio_opt: OptionButton = null
var _sub_opt: OptionButton = null
var _suppress := false


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

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# Title row
	var title_row := HBoxContainer.new()
	root.add_child(title_row)
	var title := Label.new()
	title.text = "DVD Settings"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "  ✕  "
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	_audio_opt = _add_dropdown_row(root, "Audio track")
	_audio_opt.item_selected.connect(func(idx: int):
		if not _suppress:
			audio_track_selected.emit(_audio_opt.get_item_id(idx)))

	_sub_opt = _add_dropdown_row(root, "Subtitles")
	_sub_opt.item_selected.connect(func(idx: int):
		if not _suppress:
			subtitle_selected.emit(_sub_opt.get_item_id(idx)))


func _add_dropdown_row(root: VBoxContainer, label_text: String) -> OptionButton:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 56)
	row.add_theme_constant_override("separation", 8)
	root.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_ROW)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(240, 48)
	opt.add_theme_font_size_override("font_size", 18)
	row.add_child(opt)
	return opt


# ── Public API ──────────────────────────────────────────────────────────────────

## Fill the dropdowns from VlcPlayer track lists (each entry {id:int, name:String})
## and select the current ids, without re-emitting selection signals.
func populate(audio_tracks: Array, cur_audio: int, sub_tracks: Array, cur_sub: int) -> void:
	_suppress = true
	_fill(_audio_opt, audio_tracks, cur_audio, "")
	# libVLC's subtitle list already includes a "Disable" entry (id -1); add one
	# as a fallback if the disc didn't provide it.
	_fill(_sub_opt, sub_tracks, cur_sub, "Off")
	_suppress = false


func _fill(opt: OptionButton, tracks: Array, cur_id: int, off_label: String) -> void:
	if opt == null:
		return
	opt.clear()
	var have_off := false
	for t: Dictionary in tracks:
		var id := int(t.get("id", 0))
		if id == -1:
			have_off = true
		opt.add_item(str(t.get("name", "")), id)
	if not off_label.is_empty() and not have_off:
		opt.add_item(off_label, -1)
	# Select the current id.
	for i in opt.item_count:
		if opt.get_item_id(i) == cur_id:
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)
