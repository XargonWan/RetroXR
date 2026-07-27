## DualShockController — the PlayStation DualShock, on the shared
## AnimatedController engine. Four face buttons, L1/L2/R1/R2, Select/Start, a
## D-pad and two clickable analog sticks.
##
## The model is an author's "PlayStation Controller" bundle — separated named
## meshes: button_x/circle/square/triangle, button_l1/l2/r1/r2, button_select/
## start/analog, dpad, stick_left/right, Main, controller_screws. The D-pad and
## sticks rock about the bundled pivot empties shipped inside the .glb (Dpad /
## StickLeft / StickRight).
class_name DualShockController
extends AnimatedController

# Mesh-base-name -> RETRO_JOYPAD bit (PSX/RetroArch standard glyph mapping).
const FACE_BUTTONS: Dictionary = {
	"button_x":        ControllerBindings.JOYPAD_B,   # Cross
	"button_circle":   ControllerBindings.JOYPAD_A,   # Circle
	"button_square":   ControllerBindings.JOYPAD_Y,   # Square
	"button_triangle": ControllerBindings.JOYPAD_X,   # Triangle
	"button_l1":       ControllerBindings.JOYPAD_L,
	"button_r1":       ControllerBindings.JOYPAD_R,
	"button_select":   ControllerBindings.JOYPAD_SELECT,
	"button_start":    ControllerBindings.JOYPAD_START,
}
const TRIGGERS: Dictionary = {
	"button_l2": ControllerBindings.JOYPAD_L2,
	"button_r2": ControllerBindings.JOYPAD_R2,
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in FACE_BUTTONS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(FACE_BUTTONS[base]), "depth": FACE_PRESS})
	for base: String in TRIGGERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(TRIGGERS[base]), "depth": TRIGGER_PRESS})

	var dm: MeshInstance3D = _find_mesh("dpad")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "Dpad")}
	var sl: MeshInstance3D = _find_mesh("stick_left")
	if sl != null:
		_stick_l = {"node": sl, "rest": sl.transform, "pivot": _find_pivot(sl, "StickLeft")}
	var sr: MeshInstance3D = _find_mesh("stick_right")
	if sr != null:
		_stick_r = {"node": sr, "rest": sr.transform, "pivot": _find_pivot(sr, "StickRight")}

	print("[dualshock] cached %d buttons, dpad=%s lstick=%s rstick=%s"
		% [_buttons.size(), not _dpad.is_empty(), not _stick_l.is_empty(), not _stick_r.is_empty()])
