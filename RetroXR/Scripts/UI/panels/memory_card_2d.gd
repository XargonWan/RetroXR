## MemoryCard2D — 2D UI listing what is actually saved on a PS1 memory card.
## Loaded into MemoryCardPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D / TVOptions2D.
##
## One row per save, each showing the game's own 16x16 icon animated at the
## rate the PlayStation used, its Shift-JIS title, and how many of the card's
## 15 blocks it takes.
##
## Emits:
##   name_committed(text) — card name committed
##   close_requested — user pressed ✕
class_name MemoryCard2D
extends Control

signal name_committed(text: String)
signal close_requested

const COLOR_BG := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9, 0.9, 1.0)
const COLOR_ROW := Color(0.65, 0.65, 0.80)
const COLOR_DIM := Color(0.45, 0.45, 0.58)

## The PS1 cycled icon frames at about 6 Hz.
const ICON_FPS := 6.0
const ICON_PX := 48

## Show the rename field and the ✕. The spawn menu reuses this as a read-only
## save list inside its own page, where both would be wrong: it has its own back
## button, and the card being read may not even be in the room to rename.
var show_name_field := true

var _list: VBoxContainer = null
var _name_edit: LineEdit = null
var _usage: Label = null

# Each entry: {rect: TextureRect, frames: Array[ImageTexture]}
var _animated: Array[Dictionary] = []
var _clock := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _process(delta: float) -> void:
	if _animated.is_empty():
		return
	_clock += delta
	var f := int(_clock * ICON_FPS)
	for a in _animated:
		var frames: Array = a["frames"]
		var rect: TextureRect = a["rect"]
		rect.texture = frames[f % frames.size()]


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
		margin.add_theme_constant_override(side, 14)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Embedded in a page that already names the card in its own header, the title
	# and its ✕ are a second heading for the same thing.
	var title_row := HBoxContainer.new()
	title_row.visible = show_name_field
	vbox.add_child(title_row)
	var title := Label.new()
	title.text = "Memory Card"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	if show_name_field:
		var close := Button.new()
		close.text = "✕"
		close.pressed.connect(func() -> void: close_requested.emit())
		title_row.add_child(close)

	var name_row := HBoxContainer.new()
	name_row.visible = show_name_field
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name"
	name_lbl.add_theme_color_override("font_color", COLOR_ROW)
	name_row.add_child(name_lbl)
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(t: String) -> void: name_committed.emit(t))
	_name_edit.focus_exited.connect(func() -> void: name_committed.emit(_name_edit.text))
	name_row.add_child(_name_edit)

	_usage = Label.new()
	_usage.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(_usage)

	var sep := HSeparator.new()
	vbox.add_child(sep)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)


## Fill from a parsed card. `saves` is PS1Card.list_saves() output.
func populate(card_name: String, saves: Array, free: int) -> void:
	_name_edit.text = card_name
	_animated.clear()
	for c in _list.get_children():
		c.queue_free()

	var used := 15 - free
	_usage.text = "%d of 15 blocks used   ·   %d save%s" \
		% [used, saves.size(), "" if saves.size() == 1 else "s"]

	if saves.is_empty():
		var empty := Label.new()
		empty.text = "This card is formatted and empty."
		empty.add_theme_color_override("font_color", COLOR_DIM)
		_list.add_child(empty)
		return

	for s: Dictionary in saves:
		_list.add_child(_make_row(s))


func _make_row(s: Dictionary) -> Control:
	var row := PanelContainer.new()
	var rbg := StyleBoxFlat.new()
	rbg.bg_color = Color(1, 1, 1, 0.05)
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		rbg.set(corner, 6)
	rbg.content_margin_left = 8
	rbg.content_margin_right = 8
	rbg.content_margin_top = 6
	rbg.content_margin_bottom = 6
	row.add_theme_stylebox_override("panel", rbg)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	row.add_child(h)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
	# The art is 16x16; keep it crisp rather than smearing it up to 48.
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.stretch_mode = TextureRect.STRETCH_SCALE
	h.add_child(icon)

	var frames: Array = []
	for img: Image in s.get("icons", []):
		frames.append(ImageTexture.create_from_image(img))
	if not frames.is_empty():
		icon.texture = frames[0]
		if frames.size() > 1:
			_animated.append({"rect": icon, "frames": frames})

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)

	var t := Label.new()
	var title_text := str(s.get("title", ""))
	t.text = title_text if not title_text.is_empty() else str(s.get("name", ""))
	t.add_theme_font_size_override("font_size", 20)
	t.add_theme_color_override("font_color", COLOR_TITLE)
	col.add_child(t)

	var sub := Label.new()
	var blocks: int = int(s.get("blocks", 1))
	sub.text = "%s   ·   %d block%s" \
		% [str(s.get("serial", "")), blocks, "" if blocks == 1 else "s"]
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", COLOR_DIM)
	col.add_child(sub)

	return row
