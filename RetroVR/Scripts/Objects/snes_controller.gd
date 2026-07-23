## SnesController — SNES pad variant of DualShockController.
## Same animation engine (inherited); only the mesh names and button→RETRO_JOYPAD
## bit map differ. SNES layout: a diamond of B/A/Y/X, L/R shoulders,
## Select/Start and a D-pad (no analog sticks).
##
## Model: an author's imported "SNES GamePad" bundle — PAL/Super Famicom styling with the
## coloured convex buttons. Every control is already its own mesh
## (FireButton*, LShoulderButton, RShoulderButton, Select/StartButton and
## StickLeft22 for the D-pad), so no mesh splitting was needed.
class_name SnesController
extends DualShockController

# Mesh-base-name -> RETRO_JOYPAD bit. The GLB names the diamond by POSITION, so
# map through the SNES face layout: bottom=B, right=A, left=Y, top=X — which is
# exactly the RetroPad convention (RetroPad's glyph positions ARE the SNES pad's).
const SNES_FACE: Dictionary = {
	"FireButtonBottom": ControllerBindings.JOYPAD_B,
	"FireButtonRight":  ControllerBindings.JOYPAD_A,
	"FireButtonLeft":   ControllerBindings.JOYPAD_Y,
	"FireButtonTop":    ControllerBindings.JOYPAD_X,
	"SelectButton":     ControllerBindings.JOYPAD_SELECT,
	"StartButton":      ControllerBindings.JOYPAD_START,
}

# Shoulders travel further than a face button, like the DualShock's triggers.
const SNES_SHOULDERS: Dictionary = {
	"LShoulderButton": ControllerBindings.JOYPAD_L,
	"RShoulderButton": ControllerBindings.JOYPAD_R,
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in SNES_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform,
				"bit": int(SNES_FACE[base]), "depth": FACE_PRESS})
	for base: String in SNES_SHOULDERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform,
				"bit": int(SNES_SHOULDERS[base]), "depth": TRIGGER_PRESS})
	# Same D-pad naming as the NES pad: mesh "StickLeft22", pivot empty "StickLeft".
	var dm: MeshInstance3D = _find_mesh("StickLeft22")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "StickLeft")}
	print("[snes] cached %d buttons, dpad=%s" % [_buttons.size(), not _dpad.is_empty()])
