## TouchSmoother — tremor filter for a fingertip dragging on a flat surface,
## shared by the handheld's own touch pad and a TV showing its BOTTOM channel.
##
## Works on the in-plane point in SURFACE-LOCAL METRES, deliberately not in UV.
## Two reasons: physical tremor is a property of the HAND, so the deadzone should
## not shrink because a TV is bigger than a DS; and a cached local point stays
## valid even if the device is yanked out of your finger between frames, which is
## what makes the lift-off fix below safe.
##
## Three jobs:
##   • deadzone   — sub-millimetre wobble does not move the stylus at all
##   • smoothing  — what is left is followed exponentially, not stepped
##   • FREEZE     — while `live` is false the last good point is returned
##     unchanged. That is the lift-off fix: the release used to be reported at
##     the tip's current position, which is by definition outside the screen, so
##     clamping pinned it to the border and every lift-off became a small swipe
##     toward the edge. Sliding out sideways had the same problem.
class_name TouchSmoother
extends RefCounted

## Ignored movement, in metres on the glass. Under the headset's own tracking
## jitter, and about 2.8 px of a DS's 256 px-wide bottom screen — below one
## perceived step, so a deliberate stroke loses nothing.
const DEADZONE := 0.0007
## Exponential follow rate, via the house clampf(K * delta, 0, 1) idiom. Steady
## lag is roughly speed / LERP, so a brisk 0.1 m/s drag trails by ~3.3 mm.
const LERP := 30.0

var _target := Vector2.ZERO
var _smoothed := Vector2.ZERO


## Seed a fresh press. Both halves are set, so a new tap starts exactly where it
## landed instead of sweeping in from wherever the previous one ended.
func begin(p: Vector2) -> void:
	_target = p
	_smoothed = p


func reset() -> void:
	_target = Vector2.ZERO
	_smoothed = Vector2.ZERO


## `live` = the tip is inside the CORE window. Pass false while it is only in the
## release-slack band (lifting off, or sliding past an edge) and the last
## in-window point comes back untouched.
func point(raw: Vector2, live: bool, delta: float) -> Vector2:
	if not live:
		return _smoothed
	# Soft deadzone: subtract it from the movement rather than gating on it, or
	# crossing the threshold would jump by a whole deadzone.
	var d: Vector2 = raw - _target
	var m: float = d.length()
	if m > DEADZONE:
		_target += d * ((m - DEADZONE) / m)
	_smoothed = _smoothed.lerp(_target, clampf(LERP * delta, 0.0, 1.0))
	return _smoothed


## The point last reported, without advancing anything.
func current() -> Vector2:
	return _smoothed
