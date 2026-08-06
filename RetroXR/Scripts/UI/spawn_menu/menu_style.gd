## MenuStyle — the spawn menu's palette, and builders for the widgets it makes
## over and over.
##
## The menu builds its whole UI in code, so a sixth of it was widget
## boilerplate: 104 `Label.new()` followed by a font-size override and a colour
## override, 17 hand-rolled rounded stylebox loops, and so on. Those live here
## now, so a view file is the layout and the wiring rather than the ceremony.
##
## Every builder returns exactly what the inline version did — this is a place to
## put the repetition, not an opportunity to restyle. Anything a caller varies
## (action_mode, focus_mode, size flags) is deliberately left to the caller: the
## menu runs in a Viewport2Din3D where those have real consequences, and baking
## one choice in here would apply it to widgets that must not have it.
##
## All static. Never instantiated.
class_name MenuStyle
extends RefCounted

# ── Palette ───────────────────────────────────────────────────────────────────
const COLOR_BG           := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_NAV_ACTIVE   := Color(0.25, 0.25, 0.55)
const COLOR_NAV_INACTIVE := Color(0.12, 0.12, 0.25)
const COLOR_TITLE        := Color(0.9,  0.9,  1.0)
const COLOR_LICENSE      := Color(0.65, 0.65, 0.80)
const COLOR_DESC         := Color(0.55, 0.55, 0.68)
const COLOR_BTN_DL       := Color(0.15, 0.45, 0.15)
## Lighter than COLOR_BTN_DL, which is a button fill and unreadable as text here.
const COLOR_RECOMMENDED  := Color(0.45, 0.85, 0.45)
const COLOR_BTN_UPD      := Color(0.45, 0.30, 0.10)
const COLOR_BTN_REUP     := Color(0.18, 0.18, 0.35)
const COLOR_BTN_BUSY     := Color(0.25, 0.20, 0.10)

# Scrollbar. The track matches the recessed nav chrome; the grabber climbs in
# brightness through hover and drag so the state reads from a metre away.
const COLOR_SCROLL_TRACK   := Color(0.12, 0.12, 0.25)
const COLOR_SCROLL_GRAB    := Color(0.30, 0.30, 0.60)
const COLOR_SCROLL_GRAB_HI := Color(0.42, 0.42, 0.74)
const COLOR_SCROLL_GRAB_ON := Color(0.55, 0.55, 0.90)

# Scene view
const COLOR_SCENE_ACTIVE   := Color(0.3, 0.5, 0.3)
const COLOR_SCENE_INACTIVE := Color(0.15, 0.15, 0.30)
const COLOR_BTN_SAVE       := Color(0.15, 0.45, 0.15)
const COLOR_BTN_CLEAR      := Color(0.50, 0.15, 0.15)
const COLOR_BTN_LOAD       := Color(0.15, 0.30, 0.55)
const COLOR_SLOT_ACTIVE    := Color(0.20, 0.42, 0.20)
const COLOR_SLOT_NORMAL    := Color(0.12, 0.12, 0.27)


# ── Builders ──────────────────────────────────────────────────────────────────

## A filled box with every corner rounded. StyleBoxFlat has no set-all for corner
## radius the way it does for content margins, so this was written out as a
## four-key loop in seventeen places.
static func rounded(color: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	return s


static func label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


## A section heading inside a view — "DISPLAY", "QUALITY", "MULTIPLAYER (LAN)".
static func header(text: String, font_size := 22) -> Label:
	return label(text, font_size, COLOR_TITLE)


## Explanatory small print under a control. Wraps, because these are sentences.
static func hint(text: String) -> Label:
	var l := label(text, 16, COLOR_DESC)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


static func spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


## The vertical scroll every view's root uses. Horizontal is off throughout: the
## panel is a fixed width and a sideways scroll in VR is a way to lose the UI.
static func vscroll() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	fat_vscroll_bar(s)
	return s


## Size the vertical scrollbar as something a laser can actually hit.
##
## Every panel used to ask for this with a `scrollbar_v_width` theme constant,
## which is a Godot 3 name — Godot 4 takes the bar's width from the bar's own
## styleboxes and minimum size, so the override was discarded and the panels drew
## an 8 px bar with an 8 px grabber floor. The spawn panel is 2200 px across
## 1.1 m at ui_scale 2, so one logical pixel is one millimetre: that default is
## an 8 mm x 10 mm target held at arm's length, under the laser's own jitter.
##
## `min_grabber` is PADDING on the grabber box, not a size. ScrollBar adds its
## grabber stylebox's minimum size to the proportional length, so it raises the
## floor without touching the range — which is what the cartridge list needs,
## where 2744 rows come to 274,400 px of content and size the grabber at a
## quarter of a percent of the track, collapsing it onto that floor.
static func fat_vscroll_bar(scroll: ScrollContainer, width := 40, min_grabber := 60) -> void:
	var bar := scroll.get_v_scroll_bar()
	if bar == null:
		return
	bar.custom_minimum_size.x = width

	var radius := width / 2
	bar.add_theme_stylebox_override("scroll", _track(COLOR_SCROLL_TRACK, radius, width))
	bar.add_theme_stylebox_override("scroll_focus", _track(COLOR_SCROLL_TRACK, radius, width))
	bar.add_theme_stylebox_override("grabber", _grabber(COLOR_SCROLL_GRAB, radius, min_grabber))
	bar.add_theme_stylebox_override("grabber_highlight", _grabber(COLOR_SCROLL_GRAB_HI, radius, min_grabber))
	bar.add_theme_stylebox_override("grabber_pressed", _grabber(COLOR_SCROLL_GRAB_ON, radius, min_grabber))


## The track. Its side margins are load bearing: ScrollContainer insets its
## content by the bar's THEME minimum width, not by `custom_minimum_size`, so a
## track with no margins gets a 40 px bar drawn straight over the right-hand
## column of tiles. Vertical margins are left alone — those would come off the
## track length instead.
static func _track(color: Color, radius: int, width: int) -> StyleBoxFlat:
	var s := rounded(color, radius)
	s.content_margin_left = width / 2.0
	s.content_margin_right = width / 2.0
	return s


static func _grabber(color: Color, radius: int, min_length: int) -> StyleBoxFlat:
	var s := rounded(color, radius)
	s.content_margin_top = min_length / 2.0
	s.content_margin_bottom = min_length / 2.0
	return s


static func vbox(separation: int, fill := true) -> VBoxContainer:
	var b := VBoxContainer.new()
	if fill:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_constant_override("separation", separation)
	return b


static func hbox(separation: int) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", separation)
	return b


## True when the headset is actually running.
##
## get_viewport().use_xr is false inside the menu's SubViewport even with the
## headset active — only the root window viewport is flagged, by xr_init.gd — so
## this asks OpenXR directly and is correct from any viewport.
static func is_vr_mode() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


## Byte counts as the menu shows them — download sizes, cache budgets. Here
## rather than in a view because both OPTIONS and the RomM toasts print them,
## and the two must agree on the rounding.
static func human_bytes(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (float(bytes) / 1024.0)
	return "%d B" % bytes
