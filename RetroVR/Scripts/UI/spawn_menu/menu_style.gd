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
