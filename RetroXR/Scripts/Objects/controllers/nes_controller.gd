## NesController — the Nintendo Entertainment System pad.
##
## The first of the imported console models, so unlike RetroPadController and
## VbController it binds its controls with AnimatedController's fuzzy mesh-name
## search instead of by node path — the meshes live inside nes_controller.glb and
## the scene has no authored nodes to point at.
##
## The NES pad is the smallest joypad we animate: a rocking D-pad, B and A, and
## SELECT/START. No shoulders, no triggers, no sticks, so most of the engine sits
## idle and _stick_l / _stick_r / _dpad2 stay empty.
class_name NesController
extends AnimatedController

# Mesh-name stem -> RETRO_JOYPAD bit. _find_mesh normalises and prefix-matches,
# so these hit the glTF's "BtnA_Controller_0" / "DPad_Controller_0" without the
# exporter's suffix having to appear here.
const NES_FACE: Dictionary = {
	"BtnB": ControllerBindings.JOYPAD_B,
	"BtnA": ControllerBindings.JOYPAD_A,
}
const NES_SMALL: Dictionary = {
	"BtnSelect": ControllerBindings.JOYPAD_SELECT,
	"BtnStart":  ControllerBindings.JOYPAD_START,
}

## The D-pad rocks about the shell surface rather than its own centre, which sits
## a little above it. The model ships no pivot empty for _find_pivot to find, and
## that helper's AABB fallback would rock it about its own middle, so drop the
## pivot explicitly the way the authored pads do.
const DPAD_PIVOT_DROP: float = 0.003


func _cache_meshes() -> void:
	_buttons.clear()
	for stem: String in NES_FACE:
		_add_button(stem, int(NES_FACE[stem]), FACE_PRESS)
	for stem: String in NES_SMALL:
		_add_button(stem, int(NES_SMALL[stem]), SMALL_PRESS)
	_dpad = _rocker("DPad", DPAD_PIVOT_DROP)


## The shell lies face-up — +Y out of the face, B left of A along +X — which puts
## the D-pad's UP arm on -Z, so the engine's default pitch would lift UP instead
## of pressing it.
func _dpad_pitch_sign() -> float:
	return -1.0


## Every control is moulded into the top face, so all of them travel along the
## engine's default PRESS_DIR and none needs a "dir" of its own.
func _add_button(stem: String, bit: int, depth: float) -> void:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("NesController: control mesh not found: " + stem)
		return
	_buttons.append({"node": m, "rest": m.transform, "bit": bit, "depth": depth})


func _rocker(stem: String, drop: float) -> Dictionary:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("NesController: control mesh not found: " + stem)
		return {}
	return {"node": m, "rest": m.transform, "pivot": m.position - Vector3(0.0, drop, 0.0)}
