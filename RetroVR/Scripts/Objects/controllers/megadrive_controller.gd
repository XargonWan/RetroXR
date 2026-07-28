## MegadriveController — the PAL/JP Mega Drive 3-button pad.
##
## Same hardware as the US Genesis pad, so it inherits GenesisController (and
## with it the RetroPad row mapping in FACE_BITS: A/B/C sit on Y/B/A). The one
## thing it does NOT share is the mesh layout — this is a different author's
## bundle, an author's "Sega Mega Drive GamePad", and it separates A, B and C
## into three meshes where an author's Genesis pad moulds them as one. That is why
## _cache_meshes() is replaced outright rather than extended: three real buttons
## can each depress on their own, so the "mask" hack the base class needs is not
## wanted here.
##
## The buttons carry no letters in the texture (the A/B/C legend is printed on
## the shell beside them), so the row is identified by position: X runs right, so
## the smallest X is A and the largest is C.
class_name MegadriveController
extends GenesisController

## The A/B/C row, left to right — index-aligned with GenesisController.FACE_BITS.
const FACE_ROW_MESHES: Array[String] = [
	"FireButtonLeft",     # A
	"FireButtonBottom",   # B
	"FireButtonRight",    # C
]
const MD_START := "StartButton"
## The D-pad. Named for the generic imported "StickLeft" slot it was duplicated
## into; the trailing digits are the author's duplicate counter.
const MD_DPAD := "StickLeft223"
## Sibling empty marking the D-pad's rocker pivot.
const MD_DPAD_PIVOT := "StickLeft"


func _cache_meshes() -> void:
	_buttons.clear()
	for i in FACE_ROW_MESHES.size():
		var m: MeshInstance3D = _find_mesh(FACE_ROW_MESHES[i])
		if m != null:
			_buttons.append({"node": m, "rest": m.transform,
				"bit": FACE_BITS[i], "depth": FACE_PRESS})
	var start: MeshInstance3D = _find_mesh(MD_START)
	if start != null:
		_buttons.append({"node": start, "rest": start.transform,
			"bit": ControllerBindings.JOYPAD_START, "depth": FACE_PRESS})
	var dm: MeshInstance3D = _find_mesh(MD_DPAD)
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, MD_DPAD_PIVOT)}
	print("[megadrive] cached %d buttons, dpad=%s" % [_buttons.size(), not _dpad.is_empty()])
