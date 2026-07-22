## RetroSystemModelN3DS — Nintendo 3DS (clamshell, asymmetric screens),
## with REAL stereoscopic 3D on the top screen.
##
## Runs the patched azahar core (Tools/azahar-libretro-vr overlay) with
## citra_render_3d = "side-by-side": the composite framebuffer keeps the
## default 400×480 layout but each half is one EYE — left half = the whole
## top+bottom layout for the left eye, right half = the right eye. The UV
## rects below therefore select the LEFT-eye regions, and the top screen's
## eye_shift (+0.5) makes the right VR eye sample the right-eye half — per-eye
## depth in the headset, the thing the 3DS's parallax barrier faked.
##
## Left-eye regions of the 400×480 SBS composite (default layout: top 400×240
## full-width, bottom 320×240 centered with 40px pillarboxes, each squeezed
## to half width per eye):
##   top    = (0,    0,   0.5, 0.5)
##   bottom = (0.05, 0.5, 0.4, 0.5)   ← also where touch maps (azahar folds
##                                       SBS touch onto the left-eye half)
##
## The physical 3D DEPTH SLIDER on the lid's right edge (Slider3D, authored in
## n3ds.tscn) drives citra_factor_3d 0–100%: live while a game runs (azahar
## re-parses options mid-run), and merged into the forced options for the next
## boot. Slider down = 2D-flat (both eyes identical), up = full depth.
##
## NOTE: these rects assume the patched azahar core. A stock citra core
## ignores citra_render_3d and outputs a mono 400×480 layout, which would
## show through these stereo windows misaligned.
class_name RetroSystemModelN3DS
extends RetroSystemModelDualScreen

var _slider_3d: VRSlider = null
## 3D depth 0..1 (slider position). Applied as citra_factor_3d percent.
var _depth_3d := 1.0


func _init() -> void:
	# Left-eye regions of the 400×480 side-by-side composite.
	top_uv_rect = Rect2(0.0, 0.0, 0.5, 0.5)
	bottom_uv_rect = Rect2(0.05, 0.5, 0.4, 0.5)
	top_eye_shift = 0.5
	cart_size = Vector3(0.033, 0.035, 0.004)   # 3DS Game Card


## Detailed New 3DS XL shell (an author imported). Export-excluded — store builds keep
## the primitive clamshell authored in n3ds.tscn.
func _glb_path() -> String:
	return "res://imported-assets/new_3ds_xl.glb"


## The upper clamshell half (folds with the hinge); the top screen lens is
## handled by the base. Everything else in the GLB is the base half. The two
## slider knobs ride the lid's edges, so they fold with it too.
func _lid_mesh_names() -> PackedStringArray:
	return PackedStringArray(["top", "Slider3DKnob", "VolumeKnob"])


## Force the stereo output mode every boot; depth follows the physical slider.
func get_forced_core_options() -> Dictionary:
	return {
		"citra_render_3d": "side-by-side",
		"citra_layout_option": "default",
		"citra_swap_screen": "Top",
		"citra_factor_3d": str(roundi(_depth_3d * 100.0)),
	}


## Wire the authored 3D depth slider (on the lid, beside the top screen) to
## azahar's citra_factor_3d — up (away from the hinge) = full 3D, down = 2D.
func configure_handheld_controls(host: Node3D) -> void:
	super(host)

	# The GLB carries a real, separated knob for each slider (split out of the
	# shell in Blender). Travel them with their slider so the physical cap rides
	# its groove; the authored primitive stand-in knobs stay hidden.
	_knob_3d = _cache_knob("Slider3DKnob")
	_knob_vol = _cache_knob("VolumeKnob")
	if _volume_slider != null:
		_set_knob(_knob_vol, _volume_slider.value)
		_volume_slider.value_changed.connect(func(v: float) -> void: _set_knob(_knob_vol, v))

	_slider_3d = get_node_or_null("LidPivot/Slider3D") as VRSlider
	if _slider_3d == null:
		return
	_depth_3d = _slider_3d.value
	_set_knob(_knob_3d, _depth_3d)
	_slider_3d.value_changed.connect(func(v: float) -> void:
		_depth_3d = v
		_set_knob(_knob_3d, v)
		# Live while running (azahar applies option changes mid-game); the
		# forced options carry the value into the next boot otherwise.
		if _host and _host.get("is_powered_on") and _host.has_method("set_core_option"):
			_host.set_core_option("citra_factor_3d", str(roundi(v * 100.0))))


