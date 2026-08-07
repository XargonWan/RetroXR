class_name Haptics
extends RefCounted

## Rumble on a controller, via the XRTools rumble manager.
##
## The manager (an autoload) is the only thing in the project that should call
## XRServer.trigger_haptic_pulse — it scales by the user's haptics setting and
## arbitrates between events competing for the same tracker. These wrappers
## exist so no call site has to build an XRToolsRumbleEvent by hand.


## A control latching under the hand: a keycap bottoming out, a button firing.
## Release is softer than press, the way a real switch is.
##
## Both last a single frame, matching the addon's own tap_rumble. The manager
## drives the hardware for 0.1 s on EVERY frame an event is still alive, so
## duration_ms buys nothing but restarts: two frames is already 0.2 s, which
## reads as a buzz rather than a click and smears together at typing speed.
## Press and release are told apart by magnitude alone.
const CLICK_DOWN_MAGNITUDE := 0.5
const CLICK_DOWN_MS := 10
const CLICK_UP_MAGNITUDE := 0.2
const CLICK_UP_MS := 10


## One-shot rumble of [param magnitude] (0-1) lasting [param ms].
static func pulse(ctrl: XRController3D, magnitude: float, ms: int,
		key: StringName = &"pulse") -> void:
	if not is_instance_valid(ctrl):
		return
	var event := XRToolsRumbleEvent.new()
	event.magnitude = magnitude
	event.duration_ms = ms
	XRToolsRumbleManager.add(key, event, [ctrl.tracker])


## Tick for one press or release of a control. A null [param ctrl] is a no-op, so
## a call site may pass whatever hand it has without testing for one first.
static func click(ctrl: XRController3D, down: bool,
		key: StringName = &"click") -> void:
	pulse(ctrl, CLICK_DOWN_MAGNITUDE if down else CLICK_UP_MAGNITUDE,
		CLICK_DOWN_MS if down else CLICK_UP_MS, key)


## The controller driving [param node] — a pointer or pickup function, which the
## rig parents to its XRController3D. Null for anything with no controller behind
## it (the desktop reticle), which is exactly the case that must not rumble.
static func controller_of(node: Node) -> XRController3D:
	var n := node
	while n != null:
		if n is XRController3D:
			return n as XRController3D
		n = n.get_parent()
	return null


## Start (or retune) a rumble that runs until [method stop] is called.
##
## Re-calling with the same [param key] and a new magnitude is how a ramp is
## built — the manager replaces the event under that key. Every path that can
## end the gesture must call [method stop], or the controller rumbles forever.
static func hold(ctrl: XRController3D, magnitude: float, key: StringName) -> void:
	if not is_instance_valid(ctrl):
		return
	var event := XRToolsRumbleEvent.new()
	event.magnitude = magnitude
	event.indefinite = true
	XRToolsRumbleManager.add(key, event, [ctrl.tracker])


## Stop the rumble started by [method hold] under [param key].
static func stop(ctrl: XRController3D, key: StringName) -> void:
	if not is_instance_valid(ctrl):
		return
	XRToolsRumbleManager.clear(key, [ctrl.tracker])
