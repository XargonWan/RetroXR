## MarqueeButton — a Button whose label scrolls horizontally (marquee) when the
## text is too long to fit, instead of widening the button and pushing sibling
## controls off the row. The button's own text stays empty and clip_text pins its
## minimum width to zero; a child Label overlays the content and slides back and
## forth only while it overflows. Use for list rows where a fixed-width clickable
## button must show a variable-length title (e.g. the Cartridges game list).
class_name MarqueeButton
extends Button

const _SPEED := 45.0        # px/sec scroll speed
const _EDGE_PAUSE := 1.2    # seconds paused at each end before reversing
const _PAD_X := 14.0        # left/right inset for the text

var _label: Label = null
var _dir := -1.0            # -1 scroll left (reveal end), +1 scroll right
var _pause := _EDGE_PAUSE
var _off := 0.0


## Factory mirroring VRDropdown/VRToggle: build a ready-to-use marquee button.
static func create(label_text: String, font_size: int) -> MarqueeButton:
	var b := MarqueeButton.new()
	b.add_theme_font_size_override("font_size", font_size)
	b._label.add_theme_font_size_override("font_size", font_size)
	b.set_marquee_text(label_text)
	return b


func _init() -> void:
	clip_text = true          # keep the button's own (empty) text from setting a min width
	clip_contents = true      # clip the overlay label to the button rect
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # clicks fall through to the button
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	add_child(_label)
	set_process(false)


func set_marquee_text(t: String) -> void:
	_label.text = t
	_reset_marquee()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_reset_marquee()


func _reset_marquee() -> void:
	_off = 0.0
	_dir = -1.0
	_pause = _EDGE_PAUSE
	_label.size = Vector2(_label.get_minimum_size().x, size.y)
	_label.position = Vector2(_PAD_X, 0)
	set_process(_overflow() > 0.0)


## Pixels the label runs past the visible (inset) width; 0 when it fits.
func _overflow() -> float:
	return maxf(0.0, _label.size.x - (size.x - _PAD_X * 2.0))


func _process(delta: float) -> void:
	var over := _overflow()
	if over <= 0.0:
		_label.position.x = _PAD_X
		set_process(false)
		return
	if _pause > 0.0:
		_pause -= delta
		return
	_off += _dir * _SPEED * delta
	if _off <= -over:
		_off = -over
		_dir = 1.0
		_pause = _EDGE_PAUSE
	elif _off >= 0.0:
		_off = 0.0
		_dir = -1.0
		_pause = _EDGE_PAUSE
	_label.position.x = _PAD_X + _off
