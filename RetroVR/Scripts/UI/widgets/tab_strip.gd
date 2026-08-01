## TabStrip — full-width pill buttons standing in for a TabContainer's own tab
## bar, in the spawn menu's main-nav style.
##
## TabContainer's bar inherits the default theme's 16 pt font, which is a third
## the size of everything around it on a 1.1 m panel, and its tabs size to their
## labels so each is a small target. The bar also cannot be made to fill the
## width — TabBar aligns its tabs, it does not stretch them — so the widget's own
## bar is hidden and this drives it instead.
##
## The TabContainer keeps every bit of its behaviour: setting current_tab still
## emits tab_changed, so existing wiring is untouched.
##
##   var view := TabStrip.wrap(tabs)   # returns the VBox to add in its place
class_name TabStrip
extends HFlowContainer

const COLOR_ACTIVE := Color(0.25, 0.25, 0.55)
const COLOR_INACTIVE := Color(0.12, 0.12, 0.25)
const COLOR_TEXT := Color(0.9, 0.9, 1.0)

const FONT_SIZE := 32
const HEIGHT := 56
const SEPARATION := 10
const ROW_SEPARATION := 6
## Padding is not square: the horizontal figure sets the width floor and so the
## point at which the flow wraps, while the vertical one only adds height. The
## 32 pt font is 45 px tall, so PAD_Y must stay under 5 for HEIGHT to be what
## actually decides the row height rather than the stylebox.
const PAD_X := 14
const PAD_Y := 4

var _tabs: TabContainer = null
var _buttons: Array[Button] = []
var _titles: Array[String] = []


## Hide `tabs`' own bar and return a VBox holding this strip above it. Call after
## every tab has been added — the strip is built from the titles as they stand.
static func wrap(tabs: TabContainer) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 12)

	var strip := TabStrip.new()
	strip._build(tabs)
	box.add_child(strip)

	tabs.tabs_visible = false
	box.add_child(tabs)
	return box


func _build(tabs: TabContainer) -> void:
	_tabs = tabs
	add_theme_constant_override("h_separation", SEPARATION)
	add_theme_constant_override("v_separation", ROW_SEPARATION)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	for i in tabs.get_tab_count():
		var title := tabs.get_tab_title(i)
		_titles.append(title)
		var btn := Button.new()
		btn.text = title
		btn.add_theme_color_override("font_color", COLOR_TEXT)
		btn.add_theme_font_size_override("font_size", FONT_SIZE)
		# A width floor per button, so the flow wraps to a second row rather than
		# squeezing the labels. Three Cores tabs stay on one line; ten spawn tabs
		# take two, which is the only way "Controllers" is readable at this size.
		btn.custom_minimum_size = Vector2(0, HEIGHT)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.clip_text = true
		var idx := i
		# Release-mode, so a Viewport2Din3D click's doubled press is harmless:
		# both land on set_current_tab with the same index.
		btn.pressed.connect(func() -> void: _tabs.current_tab = idx)
		add_child(btn)
		_buttons.append(btn)

	tabs.tab_changed.connect(func(_i: int) -> void: _refresh())
	_apply_min_width()
	_refresh()


## Give every button the same width floor: the widest label plus its padding.
## HFlowContainer then wraps when they no longer fit, and EXPAND_FILL stretches
## whatever lands on each row to share it.
##
## This replaced shrinking the font to fit one row. The menu is ~1072 logical px
## (scaled 2x onto the panel), so ten tabs get ~98 px each — "Controllers" does
## not fit there at any size worth reading.
func _apply_min_width() -> void:
	if _buttons.is_empty():
		return
	var font: Font = _buttons[0].get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	var widest := 0.0
	for t: String in _titles:
		widest = maxf(widest, font.get_string_size(
			t, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x)
	var w := widest + PAD_X * 2.0 + 6.0
	for b: Button in _buttons:
		b.custom_minimum_size = Vector2(w, HEIGHT)


func _refresh() -> void:
	if not is_instance_valid(_tabs):
		return
	for i in _buttons.size():
		var s := StyleBoxFlat.new()
		s.bg_color = COLOR_ACTIVE if i == _tabs.current_tab else COLOR_INACTIVE
		s.set_corner_radius_all(6)
		s.content_margin_left = PAD_X
		s.content_margin_right = PAD_X
		s.content_margin_top = PAD_Y
		s.content_margin_bottom = PAD_Y
		for state in ["normal", "hover", "pressed", "focus"]:
			_buttons[i].add_theme_stylebox_override(state, s)
