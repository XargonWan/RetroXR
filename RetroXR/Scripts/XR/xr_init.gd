extends Node3D

## Scene id this room registers as in SceneManager.SCENE_PATHS. Leave empty for
## the arcade, which is the default.
@export var scene_id: String = ""


## Claim the scene id before any _ready() runs. SpawnMenuController auto-loads the
## last arcade save on startup whenever SceneManager still reads "arcade", and that
## load begins by freeing every node in the "spawned" group — cables included.
## Arriving through SceneManager.change_scene() sets the id already; running a
## scene directly (F6, or a headless probe) does not.
func _enter_tree() -> void:
	if scene_id.is_empty():
		return
	var sm := get_node_or_null("/root/SceneManager")
	if sm != null:
		sm.current_scene_id = scene_id


func _ready():
	DesktopBindings.load_and_apply()
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# Use roomscale tracking so Y=0 is the physical floor
		xr_interface.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		# Pick a display refresh rate (system setting alone is not enough).
		# Quest: 72Hz — the arcade scene blows the 8.3ms/frame budget of 120Hz on
		# both CPU and GPU, so higher rates just triple the stale-frame count.
		# Desktop PCVR: keep the highest available rate.
		var supported_rates: Array = xr_interface.get_available_display_refresh_rates()
		if not supported_rates.is_empty():
			var target: float = 72.0 if OS.get_name() == "Android" else supported_rates.max()
			var best: float = supported_rates[0]
			for rate: float in supported_rates:
				if absf(rate - target) < absf(best - target):
					best = rate
			xr_interface.set_display_refresh_rate(best)
			print("XRInit: display refresh rate set to %s Hz (available: %s)" % [best, supported_rates])
		# Before the first XR frame, so the swapchain is sized once (see below).
		_apply_eye_buffer_scale(xr_interface)
		# Enable XR rendering — this also signals desktop support nodes to disable
		# themselves (xr_start_shim.gd returns get_viewport().use_xr).
		get_viewport().use_xr = true
		_log_eye_buffer_quality(xr_interface)
		print("=====================================")
		print("  RetroXR: running in XR / VR mode")
		print("=====================================")
	else:
		print("=====================================")
		print("  RetroXR: running in DESKTOP mode")
		print("  WASD = move   Mouse = look")
		print("  Left-click = grab/shoot")
		print("  Shift+Left-click = drop (held gun)")
		print("  Tab = spawn menu")
		print("=====================================")
		# Ensure the window starts with a sensible resolution for desktop play
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


## Render each eye at the Quest's PANEL resolution instead of the runtime's
## recommended swapchain.
##
## x1.0 is NOT "native": OpenXR's recommendedImageRect is a performance
## recommendation, not the display size. Meta ships Quest 3 with recommended
## 1680x1760 per eye against a 2064x2208 panel (the Godot window reports 4128x2208
## for the pair) — about 80% linear, on purpose. Unity's default eye texture is the
## same recommended size; Quest titles that look sharper have raised it themselves.
##
## Nor is the shortfall a flat 1.23x upscale of the finished image: the compositor
## warps a rectilinear eye buffer through the lens distortion, which over-samples
## the periphery and under-samples the CENTRE, so the runtime sizes the
## recommendation to land ~1:1 in the middle. The missing detail is therefore
## concentrated exactly where you look, which is why raising this is worth real
## frame time — and why foveation is its natural partner (spend the pixels in the
## centre, drop the ones wasted at the edges). It also means 3c05e74's compositor
## sharpening was sharpening an under-sampled centre rather than fixing it.
##
## Caveat not yet tested: xr/openxr/extensions/meta/dynamic_resolution is on (a
## vendors-plugin default) and lets the runtime LOWER the eye buffer under GPU load,
## which this scene is under. get_render_target_size() is only sampled at startup
## below, so a mid-session drop would not show up. Log it per-second on-device to
## find out.
##
## COSTS FRAME RATE, deliberately, for now. Measured on a Quest 3 (arcade scene,
## 72 Hz = 13.9 ms budget):
##
##   1680x1760 (x1.0)      13.55 ms  68 fps
##   2065x2163 (x1.229)    17.04 ms  56 fps   <- this
##
## Fixed foveation would pay for it outright (12.92 ms / 71 fps at x1.229), but
## foveation_level >= 1 fills the whole eye buffer with one flat colour on this stack
## (Godot 4.7 + vendors 5.1 + 4x MSAA + multiview / Quest 3) — see 21351c5. So the
## resolution is turned up on its own and the frame rate is the price until that is
## solved. Set QUEST_EYE_BUFFER_SCALE back to 1.0 to undo.
##
## Assigned to the interface PROPERTY, not a project setting: there is no
## `xr/openxr/render_target_size_multiplier` setting (the whole xr/* list was dumped
## to check). It is set before `use_xr = true`, i.e. before the first XR frame, so
## the swapchain is created once at this size rather than resized mid-session.
##
## Android only — PCVR runtimes size and supersample their own swapchains.
const QUEST_EYE_BUFFER_SCALE := 1.229   # 2064/1680; 1.0 = runtime recommended

func _apply_eye_buffer_scale(xri: XRInterface) -> void:
	if OS.get_name() != "Android" or is_equal_approx(QUEST_EYE_BUFFER_SCALE, 1.0):
		return
	xri.set("render_target_size_multiplier", QUEST_EYE_BUFFER_SCALE)


## Report what the session actually came up with, so a bad eye-buffer size is
## visible in logcat instead of only in the headset. `foveation` should read 0 —
## anything else means foveation crept back in and the view will be a flat colour
## (21351c5); on a Quest 3 with the scale above, expect
## "eye buffer (2064.72, 2163.04) per eye, window (4128, 2208), foveation 0".
func _log_eye_buffer_quality(xri: XRInterface) -> void:
	print("XRInit: eye buffer %s per eye, window %s, foveation %s" % [
		xri.get_render_target_size(), get_viewport().size, xri.get("foveation_level")])
