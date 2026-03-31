## DesktopBindings — save, load, and apply keyboard/mouse bindings for desktop mode.
##
## Bindings are stored in user://desktop_bindings.json as a flat dict of
## action_name → serialised InputEvent.  On load, each entry is applied to
## the live InputMap so all existing code that calls Input.is_action_pressed()
## or Input.get_axis() automatically picks up the user's preferences.
class_name DesktopBindings
extends RefCounted

const SAVE_PATH := "user://desktop_bindings.json"

## Gamepad button actions (joypad + trigger).
const JOYPAD_ACTIONS: Array = [
	"RETRO_JOYPAD_UP", "RETRO_JOYPAD_DOWN", "RETRO_JOYPAD_LEFT", "RETRO_JOYPAD_RIGHT",
	"RETRO_JOYPAD_A",  "RETRO_JOYPAD_B",    "RETRO_JOYPAD_X",    "RETRO_JOYPAD_Y",
	"RETRO_JOYPAD_L",  "RETRO_JOYPAD_R",    "RETRO_JOYPAD_L2",   "RETRO_JOYPAD_R2",
	"RETRO_JOYPAD_L3", "RETRO_JOYPAD_R3",   "RETRO_JOYPAD_SELECT","RETRO_JOYPAD_START",
	"trigger_left",
]

## Analog axis actions (each axis split into positive/negative actions).
const ANALOG_ACTIONS: Array = [
	"RETRO_ANALOG_LEFT_X_NEGATIVE",  "RETRO_ANALOG_LEFT_X_POSITIVE",
	"RETRO_ANALOG_LEFT_Y_NEGATIVE",  "RETRO_ANALOG_LEFT_Y_POSITIVE",
	"RETRO_ANALOG_RIGHT_X_NEGATIVE", "RETRO_ANALOG_RIGHT_X_POSITIVE",
	"RETRO_ANALOG_RIGHT_Y_NEGATIVE", "RETRO_ANALOG_RIGHT_Y_POSITIVE",
]

## Human-readable label for each action shown in the Controls UI.
const ACTION_LABELS: Dictionary = {
	"RETRO_JOYPAD_UP":     "D-pad Up",
	"RETRO_JOYPAD_DOWN":   "D-pad Down",
	"RETRO_JOYPAD_LEFT":   "D-pad Left",
	"RETRO_JOYPAD_RIGHT":  "D-pad Right",
	"RETRO_JOYPAD_A":      "A",
	"RETRO_JOYPAD_B":      "B",
	"RETRO_JOYPAD_X":      "X",
	"RETRO_JOYPAD_Y":      "Y",
	"RETRO_JOYPAD_L":      "L",
	"RETRO_JOYPAD_R":      "R",
	"RETRO_JOYPAD_L2":     "L2",
	"RETRO_JOYPAD_R2":     "R2",
	"RETRO_JOYPAD_L3":     "L3 (Click)",
	"RETRO_JOYPAD_R3":     "R3 (Click)",
	"RETRO_JOYPAD_SELECT": "Select",
	"RETRO_JOYPAD_START":  "Start",
	"trigger_left":        "Trigger / Shoot",
	"RETRO_ANALOG_LEFT_X_NEGATIVE":  "Left Stick \u2190",
	"RETRO_ANALOG_LEFT_X_POSITIVE":  "Left Stick \u2192",
	"RETRO_ANALOG_LEFT_Y_NEGATIVE":  "Left Stick \u2191",
	"RETRO_ANALOG_LEFT_Y_POSITIVE":  "Left Stick \u2193",
	"RETRO_ANALOG_RIGHT_X_NEGATIVE": "Right Stick \u2190",
	"RETRO_ANALOG_RIGHT_X_POSITIVE": "Right Stick \u2192",
	"RETRO_ANALOG_RIGHT_Y_NEGATIVE": "Right Stick \u2191",
	"RETRO_ANALOG_RIGHT_Y_POSITIVE": "Right Stick \u2193",
}


## Load saved bindings from disk and apply them to the live InputMap.
## Safe to call even if the file does not exist (does nothing in that case).
static func load_and_apply() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var text := FileAccess.get_file_as_string(SAVE_PATH)
	if text.is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_warning("DesktopBindings: failed to parse %s" % SAVE_PATH)
		return
	var data: Dictionary = parsed as Dictionary
	for action: String in data:
		if not InputMap.has_action(action):
			continue
		var ev := _dict_to_event(data[action] as Dictionary)
		if ev == null:
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, ev)


## Save the current InputMap state for all managed actions to disk.
static func save() -> void:
	var data: Dictionary = {}
	for action: String in JOYPAD_ACTIONS:
		_add_action_to_dict(data, action)
	for action: String in ANALOG_ACTIONS:
		_add_action_to_dict(data, action)
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("DesktopBindings: cannot write to %s (error %d)" % [SAVE_PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


static func _add_action_to_dict(data: Dictionary, action: String) -> void:
	if not InputMap.has_action(action):
		return
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return
	var d := _event_to_dict(events[0])
	if not d.is_empty():
		data[action] = d


## Returns a short human-readable string for the first binding of an action.
## E.g. "W", "LMB", "KP 2", "(none)".
static func event_display_name(action: String) -> String:
	if not InputMap.has_action(action):
		return "(none)"
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return "(none)"
	return _format_event(events[0])


static func _format_event(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var key := ev as InputEventKey
		var s := OS.get_keycode_string(key.physical_keycode)
		if s.is_empty():
			s = OS.get_keycode_string(key.keycode)
		return s if not s.is_empty() else "(key %d)" % key.physical_keycode
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT:   return "LMB"
			MOUSE_BUTTON_RIGHT:  return "RMB"
			MOUSE_BUTTON_MIDDLE: return "MMB"
			MOUSE_BUTTON_WHEEL_UP:   return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			var idx: return "MB%d" % idx
	return "?"


static func _event_to_dict(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		var key := ev as InputEventKey
		return {"type": "key", "physical_keycode": key.physical_keycode, "keycode": key.keycode}
	if ev is InputEventMouseButton:
		return {"type": "mouse", "button_index": (ev as InputEventMouseButton).button_index}
	return {}


static func _dict_to_event(d: Dictionary) -> InputEvent:
	match d.get("type", ""):
		"key":
			var ev := InputEventKey.new()
			ev.physical_keycode = int(d.get("physical_keycode", 0))
			ev.keycode          = int(d.get("keycode", 0))
			return ev
		"mouse":
			var ev := InputEventMouseButton.new()
			ev.button_index = int(d.get("button_index", MOUSE_BUTTON_LEFT))
			ev.pressed = true
			return ev
	return null
