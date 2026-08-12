## SevenSegmentDisplay — a Control that renders a string as a classic 7-segment
## digital readout (lit segments plus dim "ghost" segments for authenticity).
## Supports digits 0-9, ':' (colon), '/' (slash) and ' ' (space) and '-' (dash).
## Meant to live inside a SubViewport whose texture is mapped onto the VCR's
## front-panel quad.
class_name SevenSegmentDisplay
extends Control

## The text to render, e.g. "00:00:12 / 00:00:30".
@export var text: String = "00:00:00 / 00:00:00": set = _set_text

## Colours for lit and unlit (ghost) segments, plus the panel background.
@export var lit_color: Color = Color(1.0, 0.45, 0.06)
@export var dim_color: Color = Color(0.16, 0.07, 0.02)
@export var bg_color: Color  = Color(0.02, 0.02, 0.025)

## Per-digit geometry (in viewport pixels). The whole string is uniformly scaled
## down at draw time if it would otherwise exceed the control size minus margin,
## so it never clips regardless of viewport dimensions.
@export var digit_w: float = 34.0
@export var digit_h: float = 62.0
@export var seg_t: float   = 7.0
@export var gap: float     = 10.0
@export var margin: float  = 14.0

# Segment order: a(top) b(top-right) c(bottom-right) d(bottom) e(bottom-left)
# f(top-left) g(middle).
const SEG := {
	"0": [1, 1, 1, 1, 1, 1, 0],
	"1": [0, 1, 1, 0, 0, 0, 0],
	"2": [1, 1, 0, 1, 1, 0, 1],
	"3": [1, 1, 1, 1, 0, 0, 1],
	"4": [0, 1, 1, 0, 0, 1, 1],
	"5": [1, 0, 1, 1, 0, 1, 1],
	"6": [1, 0, 1, 1, 1, 1, 1],
	"7": [1, 1, 1, 0, 0, 0, 0],
	"8": [1, 1, 1, 1, 1, 1, 1],
	"9": [1, 1, 1, 1, 0, 1, 1],
	"-": [0, 0, 0, 0, 0, 0, 1],
}


func _set_text(t: String) -> void:
	text = t
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), bg_color, true)
	# Uniformly scale the layout so it fits inside the control minus margin.
	var nat_w := _measure(text, digit_w, gap)
	var avail_w := maxf(1.0, size.x - margin * 2.0)
	var avail_h := maxf(1.0, size.y - margin * 2.0)
	var s := minf(1.0, minf(avail_w / nat_w, avail_h / digit_h))
	var dw := digit_w * s
	var dh := digit_h * s
	var t := seg_t * s
	var g := gap * s

	var x := (size.x - _measure(text, dw, g)) * 0.5
	var y := (size.y - dh) * 0.5
	for i in text.length():
		var ch := text[i]
		match ch:
			":":
				_draw_colon(x, y, dw, dh, t)
				x += dw * 0.45 + g
			"/":
				_draw_slash(x, y, dw, dh, t)
				x += dw + g
			" ":
				x += dw * 0.5 + g
			_:
				_draw_digit(ch, x, y, dw, dh, t)
				x += dw + g


func _measure(s: String, dw: float, g: float) -> float:
	var w := 0.0
	for i in s.length():
		match s[i]:
			":": w += dw * 0.45 + g
			"/": w += dw + g
			" ": w += dw * 0.5 + g
			_:   w += dw + g
	return maxf(1.0, w - g)


func _draw_digit(ch: String, cx: float, cy: float, W: float, H: float, T: float) -> void:
	var segs: Array = SEG.get(ch, [0, 0, 0, 0, 0, 0, 0])
	var half := (H - T) * 0.5
	# Horizontal segments: a, g, d
	_seg(Rect2(cx + T * 0.5, cy,               W - T, T), segs[0])
	_seg(Rect2(cx + T * 0.5, cy + half,        W - T, T), segs[6])
	_seg(Rect2(cx + T * 0.5, cy + H - T,       W - T, T), segs[3])
	# Vertical segments: f, b (upper), e, c (lower)
	var vlen := half - T * 0.5
	_seg(Rect2(cx,           cy + T * 0.5,        T, vlen), segs[5])
	_seg(Rect2(cx + W - T,   cy + T * 0.5,        T, vlen), segs[1])
	_seg(Rect2(cx,           cy + half + T * 0.5, T, vlen), segs[4])
	_seg(Rect2(cx + W - T,   cy + half + T * 0.5, T, vlen), segs[2])


func _seg(rect: Rect2, on: int) -> void:
	draw_rect(rect, lit_color if on == 1 else dim_color, true)


func _draw_colon(cx: float, cy: float, W: float, H: float, T: float) -> void:
	var cw := W * 0.45
	var px := cx + (cw - T) * 0.5
	draw_rect(Rect2(px, cy + H * 0.30, T, T), lit_color, true)
	draw_rect(Rect2(px, cy + H * 0.62, T, T), lit_color, true)


func _draw_slash(cx: float, cy: float, W: float, H: float, T: float) -> void:
	draw_line(Vector2(cx, cy + H), Vector2(cx + W, cy), lit_color, T)
