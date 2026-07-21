## GamecubeController — GameCube pad variant of DualShockController.
## Same animation engine (inherited); only the mesh names and button→RETRO_JOYPAD
## bit map differ. Layout: A/B/X/Y + Z + Start, one Analog stick + a C-stick,
## L/R analog triggers, and a D-pad. Bit map follows RetroArch's usual
## GameCube→RetroPad layout (implementer's choice; tune in-headset).
class_name GamecubeController
extends DualShockController

const GC_FACE: Dictionary = {
	"A Button": ControllerBindings.JOYPAD_A,
	"B Button": ControllerBindings.JOYPAD_B,
	"X Button": ControllerBindings.JOYPAD_X,
	"Y Button": ControllerBindings.JOYPAD_Y,
	"Z Button": ControllerBindings.JOYPAD_R,
	"Start":    ControllerBindings.JOYPAD_START,
}
const GC_TRIGGERS: Dictionary = {
	"L Trigger": ControllerBindings.JOYPAD_L2,
	"R Trigger": ControllerBindings.JOYPAD_R2,
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in GC_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(GC_FACE[base]), "depth": FACE_PRESS})
	for base: String in GC_TRIGGERS:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(GC_TRIGGERS[base]), "depth": TRIGGER_PRESS})
	var dm: MeshInstance3D = _find_mesh("Dpad")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "Dpad")}
	var sl: MeshInstance3D = _find_mesh("Analog")
	if sl != null:
		_stick_l = {"node": sl, "rest": sl.transform, "pivot": _find_pivot(sl, "Analog")}
	var sr: MeshInstance3D = _find_mesh("Cstick")
	if sr != null:
		_stick_r = {"node": sr, "rest": sr.transform, "pivot": _find_pivot(sr, "Cstick")}
	print("[gamecube] cached %d buttons, dpad=%s lstick=%s rstick=%s"
		% [_buttons.size(), not _dpad.is_empty(), not _stick_l.is_empty(), not _stick_r.is_empty()])
