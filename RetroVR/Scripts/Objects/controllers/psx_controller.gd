## PsxController — the ORIGINAL PlayStation digital pad (SCPH-1080), i.e. the
## controller that shipped before the DualShock. It reuses DualShockController's
## animation engine (shared by all the imported pads) but is NOT a DualShock: it has
## the four face buttons, L1/L2/R1/R2, Select/Start and a D-pad — and no analog
## sticks (so no stick meshes are cached and no stick ever tilts).
##
## Model: imported "PSX Classic Controller (HighPoly)" bundle — separated named meshes
## FireButtonTop/Right/Left/Bottom (△ ○ □ ✕), LShoulderButton/RShoulderButton
## (L1/R1), LIndexTriggerButton/RIndexTriggerButton (L2/R2), SelectButton,
## StartButton and StickLeft22 (the D-pad, rocking about the "StickLeft" pivot).
class_name PsxController
extends DualShockController

# Mesh-base-name -> RETRO_JOYPAD bit (PSX/RetroArch standard glyph mapping,
# identical to the DualShock's — same face glyphs, just no sticks).
const PSX_FACE: Dictionary = {
	"FireButtonBottom": ControllerBindings.JOYPAD_B,   # Cross ✕
	"FireButtonRight":  ControllerBindings.JOYPAD_A,   # Circle ○
	"FireButtonLeft":   ControllerBindings.JOYPAD_Y,   # Square □
	"FireButtonTop":    ControllerBindings.JOYPAD_X,   # Triangle △
	"LShoulderButton":  ControllerBindings.JOYPAD_L,   # L1
	"RShoulderButton":  ControllerBindings.JOYPAD_R,   # R1
	"SelectButton":     ControllerBindings.JOYPAD_SELECT,
	"StartButton":      ControllerBindings.JOYPAD_START,
}
const PSX_TRIGGERS: Dictionary = {
	"LIndexTriggerButton": ControllerBindings.JOYPAD_L2,
	"RIndexTriggerButton": ControllerBindings.JOYPAD_R2,
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in PSX_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(PSX_FACE[base]), "depth": FACE_PRESS})
	for base: String in PSX_TRIGGERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(PSX_TRIGGERS[base]), "depth": TRIGGER_PRESS})
	# D-pad mesh "StickLeft22" (pivot empty "StickLeft"). No analog sticks on the
	# original digital pad, so _stick_l / _stick_r stay empty.
	var dm: MeshInstance3D = _find_mesh("StickLeft22")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "StickLeft")}
	print("[psx] cached %d buttons, dpad=%s" % [_buttons.size(), not _dpad.is_empty()])
