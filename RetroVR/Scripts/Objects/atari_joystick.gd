## AtariJoystick — Atari CX40-style one-button joystick, on the shared
## DualShockController animation engine. One fire button and a digital 4-way
## stick, so only two moving parts.
##
## Model: imported "Atari Joystick (Antony)". Its meshes are named generically
## (object_001_low … object_007_low) rather than by function, so unlike the
## NES/SNES/PSX pads the mapping can't be read off the names — it was measured:
##
##   object_005_low  x[-0.008 +0.009] y[+0.049 +0.120]  tall shaft  -> the STICK
##   object_003_low  centred (0.030, 0.038, 0.027)      matches the
##                                                       FireButtonBottom marker
##
## The stick rocks about the "StickLeft" empty; the button sits on
## "FireButtonBottom". Everything else is shell.
class_name AtariJoystick
extends DualShockController

## The 2600's single fire button. Stella and friends read it as RetroPad B.
const FIRE_MESH := "object_003_low"
## The stick shaft, rocked like a d-pad.
const STICK_MESH := "object_005_low"

## A joystick shaft swings far further than a thumb pad rocks — the inherited 7°
## would be invisible on a 7 cm stick. (Named _THROW_ rather than STICK_TILT_DEG:
## the parent already defines that for analog sticks.)
const SHAFT_THROW_DEG := 20.0


func _dpad_tilt_deg() -> float:
	return SHAFT_THROW_DEG


func _cache_meshes() -> void:
	_buttons.clear()
	var fire: MeshInstance3D = _find_mesh(FIRE_MESH)
	if fire != null:
		_buttons.append({"node": fire, "rest": fire.transform,
			"bit": ControllerBindings.JOYPAD_B, "depth": FACE_PRESS})
	var stick: MeshInstance3D = _find_mesh(STICK_MESH)
	if stick != null:
		_dpad = {"node": stick, "rest": stick.transform,
			"pivot": _find_pivot(stick, "StickLeft")}
	print("[atari] cached %d buttons, stick=%s" % [_buttons.size(), not _dpad.is_empty()])
