## NesController — NES pad variant of DualShockController.
## Same animation engine (inherited); only the mesh names and button→RETRO_JOYPAD
## bit map differ. NES layout: A / B + Select / Start + a D-pad (no analog sticks).
##
## Model: an author's imported "NES Controller (Anim)" bundle — separated named meshes
## FireButtonRight (A), FireButtonBottom (B), SelectButton, StartButton and
## StickLeft22 (the D-pad, rocking about the "StickLeft" pivot empty).
class_name NesController
extends DualShockController

# Mesh-base-name -> RETRO_JOYPAD bit (standard NES→RetroPad glyph mapping).
const NES_FACE: Dictionary = {
	"FireButtonRight":  ControllerBindings.JOYPAD_A,
	"FireButtonBottom": ControllerBindings.JOYPAD_B,
	"SelectButton":     ControllerBindings.JOYPAD_SELECT,
	"StartButton":      ControllerBindings.JOYPAD_START,
}


func _cache_meshes() -> void:
	_buttons.clear()
	for base: String in NES_FACE:
		var m: MeshInstance3D = _find_mesh(base)
		if m != null:
			_buttons.append({"node": m, "rest": m.transform, "bit": int(NES_FACE[base]), "depth": FACE_PRESS})
	# The NES D-pad mesh is "StickLeft22"; its pivot empty is named "StickLeft".
	var dm: MeshInstance3D = _find_mesh("StickLeft22")
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "StickLeft")}
	print("[nes] cached %d buttons, dpad=%s" % [_buttons.size(), not _dpad.is_empty()])
