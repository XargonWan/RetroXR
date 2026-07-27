## SaturnController — Sega Saturn control pad.
##
## Same animation engine as every other pad (it is a thin subclass); only the mesh
## names and the button→RETRO_JOYPAD map differ. Layout: a D-pad, six face
## buttons in two arcs of three (X/Y/Z above A/B/C), L and R shoulder triggers,
## and START. No analog sticks — this is the digital pad, so _stick_l/_stick_r
## stay empty and the base class simply skips them.
##
## Model: an author's "Sega Saturn Controller" bundle. Its meshes carry the
## generic bundled slot names rather than the Saturn's own legend, and the slots do
## not line up with the letters at all — C is "RShoulderButton", Z is
## "LShoulderButton", and the real shoulder triggers are the "…IndexTrigger…"
## pair. The letters below were read off the albedo by sampling each button's
## top-face UV centroid, not guessed from the names.
##
## Bit map is Beetle Saturn's default: the A/B/C row on RetroPad Y/B/A (same as
## the Genesis pads) and the X/Y/Z row on L/X/R, with the physical triggers on
## L2/R2.
class_name SaturnController
extends AnimatedController

const SATURN_FACE: Dictionary = {
	"FireButtonBottom": ControllerBindings.JOYPAD_Y,   # A
	"FireButtonRight":  ControllerBindings.JOYPAD_B,   # B
	"RShoulderButton":  ControllerBindings.JOYPAD_A,   # C
	"FireButtonLeft":   ControllerBindings.JOYPAD_L,   # X
	"FireButtonTop":    ControllerBindings.JOYPAD_X,   # Y
	"LShoulderButton":  ControllerBindings.JOYPAD_R,   # Z
	"StartButton":      ControllerBindings.JOYPAD_START,
}
## The real L/R triggers, on the pad's leading edge.
const SATURN_TRIGGERS: Dictionary = {
	"LIndexTriggerButton": ControllerBindings.JOYPAD_L2,
	"RIndexTriggerButton": ControllerBindings.JOYPAD_R2,
}
## A trigger sits on the sloped leading edge, so it travels back-and-down into
## that face. Pressed along the default straight-down PRESS_DIR it would slide
## along the outside of the shell instead of sinking into it.
const TRIGGER_DIR: Vector3 = Vector3(0.0, -0.707, 0.707)

const SATURN_DPAD := "StickLeft1"
const SATURN_DPAD_PIVOT := "StickLeft"


func _ready() -> void:
	super._ready()
	# The single shell material ships metallicFactor 0.66 with no metallic map,
	# which renders matte grey ABS as brushed steel.
	var model := get_node_or_null("Model")
	if model != null:
		ModelMaterialFix.demetal(model)


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in SATURN_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform,
				"bit": int(SATURN_FACE[base]), "depth": FACE_PRESS})
	for base: String in SATURN_TRIGGERS:
		var t: MeshInstance3D = _find_mesh(base)
		if t != null:
			_buttons.append({"node": t, "rest": t.transform,
				"bit": int(SATURN_TRIGGERS[base]), "depth": TRIGGER_PRESS,
				"dir": TRIGGER_DIR})
	var dm: MeshInstance3D = _find_mesh(SATURN_DPAD)
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, SATURN_DPAD_PIVOT)}
	print("[saturn] cached %d buttons, dpad=%s" % [_buttons.size(), not _dpad.is_empty()])
