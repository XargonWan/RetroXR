## GamepadBindings — physical gamepad (Xbox / 8BitDo / any HID pad) remapping.
##
## Mirrors ControllerBindings, but for real joypads read directly through the
## Godot Input singleton (Input.is_joy_button_pressed / get_joy_axis) rather than
## InputMap actions. Bindings are stored in user://gamepad_bindings.json and merged
## default → global (per-system layer intentionally left open for later).
##
## Every connected pad is merged into a single virtual RetroPad (buttons OR'd,
## largest-magnitude stick wins) — RetroController.poll() feeds this into the held
## controller's port alongside VR/keyboard input.
class_name GamepadBindings
extends RefCounted

const SAVE_PATH := "user://gamepad_bindings.json"

# ── Tunables ──────────────────────────────────────────────────────────────────
const DEADZONE          := 0.15     # radial stick deadzone
const TRIGGER_THRESHOLD := 0.5      # axis magnitude to count a button-bound axis as pressed
const DPAD_THRESHOLD    := 0.35     # stick magnitude to fire a d-pad direction
const ANALOG_SCALE      := 0x7fff   # libretro analog full-scale

## When true (during rebind capture), poll() returns neutral so the captured
## press does not simultaneously drive a running game.
static var suspend_polling: bool = false

# ── RetroPad targets ──────────────────────────────────────────────────────────
## Ordered so index == RETRO_DEVICE_ID_JOYPAD bit (matches ControllerBindings.JOYPAD_*).
const TARGET_ORDER: Array = [
	"b", "y", "select", "start", "up", "down", "left", "right",
	"a", "x", "l", "r", "l2", "r2", "l3", "r3",
]

## RetroPad target → UI label.
const TARGET_LABELS: Dictionary = {
	"b": "B", "y": "Y", "select": "Select", "start": "Start",
	"up": "D-Up", "down": "D-Down", "left": "D-Left", "right": "D-Right",
	"a": "A", "x": "X", "l": "L", "r": "R",
	"l2": "L2", "r2": "R2", "l3": "L3", "r3": "R3",
}

# ── Binding encoding ──────────────────────────────────────────────────────────
# A binding is a string:
#   "btn:<JoyButton index>"        → Input.is_joy_button_pressed
#   "axis:<JoyAxis index>:<+|->"   → signed Input.get_joy_axis past ±TRIGGER_THRESHOLD
#   "none"                         → unbound

## Xbox/SDL button index → display name (physical position, not RetroPad role).
const JOY_BUTTON_NAMES: Dictionary = {
	0: "A (bottom)", 1: "B (right)", 2: "X (left)", 3: "Y (top)",
	4: "Back", 5: "Guide", 6: "Start",
	7: "L-Stick", 8: "R-Stick", 9: "LB", 10: "RB",
	11: "D-Up", 12: "D-Down", 13: "D-Left", 14: "D-Right",
}

## Xbox/SDL axis index → display name.
const JOY_AXIS_NAMES: Dictionary = {
	0: "LS-X", 1: "LS-Y", 2: "RS-X", 3: "RS-Y", 4: "LT", 5: "RT",
}

## Default map: standard libretro positional convention for an Xbox-layout pad.
## Xbox A(bottom)→B, B(right)→A, X(left)→Y, Y(top)→X.
const DEFAULT_BUTTON_MAP: Dictionary = {
	"b":      "btn:0",     # Xbox A (bottom)
	"a":      "btn:1",     # Xbox B (right)
	"y":      "btn:2",     # Xbox X (left)
	"x":      "btn:3",     # Xbox Y (top)
	"select": "btn:4",     # Back
	"start":  "btn:6",     # Start
	"l3":     "btn:7",     # Left-stick click
	"r3":     "btn:8",     # Right-stick click
	"l":      "btn:9",     # LB
	"r":      "btn:10",    # RB
	"up":     "btn:11",    # D-pad up
	"down":   "btn:12",    # D-pad down
	"left":   "btn:13",    # D-pad left
	"right":  "btn:14",    # D-pad right
	"l2":     "axis:4:+",  # Left trigger
	"r2":     "axis:5:+",  # Right trigger
}

## Default stick routing. Left stick doubles as the d-pad so single-stick
## retro cores (NES/SNES) work out of the box.
const DEFAULT_STICK_MAP: Dictionary = {
	"stick_left":  "left+dpad",
	"stick_right": "right",
}

# ── File I/O ──────────────────────────────────────────────────────────────────

static func _load_file() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var result: Variant = JSON.parse_string(text)
	if result is Dictionary:
		return result
	return {}


