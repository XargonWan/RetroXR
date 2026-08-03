class_name Haptics
extends RefCounted

## Rumble on a controller, via the XRTools rumble manager.
##
## The manager (an autoload) is the only thing in the project that should call
## XRServer.trigger_haptic_pulse — it scales by the user's haptics setting and
## arbitrates between events competing for the same tracker. These wrappers
## exist so no call site has to build an XRToolsRumbleEvent by hand.


## One-shot rumble of [param magnitude] (0-1) lasting [param ms].
static func pulse(ctrl: XRController3D, magnitude: float, ms: int,
		key: StringName = &"pulse") -> void:
	if not is_instance_valid(ctrl):
		return
	var event := XRToolsRumbleEvent.new()
	event.magnitude = magnitude
	event.duration_ms = ms
	XRToolsRumbleManager.add(key, event, [ctrl.tracker])


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