# ── Physical slider knobs ─────────────────────────────────────────────────────
# Both grooves run along the lid's slanted side rim, so travel is a diagonal in
# the model's local space. Value 0 = the hinge end (2D / quiet), 1 = the far end
# by the top of the screen (full depth / loud) — matching the real hardware.
const _KNOB_TRAVEL := 0.0105
const _KNOB_AXIS := Vector3(0.0, -0.622, -0.783)

var _knob_3d: Dictionary = {}
var _knob_vol: Dictionary = {}


func _cache_knob(mesh_name: String) -> Dictionary:
	var m := find_child(mesh_name, true, false) as MeshInstance3D
	if m == null:
		return {}
	# Express the travel axis in the knob's PARENT space, so it stays correct
	# after the base reparents the knob onto the folding LidPivot.
	var axis := _KNOB_AXIS
	var parent := m.get_parent() as Node3D
	if parent != null:
		axis = parent.global_transform.basis.inverse() * (global_transform.basis * _KNOB_AXIS)
	return {"node": m, "rest": m.position, "axis": axis.normalized()}


func _set_knob(e: Dictionary, value: float) -> void:
	if e.is_empty():
		return
	var node: MeshInstance3D = e["node"]
	var rest: Vector3 = e["rest"]
	var axis: Vector3 = e["axis"]
	node.position = rest + axis * (clampf(value, 0.0, 1.0) * _KNOB_TRAVEL)


