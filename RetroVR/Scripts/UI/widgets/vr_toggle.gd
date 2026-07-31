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
	# Don't let a taller menu row stretch the switch (which left the knob short).
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
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

	# Raised knob — anchored so it always fills the track height (minus a small
	# inset), sliding left/right in _refresh.
	_knob = Panel.new()
	_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	_gloss.anchor_left = 0.0; _gloss.anchor_right = 1.0
	_gloss.anchor_top = 0.0; _gloss.anchor_bottom = 0.5
	_gloss.offset_left = 3; _gloss.offset_right = -3
	_gloss.offset_top = 2; _gloss.offset_bottom = 0
	var gs := StyleBoxFlat.new()
	gs.bg_color = Color(1, 1, 1, 0.35)
	for k in ["corner_radius_top_left", "corner_radius_top_right"]:
		gs.set(k, _RADIUS - 3)
	_gloss.add_theme_stylebox_override("panel", gs)
	_knob.add_child(_gloss)

	_refresh(initial_on)
	toggled.connect(func(on: bool) -> void: _refresh(on))


func _refresh(on: bool) -> void:
	# Knob fills the full track height (minus inset) and sits on one side.
	_knob.anchor_top = 0.0
	_knob.anchor_bottom = 1.0
	_knob.offset_top = _MARGIN
	_knob.offset_bottom = -_MARGIN
	# Label fills the full height so the text is vertically centered too.
	_label.anchor_top = 0.0
	_label.anchor_bottom = 1.0
	_label.offset_top = 0
	_label.offset_bottom = 0
	if on:
		# Knob on the right; "ON" centered in the left (blue) area.
		_knob.anchor_left = 1.0
		_knob.anchor_right = 1.0
		_knob.offset_left = -(_KNOB_W + _MARGIN)
		_knob.offset_right = -_MARGIN
		_label.text = "ON"
		_label.add_theme_color_override("font_color", Color.WHITE)
		_label.anchor_left = 0.0
		_label.anchor_right = 1.0
		_label.offset_left = 0
		_label.offset_right = -(_KNOB_W + _MARGIN)
	else:
		# Knob on the left; "OFF" centered in the right (gray) area.
		_knob.anchor_left = 0.0
		_knob.anchor_right = 0.0
		_knob.offset_left = _MARGIN
		_knob.offset_right = _MARGIN + _KNOB_W
		_label.text = "OFF"
		_label.add_theme_color_override("font_color", Color(0.42, 0.43, 0.47))
		_label.anchor_left = 0.0
		_label.anchor_right = 1.0
		_label.offset_left = _KNOB_W + _MARGIN
		_label.offset_right = 0


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
