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
## handled by the base. Everything else in the GLB is the base half.
func _lid_mesh_names() -> PackedStringArray:
	return PackedStringArray(["top"])


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
	_slider_3d = get_node_or_null("LidPivot/Slider3D") as VRSlider
	if _slider_3d == null:
		return
	_depth_3d = _slider_3d.value
	_slider_3d.value_changed.connect(func(v: float) -> void:
		_depth_3d = v
		# Live while running (azahar applies option changes mid-game); the
		# forced options carry the value into the next boot otherwise.
		if _host and _host.get("is_powered_on") and _host.has_method("set_core_option"):
			_host.set_core_option("citra_factor_3d", str(roundi(v * 100.0))))