## Power button: drive the real PowerButton3ds mesh on the front-right edge
## rather than the base's generic nub, so the visible power button depresses when
## pressed. The button→toggle_power connection is made once by RetroSystem; this
## only repositions the VRButton and points it at the real mesh (as every other
## model's configure_buttons does). The 3DS has no separate reset / eject.
func configure_buttons(power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	var mesh := find_child("PowerButton3ds", true, false) as MeshInstance3D
	var marker := find_child("Power", true, false) as Node3D
	power_btn.trigger_radius = 0.013
	power_btn.depress_depth = 0.0014
	power_btn.set_latched_pressed(false)
	if mesh != null:
		power_btn.set_button_mesh(mesh)   # depress the real button; hides the console ButtonMesh
	if marker != null:
		power_btn.global_position = marker.global_position
		power_btn.set_depress_axis_from_node(marker)
	elif mesh != null:
		power_btn.global_position = mesh.global_transform * mesh.get_aabb().get_center()
		power_btn.set_depress_axis_world(Vector3(0, 0, 1))   # press inward from the front face
	var col := power_btn.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = Vector3(0.012, 0.010, 0.010)
	var lbl := power_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# ── Physical control animation ────────────────────────────────────────────────
# Driven each frame by HandheldInput from the exact joypad state it feeds the
# core: face buttons and shoulders/triggers depress, the D-pad rocks, and the
# Circle Pad SLIDES in its dish (it does not tilt like a thumbstick). Meshes come
# from the runtime-loaded detailed GLB; a store build on the primitive fallback
# simply has nothing to cache and no-ops.

const _FACE_MESH := {
	ControllerBindings.JOYPAD_A: "FireButtonRight",   # A
	ControllerBindings.JOYPAD_B: "FireButtonBottom",  # B
	ControllerBindings.JOYPAD_X: "FireButtonTop",     # X
	ControllerBindings.JOYPAD_Y: "FireButtonLeft",    # Y
	ControllerBindings.JOYPAD_START:  "StartButton",
	ControllerBindings.JOYPAD_SELECT: "SelectButton",
}
const _SHOULDER_MESH := {
	ControllerBindings.JOYPAD_L:  "LShoulderButton",
	ControllerBindings.JOYPAD_R:  "RShoulderButton",
	ControllerBindings.JOYPAD_L2: "LIndexTriggerButton",   # ZL
	ControllerBindings.JOYPAD_R2: "RIndexTriggerButton",   # ZR
}
const _FACE_PRESS := 0.0026
const _SHOULDER_PRESS := 0.0040
const _PAD_SLIDE := 0.0032
const _DPAD_TILT_DEG := 8.0
const _ANIM_W := 0.4
const _ANIM_PRESS_DIR := Vector3(0, -1, 0)

var _anim_cached := false
var _anim_btns: Array[Dictionary] = []   # {node, rest, bit, depth}
var _anim_pad: Dictionary = {}           # circle pad: {node, rest}
var _anim_dpad: Dictionary = {}          # {node, rest, pivot}


func _cache_anim_meshes() -> void:
	_anim_cached = true
	for map: Dictionary in [_FACE_MESH, _SHOULDER_MESH]:
		var depth: float = _FACE_PRESS if map == _FACE_MESH else _SHOULDER_PRESS
		for bit: int in map:
			var m := find_child(map[bit], true, false) as MeshInstance3D
			if m != null:
				_anim_btns.append({"node": m, "rest": m.transform, "bit": bit, "depth": depth})
	var pad := find_child("StickLeft22", true, false) as MeshInstance3D
	if pad != null:
		_anim_pad = {"node": pad, "rest": pad.transform}
	var dpad := find_child("Dpad22", true, false) as MeshInstance3D
	if dpad != null:
		var pivot := dpad.transform.origin
		var e := find_child("Dpad", true, false)
		if e != null and not (e is MeshInstance3D):
			pivot = dpad.get_parent().to_local((e as Node3D).global_position)
		_anim_dpad = {"node": dpad, "rest": dpad.transform, "pivot": pivot}


## btn = RETRO_JOYPAD bitmask; lstick/rstick are the analog values (−1..1) as sent
## to the core (y already screen-negated). Lerps the meshes toward that state.
func animate_controls(btn: int, lstick: Vector2, _rstick: Vector2) -> void:
	if not _anim_cached:
		_cache_anim_meshes()

	for e: Dictionary in _anim_btns:
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var down := 1.0 if (btn & (1 << int(e["bit"]))) != 0 else 0.0
		var tgt := Transform3D(rest.basis, rest.origin + _ANIM_PRESS_DIR * (float(e["depth"]) * down))
		node.transform = node.transform.interpolate_with(tgt, _ANIM_W)

	if not _anim_pad.is_empty():
		var node: MeshInstance3D = _anim_pad["node"]
		var rest: Transform3D = _anim_pad["rest"]
		# x = right, z toward the hinge (lstick.y is screen-negated, so forward = −z).
		var off := Vector3(lstick.x, 0.0, lstick.y) * _PAD_SLIDE
		node.transform = node.transform.interpolate_with(Transform3D(rest.basis, rest.origin + off), _ANIM_W)

	if not _anim_dpad.is_empty():
		var pitch := float((btn >> ControllerBindings.JOYPAD_UP) & 1) - float((btn >> ControllerBindings.JOYPAD_DOWN) & 1)
		var roll := float((btn >> ControllerBindings.JOYPAD_LEFT) & 1) - float((btn >> ControllerBindings.JOYPAD_RIGHT) & 1)
		var r := Basis.from_euler(Vector3(deg_to_rad(pitch * _DPAD_TILT_DEG), 0.0, deg_to_rad(roll * _DPAD_TILT_DEG)))
		var node: MeshInstance3D = _anim_dpad["node"]
		var rest: Transform3D = _anim_dpad["rest"]
		var pivot: Vector3 = _anim_dpad["pivot"]
		var about := Transform3D(r, pivot - r * pivot)
		node.transform = node.transform.interpolate_with(about * rest, _ANIM_W)
