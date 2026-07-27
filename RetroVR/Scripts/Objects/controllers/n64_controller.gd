## N64Controller — Nintendo 64 pad variant of AnimatedController.
## Same animation engine (inherited); only the mesh names and button→RETRO_JOYPAD
## bit map differ. Layout: A / B, Start, four yellow C-buttons, L / R shoulder +
## Z trigger, one analog stick and a D-pad. The C-buttons have no dedicated
## RetroPad bits, so they borrow X / Y / SELECT / R2 — the whole map is the
## implementer's choice (tune in-headset), same as the GameCube variant.
##
## Model: an author's "N64 Controller (Anim)" bundle — separated named meshes:
## FireButtonBottom (A), FireButtonLeft (B), StartButton, YellowUp/Down/Left/Right
## (C-buttons), LIndexTriggerButton (L), RShoulderButton (R), RIndexTriggerButton
## (Z), StickDpad2 (D-pad, pivot "Dpad") and StickLeft1 (analog, pivot "StickLeft").
class_name N64Controller
extends AnimatedController

const N64_FACE: Dictionary = {
	"FireButtonBottom": ControllerBindings.JOYPAD_A,       # A
	"FireButtonLeft":   ControllerBindings.JOYPAD_B,       # B
	"StartButton":      ControllerBindings.JOYPAD_START,
	"YellowUp":         ControllerBindings.JOYPAD_X,        # C-Up
	"YellowDown":       ControllerBindings.JOYPAD_Y,        # C-Down
	"YellowLeft":       ControllerBindings.JOYPAD_SELECT,   # C-Left
	"YellowRight":      ControllerBindings.JOYPAD_R2,       # C-Right
}
const N64_TRIGGERS: Dictionary = {
	"LIndexTriggerButton": ControllerBindings.JOYPAD_L,
	"RShoulderButton":     ControllerBindings.JOYPAD_R,
	"RIndexTriggerButton": ControllerBindings.JOYPAD_L2,    # Z trigger
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in N64_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(N64_FACE[base]), "depth": FACE_PRESS})
	for base: String in N64_TRIGGERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(N64_TRIGGERS[base]), "depth": TRIGGER_PRESS})
	# D-pad mesh "StickDpad2" (pivot "Dpad"); the single analog stick is "StickLeft1"
	# (pivot "StickLeft"). The N64 has no right stick.
	var dm: MeshInstance3D = _find_mesh("StickDpad2")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "Dpad")}
	var sl: MeshInstance3D = _find_mesh("StickLeft1")
	if sl != null:
		_stick_l = {"node": sl, "rest": sl.transform, "pivot": _find_pivot(sl, "StickLeft")}
	print("[n64] cached %d buttons, dpad=%s lstick=%s"
		% [_buttons.size(), not _dpad.is_empty(), not _stick_l.is_empty()])
