## VRCheck — a square tickbox sized for a panel read through a headset.
##
## Unchecked it is an empty gray box with a clear border; checked it fills blue
## and shows a white tick. Both states are legible from across the room, which is
## the whole reason this exists rather than a themed CheckBox: Godot's draws a
## ~16 px indicator beside its label, and at the distance a Viewport2DIn3D panel
## sits, an unchecked one is a few faint pixels.
##
## Sibling to [VRToggle], and the same choice applies — use the switch for a
## setting that is on or off, this for picking items out of a list.
##
## Build with VRCheck.create(initial_on, on_toggled). Extends Button in toggle
## mode, so `button_pressed` still works and setting it in code repaints.
@tool
class_name VRCheck
extends Button

const _SIZE   := 46.0   # outer box, square
const _RADIUS := 7

const _ON_BG      := Color(0.20, 0.52, 0.92)   # the same blue VRToggle uses
const _ON_BORDER  := Color(0.11, 0.32, 0.62)
## Deliberately lighter than the panel behind it. An unchecked box drawn in the
## panel's own dark blue reads as absent rather than as empty.
const _OFF_BG     := Color(0.30, 0.31, 0.36)
const _OFF_BORDER := Color(0.55, 0.56, 0.62)

## md-check, the same glyph the firmware rows use for "this one is present".
const _TICK := 0xF012C

var _tick: Label


static func create(initial_on: bool, on_toggled: Callable = Callable()) -> VRCheck:
	var c := VRCheck.new()
	c._setup(initial_on)
	if on_toggled.is_valid():
		c.toggled.connect(func(on: bool) -> void: on_toggled.call(on))
	return c


func _setup(initial_on: bool) -> void:
	toggle_mode = true
	button_pressed = initial_on
	custom_minimum_size = Vector2(_SIZE, _SIZE)
	# A taller row must not stretch it into a rectangle.
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	focus_mode = Control.FOCUS_NONE
	text = ""
	# Every click inside a Viewport2DIn3D arrives as TWO presses, so a press-mode
	# toggle flips twice and lands back where it started. See MenuStyle.check.
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE

	add_theme_stylebox_override("normal", _box(_OFF_BG, _OFF_BORDER))
	add_theme_stylebox_override("hover", _box(_OFF_BG.lightened(0.10), _OFF_BORDER))
	add_theme_stylebox_override("pressed", _box(_ON_BG, _ON_BORDER))
	add_theme_stylebox_override("hover_pressed", _box(_ON_BG.lightened(0.08), _ON_BORDER))
	add_theme_stylebox_override("disabled",
		_box(_OFF_BG.darkened(0.25), _OFF_BORDER.darkened(0.3)))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	_tick = Label.new()
	_tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tick.add_theme_font_override("font", MenuIcons.symbols())
	_tick.add_theme_font_size_override("font_size", 30)
	_tick.add_theme_color_override("font_color", Color.WHITE)
	_tick.text = String.chr(_TICK)
	_tick.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tick.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Fills the box, so the glyph is centred at any size this is given.
	_tick.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_tick)

	_refresh(initial_on)
	toggled.connect(func(on: bool) -> void: _refresh(on))


func _refresh(on: bool) -> void:
	if _tick != null:
		_tick.visible = on


func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	for side in ["border_width_left", "border_width_right",
				 "border_width_top", "border_width_bottom"]:
		s.set(side, 2)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		s.set(k, _RADIUS)
	for m in ["content_margin_left", "content_margin_right",
			  "content_margin_top", "content_margin_bottom"]:
		s.set(m, 0)
	return s