static func _save_file(data: Dictionary) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("GamepadBindings: cannot write to %s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

# ── Public API ────────────────────────────────────────────────────────────────

## Save global (fallback) gamepad bindings.
static func save_global(button_map: Dictionary, stick_map: Dictionary) -> void:
	var data := _load_file()
	if not data.has("global"):
		data["global"] = {}
	data["global"]["buttons"] = button_map
	data["global"]["sticks"] = stick_map
	_save_file(data)


## Merged global bindings (global overrides of defaults). Keys "buttons", "sticks".
static func get_global() -> Dictionary:
	var data := _load_file()
	var global_data: Dictionary = data.get("global", {}) as Dictionary
	return {
		"buttons": _merge(DEFAULT_BUTTON_MAP, global_data.get("buttons", {})),
		"sticks":  _merge(DEFAULT_STICK_MAP,  global_data.get("sticks",  {})),
	}


## Encode a captured joypad InputEvent into a binding string ("" if unsupported).
static func encode_event(event: InputEvent) -> String:
	if event is InputEventJoypadButton:
		return "btn:%d" % (event as InputEventJoypadButton).button_index
	if event is InputEventJoypadMotion:
		var m := event as InputEventJoypadMotion
		return "axis:%d:%s" % [m.axis, "+" if m.axis_value >= 0.0 else "-"]
	return ""


## Human-readable label for a binding string, for the remap UI.
static func binding_display_name(binding: String) -> String:
	if binding == "none" or binding.is_empty():
		return "(none)"
	if binding.begins_with("btn:"):
		var idx := binding.substr(4).to_int()
		return JOY_BUTTON_NAMES.get(idx, "Btn %d" % idx)
	if binding.begins_with("axis:"):
		var parts := binding.split(":")
		if parts.size() < 3:
			return binding
		var axis := parts[1].to_int()
		var axis_name: String = JOY_AXIS_NAMES.get(axis, "Axis %d" % axis)
		if axis == JOY_AXIS_TRIGGER_LEFT or axis == JOY_AXIS_TRIGGER_RIGHT:
			return axis_name   # triggers are one-directional
		return "%s %s" % [axis_name, "+" if parts[2] == "+" else "−"]
	return binding


## Poll every connected pad, merge, and return libretro-convention state:
## {btn, alx, aly, arx, ary}. Y is positive-down (no negation — joypad axes
## already match libretro's convention, unlike VR sticks).
static func poll(button_map: Dictionary, stick_map: Dictionary) -> Dictionary:
	var zero := {"btn": 0, "alx": 0, "aly": 0, "arx": 0, "ary": 0}
	if suspend_polling:
		return zero
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return zero

	# Buttons: OR each RetroPad target across all connected pads.
	var btn := 0
	for i: int in TARGET_ORDER.size():
		var binding: String = button_map.get(TARGET_ORDER[i], "none")
		if binding == "none" or binding.is_empty():
			continue
		for device: int in pads:
			if _binding_active(binding, device):
				btn |= (1 << i)
				break

	# Sticks: largest-magnitude vector per stick across pads (deadzoned).
	var left_vec := Vector2.ZERO
	var right_vec := Vector2.ZERO
	for device: int in pads:
		var lv := Vector2(Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
						  Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
		if lv.length() < DEADZONE:
			lv = Vector2.ZERO
		if lv.length_squared() > left_vec.length_squared():
			left_vec = lv
		var rv := Vector2(Input.get_joy_axis(device, JOY_AXIS_RIGHT_X),
						  Input.get_joy_axis(device, JOY_AXIS_RIGHT_Y))
		if rv.length() < DEADZONE:
			rv = Vector2.ZERO
		if rv.length_squared() > right_vec.length_squared():
			right_vec = rv

	# Route sticks through the map. Mirrors retro_controller._process ordering:
	# left assigns first, then right may overwrite an analog target.
	var alx := 0
	var aly := 0
	var arx := 0
	var ary := 0
	var lt: String = stick_map.get("stick_left", "left+dpad")
	var rt: String = stick_map.get("stick_right", "right")

	if "left" in lt:
		alx = int(left_vec.x * ANALOG_SCALE); aly = int(left_vec.y * ANALOG_SCALE)
	elif "right" in lt:
		arx = int(left_vec.x * ANALOG_SCALE); ary = int(left_vec.y * ANALOG_SCALE)
	if "dpad" in lt:
		btn |= _stick_to_dpad(left_vec)

	if "right" in rt:
		arx = int(right_vec.x * ANALOG_SCALE); ary = int(right_vec.y * ANALOG_SCALE)
	elif "left" in rt:
		alx = int(right_vec.x * ANALOG_SCALE); aly = int(right_vec.y * ANALOG_SCALE)
	if "dpad" in rt:
		btn |= _stick_to_dpad(right_vec)

	return {"btn": btn, "alx": alx, "aly": aly, "arx": arx, "ary": ary}

# ── Helpers ───────────────────────────────────────────────────────────────────

## Is the given binding currently active on the given device?
static func _binding_active(binding: String, device: int) -> bool:
	if binding.begins_with("btn:"):
		var idx := binding.substr(4).to_int()
		return Input.is_joy_button_pressed(device, idx as JoyButton)
	if binding.begins_with("axis:"):
		var parts := binding.split(":")
		if parts.size() < 3:
			return false
		var val := Input.get_joy_axis(device, parts[1].to_int() as JoyAxis)
		if parts[2] == "+":
			return val > TRIGGER_THRESHOLD
		return val < -TRIGGER_THRESHOLD
	return false


## Convert a stick vector to RetroPad d-pad bits (joy convention: +Y = down).
static func _stick_to_dpad(v: Vector2) -> int:
	var bits := 0
	if v.y < -DPAD_THRESHOLD: bits |= (1 << 4)   # UP
	if v.y >  DPAD_THRESHOLD: bits |= (1 << 5)   # DOWN
	if v.x < -DPAD_THRESHOLD: bits |= (1 << 6)   # LEFT
	if v.x >  DPAD_THRESHOLD: bits |= (1 << 7)   # RIGHT
	return bits


## Apply base then overlay (last writer wins). Returns a new dictionary.
static func _merge(base: Dictionary, overlay: Dictionary) -> Dictionary:
	var result := base.duplicate()
	for k: String in overlay:
		result[k] = overlay[k]
	return result
