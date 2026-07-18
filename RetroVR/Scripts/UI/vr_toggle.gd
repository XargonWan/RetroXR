## VRToggle — a classic skeuomorphic ON/OFF slider switch, used everywhere a
## boolean is toggled so every switch in the UI looks the same. When ON the track
## is blue with "ON" on the left and the raised knob sits on the right; when OFF
## the track is gray with "OFF" on the right and the knob sits on the left.
##
## Build with VRToggle.create(initial_on, on_toggled). Extends Button
## (toggle_mode), so it drops into existing rows and `button_pressed` still works;
## setting it programmatically also slides the knob and swaps the label.
@tool
class_name VRToggle
extends Button

const _W      := 104.0   # track width
const _H      := 46.0    # track height
const _KNOB_W := 50.0    # knob width (covers ~half the track)
const _MARGIN := 3.0     # inset of the knob from the track edge
const _RADIUS := 8       # track/knob corner radius

const _ON_BG      := Color(0.20, 0.52, 0.92)   # classic blue
const _ON_BORDER  := Color(0.11, 0.32, 0.62)
const _OFF_BG     := Color(0.85, 0.86, 0.88)   # light gray
const _OFF_BORDER := Color(0.54, 0.55, 0.59)
const _KNOB_BG    := Color(0.96, 0.965, 0.975)
const _KNOB_BORDER := Color(0.50, 0.51, 0.55)

var _knob: Panel
var _gloss: Panel
var _label: Label
var _x_on: float
var _x_off: float


## Factory: a ready-to-use switch. on_toggled(on: bool) fires on user changes.
static func create(initial_on: bool, on_toggled: Callable = Callable()) -> VRToggle:
	var t := VRToggle.new()
	t._setup(initial_on)
	if on_toggled.is_valid():
		t.toggled.connect(func(on: bool) -> void: on_toggled.call(on))
	return t


func _setup(initial_on: bool) -> void:
	toggle_mode = true
	button_pressed = initial_on
	custom_minimum_size = Vector2(_W, _H)
	focus_mode = Control.FOCUS_NONE
	text = ""
	clip_contents = true

	add_theme_stylebox_override("normal", _track(_OFF_BG, _OFF_BORDER))
	add_theme_stylebox_override("hover", _track(_OFF_BG.lightened(0.04), _OFF_BORDER))
	add_theme_stylebox_override("pressed", _track(_ON_BG, _ON_BORDER))
	add_theme_stylebox_override("hover_pressed", _track(_ON_BG.lightened(0.04), _ON_BORDER))
	add_theme_stylebox_override("disabled", _track(Color(0.7, 0.7, 0.72), _OFF_BORDER))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	# ON/OFF caption, sits in the track half not covered by the knob.
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 18)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)

	# Raised knob.
	_knob = Panel.new()
	_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_knob.size = Vector2(_KNOB_W, _H - 2.0 * _MARGIN)
	var ks := StyleBoxFlat.new()
	ks.bg_color = _KNOB_BG
	ks.border_color = _KNOB_BORDER
	for s in ["border_width_left", "border_width_right", "border_width_top", "border_width_bottom"]:
		ks.set(s, 1)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		ks.set(k, _RADIUS - 2)
	ks.shadow_color = Color(0, 0, 0, 0.22)
	ks.shadow_size = 3
	ks.shadow_offset = Vector2(1, 1)
	_knob.add_theme_stylebox_override("panel", ks)
	add_child(_knob)

	# Gloss highlight across the knob's top half (skeuomorphic sheen).
	_gloss = Panel.new()
	_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gloss.size = Vector2(_KNOB_W - 6, (_H - 2.0 * _MARGIN) * 0.5)
	_gloss.position = Vector2(3, 2)
	var gs := StyleBoxFlat.new()
	gs.bg_color = Color(1, 1, 1, 0.35)
	for k in ["corner_radius_top_left", "corner_radius_top_right"]:
		gs.set(k, _RADIUS - 3)
	_gloss.add_theme_stylebox_override("panel", gs)
	_knob.add_child(_gloss)

	_x_off = _MARGIN
	_x_on = _W - _KNOB_W - _MARGIN
	_refresh(initial_on)
	toggled.connect(func(on: bool) -> void: _refresh(on))


func _refresh(on: bool) -> void:
	_knob.position = Vector2(_x_on if on else _x_off, _MARGIN)
	if on:
		_label.text = "ON"
		_label.add_theme_color_override("font_color", Color.WHITE)
		_label.position = Vector2(2, 0)
		_label.size = Vector2(_x_on - 2, _H)
	else:
		_label.text = "OFF"
		_label.add_theme_color_override("font_color", Color(0.42, 0.43, 0.47))
		_label.position = Vector2(_KNOB_W + _MARGIN, 0)
		_label.size = Vector2(_W - _KNOB_W - _MARGIN - 2, _H)


func _track(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	for side in ["border_width_left", "border_width_right", "border_width_top", "border_width_bottom"]:
		s.set(side, 1)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		s.set(k, _RADIUS)
	for m in ["content_margin_left", "content_margin_right",
			  "content_margin_top", "content_margin_bottom"]:
		s.set(m, 0)
	return s
