## PerfSparkline — the frame-time trace on the performance HUD.
##
## One bar per sampled frame, oldest at the left, with the frame budget drawn
## across as a line. A bar that MISSED is drawn in the warn colour, so a stutter
## is visible as a shape rather than as a number that has already scrolled past.
##
## Missing is not the same as reaching the budget line, which is why the colour
## rule and the line are not the same threshold. A frame keeping up with vsync
## lands on the budget every time, so jitter puts about half the bars a hair over
## it — coloured on that, a locked trace came out a red and green barcode with no
## stutter anywhere in it. The line still marks the deadline, because seeing how
## much room is left under it is the point of drawing it.
##
## The trace is handed in as the caller's ring buffer plus its write cursor
## rather than a rebuilt array: PerfHud samples every rendered frame and redraws
## four times a second, so copying 144 floats twenty times a second to draw them
## once would be the most expensive thing on the panel.
class_name PerfSparkline
extends Control

## Bars shorter than this still draw, so a run of fast frames reads as a floor
## rather than as a gap in the trace.
const MIN_BAR_PX := 1.0

## Head room above the budget line. The scale is budget * this, so the line sits
## at a fixed height and traces are comparable between sessions; anything taller
## is clipped to the top, which is exactly the "off the scale" reading wanted.
const SCALE_FACTOR := 2.2

var _samples: PackedFloat32Array = PackedFloat32Array()
var _cursor: int = 0
var _budget_ms: float = 13.9
var _miss_ms: float = 13.9

var color_ok := Color(0.45, 0.85, 0.45, 0.85)
var color_over := Color(0.95, 0.45, 0.35, 0.95)
## Drawn over the bars, so it has to beat a solid green fill — a dim slate line
## disappears into one completely.
var color_budget := Color(1.0, 1.0, 1.0, 0.75)
var color_bg := Color(0.05, 0.05, 0.10, 0.60)


## `samples` is the caller's ring, `cursor` the index the NEXT sample will be
## written to (so cursor is the oldest entry), `budget_ms` one refresh period,
## and `miss_ms` how long a frame has to take before it counts as missed. The
## caller owns that threshold — PerfHud grades its own rows against the same one.
func set_trace(samples: PackedFloat32Array, cursor: int, budget_ms: float,
		miss_ms: float) -> void:
	_samples = samples
	_cursor = cursor
	_budget_ms = maxf(budget_ms, 0.1)
	_miss_ms = maxf(miss_ms, _budget_ms)
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w <= 0.0 or h <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), color_bg)

	var count := _samples.size()
	if count == 0:
		return

	var scale_ms := _budget_ms * SCALE_FACTOR
	var bar_w := w / float(count)
	for i in range(count):
		# Oldest first: the ring's write cursor is the oldest entry.
		var ms := _samples[(_cursor + i) % count]
		if ms <= 0.0:
			continue
		var frac := clampf(ms / scale_ms, 0.0, 1.0)
		var bar_h := maxf(frac * h, MIN_BAR_PX)
		draw_rect(Rect2(i * bar_w, h - bar_h, maxf(bar_w - 0.5, 0.5), bar_h),
			color_over if ms > _miss_ms else color_ok)

	var budget_y := h - (h / SCALE_FACTOR)
	draw_line(Vector2(0.0, budget_y), Vector2(w, budget_y), color_budget, 1.0)
