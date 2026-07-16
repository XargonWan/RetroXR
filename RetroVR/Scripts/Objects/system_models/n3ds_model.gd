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
## The physical 3D DEPTH SLIDER on the lid's right edge (just like the real
## hardware) drives citra_factor_3d 0–100%: live while a game runs (azahar
## re-parses options mid-run), and merged into the forced options for the
## next boot. Slider down = 2D-flat (both eyes identical), up = full depth.
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
	# Original 3DS: 134 × 74 × 21 mm closed; top 3.53" 400×240 (~76.8×46.1 mm),
	# bottom 3.02" 320×240 (~61.4×46.1 mm).
	body_size = Vector3(0.134, 0.0105, 0.074)
	lid_size = Vector3(0.134, 0.0105, 0.074)
	lid_open_deg = 115.0
	top_screen_size = Vector2(0.0768, 0.0461)
	bottom_screen_size = Vector2(0.0614, 0.0461)
	top_uv_rect = Rect2(0.0, 0.0, 0.5, 0.5)
	bottom_uv_rect = Rect2(0.05, 0.5, 0.4, 0.5)
	top_eye_shift = 0.5
	body_color = Color(0.12, 0.35, 0.65)     # aqua blue
	accent_color = Color(0.85, 0.85, 0.88)


func _build_shell() -> void:
	super()
	_build_3d_slider()


## Force the stereo output mode every boot; depth follows the physical slider.
func get_forced_core_options() -> Dictionary:
	return {
		"citra_render_3d": "side-by-side",
		"citra_layout_option": "default",
		"citra_swap_screen": "Top",
		"citra_factor_3d": str(roundi(_depth_3d * 100.0)),
	}


## The 3D depth slider on the lid's right edge, beside the top screen —
## up (away from the hinge) = full 3D, down = 2D, like the real hardware.
func _build_3d_slider() -> void:
	_slider_3d = _make_slider("Slider3D", 0, _depth_3d)
	# Lid local frame: panel extends -Z from the hinge, interior face +Y.
	_slider_3d.axis_local = Vector3(0, 0, -1)   # value 1 → -Z = up the lid
	_slider_3d.travel = 0.022
	_slider_3d.engage_radius = 0.02
	_slider_3d.position = Vector3(lid_size.x / 2.0 - 0.005, lid_size.y + 0.003,
		-lid_size.z / 2.0)
	_lid_pivot.add_child(_slider_3d)

	var lbl := Label3D.new()
	lbl.text = "3D"
	lbl.pixel_size = 0.00022
	lbl.font_size = 16
	lbl.modulate = Color(0.1, 0.1, 0.12)
	lbl.rotation_degrees = Vector3(-90, 0, 0)   # flat on the lid face
	lbl.position = _slider_3d.position + Vector3(0, 0.0005, -0.016)
	_lid_pivot.add_child(lbl)

	_slider_3d.value_changed.connect(func(v: float) -> void:
		_depth_3d = v
		# Live while running (azahar applies option changes mid-game); the
		# forced options carry the value into the next boot otherwise.
		if _host and _host.get("is_powered_on") and _host.has_method("set_core_option"):
			_host.set_core_option("citra_factor_3d", str(roundi(v * 100.0))))
