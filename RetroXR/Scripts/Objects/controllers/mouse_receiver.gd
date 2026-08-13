## MouseReceiver — the real mouse, forwarded to the port it is plugged into.
##
## The virtual RetroMouse is a shell you slide across a surface in VR, and its
## deltas come from its own travel through the room. That is a lovely object and
## a poor pointing device: it needs a hand, a flat surface and your attention.
## This is the same port fed from the mouse already on your desk.
##
## Deltas are RELATIVE and per-frame, which is why they accumulate here and are
## drained on send rather than being polled like a held button. Buttons are read
## as state, so a button held across a frame boundary stays held.
##
## VR only — see the spawn menu. On desktop the real mouse IS the player:
## mouse-look is deliberately never gated, because turning is how the player drags
## the virtual mouse. Desktop keeps the held shell, untouched.
class_name MouseReceiver
extends InputReceiver

const RETRO_DEVICE_MOUSE := 2

const MOUSE_BTN_LEFT   := 1 << 0
const MOUSE_BTN_RIGHT  := 1 << 1
const MOUSE_BTN_MIDDLE := 1 << 2

## Motion since the last report, in mouse counts. Fractional carry is kept so a
## slow drag is not rounded away one frame at a time.
var _accum := Vector2.ZERO
var _carry := Vector2.ZERO
var _last_buttons := 0


func _ready() -> void:
	device_type = RETRO_DEVICE_MOUSE
	super._ready()


## The PS/2 plug the held RetroMouse wears, named from that class so the two cannot
## drift apart. The same connector whatever the machine: a keyboard is a
## keyboard, and only a pad takes the console's own moulding.
func connector_for(_sysid: String) -> String:
	return RetroMouse.PLUG_MESH


func receiver_glyph() -> String:
	return TransportGlyphs.glyph("bluetooth") + " " + TransportGlyphs.glyph("mouse")


## Nothing printed: the Bluetooth mark and the device symbol say it.
func case_text() -> String:
	return ""


func receiver_label() -> String:
	return "MOUSE"


## There is one mouse and it is always attached, so a seated receiver always has
## something to forward.
func is_bound() -> bool:
	return true


func on_going_idle() -> void:
	_accum = Vector2.ZERO
	_carry = Vector2.ZERO
	_last_buttons = 0


# ── Input ─────────────────────────────────────────────────────────────────────

## _input rather than _unhandled_input: motion is not something the UI consumes,
## and a menu panel under the pointer must not silently stop the game's mouse.
## Gathered even while unplugged is pointless, so the gate is here.
func _input(event: InputEvent) -> void:
	if not is_live():
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		_accum += motion.relative


func _process(_delta: float) -> void:
	if not is_live():
		return
	var move := _accum + _carry
	_accum = Vector2.ZERO
	var dx := int(move.x)
	var dy := int(move.y)
	_carry = move - Vector2(dx, dy)
	var buttons := _poll_buttons()

	# Netplay: mouse deltas ride the deterministic schedule through the same seam
	# as joypads — dx/dy packed into the analog-left slots. "drain": the session
	# zeroes them after the first scheduled frame consumes them, because a delta
	# is a per-frame quantity unlike held joypad state.
	if NetworkManager.netplay_route(_connected_system, _port_index,
			{"btn": buttons, "alx": dx, "aly": dy, "arx": 0, "ary": 0, "drain": true}):
		_last_buttons = buttons
		return

	if dx != 0 or dy != 0 or buttons != _last_buttons:
		_connected_system.get_libretro_node().SetMouseState(_port_index, dx, dy, buttons)
		_last_buttons = buttons


func _poll_buttons() -> int:
	var b := 0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		b |= MOUSE_BTN_LEFT
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		b |= MOUSE_BTN_RIGHT
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		b |= MOUSE_BTN_MIDDLE
	return b
