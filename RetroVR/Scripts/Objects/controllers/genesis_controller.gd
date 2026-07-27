## GenesisController — Sega Genesis / Mega Drive 3-button pad.
## Same animation engine as every other pad; only the mesh names and the
## button→RETRO_JOYPAD map differ. Layout: a D-pad, one row of A/B/C, and START.
##
## Model: an author's "Genesis Controller" bundle. Its meshes are named for the
## Blender object they were duplicated from, so every one is prefixed
## `Controler_001|` (the author's spelling) and suffixed `|Dupli|<n>` — matching
## is on the normalised prefix, and the D-pad target has to carry its `|Dupli`
## or it also matches `D_Pad_Frame_001`.
##
## A, B and C are ONE mesh. There is no separate geometry to press, so the row
## depresses as a unit whenever any of the three is held, via the "mask" entry.
## Splitting it would mean inventing button geometry the author didn't model.
class_name GenesisController
extends AnimatedController

## Mesh prefix for the moulded A/B/C row.
const FACE_ROW := "Controler_001|C_Button"
const START_BUTTON := "Controler_001|Start_Button"
## Trailing `|Dupli` disambiguates the pad from its surrounding frame mesh.
const DPAD_MESH := "Controler_001|D_Pad|Dupli"

## RetroArch's usual Genesis mapping: the A/B/C row sits on RetroPad Y/B/A.
const FACE_BITS: Array[int] = [
	ControllerBindings.JOYPAD_Y,
	ControllerBindings.JOYPAD_B,
	ControllerBindings.JOYPAD_A,
]


func _cache_meshes() -> void:
	_buttons.clear()
	var row: MeshInstance3D = _find_mesh(FACE_ROW)
	if row != null:
		var mask := 0
		for bit in FACE_BITS:
			mask |= 1 << bit
		_buttons.append({"node": row, "rest": row.transform,
			"bit": FACE_BITS[1], "mask": mask, "depth": FACE_PRESS})
	var start: MeshInstance3D = _find_mesh(START_BUTTON)
	if start != null:
		_buttons.append({"node": start, "rest": start.transform,
			"bit": ControllerBindings.JOYPAD_START, "depth": FACE_PRESS})
	# No pivot empty in this GLB — _find_pivot falls back to the mesh's own AABB
	# centre, which is what we want: the pad rocks in place.
	var dm: MeshInstance3D = _find_mesh(DPAD_MESH)
	if dm != null:
		_dpad = {"node": dm, "rest": dm.transform, "pivot": _find_pivot(dm, "")}
