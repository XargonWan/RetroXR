extends Node3D

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
		# Enable XR rendering — this also signals desktop support nodes to disable
		# themselves (xr_start_shim.gd returns get_viewport().use_xr).
		get_viewport().use_xr = true
		_log_eye_buffer_quality(xr_interface)
		print("=====================================")
		print("  RetroVR: running in XR / VR mode")
		print("=====================================")
	else:
		print("=====================================")
		print("  RetroVR: running in DESKTOP mode")
		print("  WASD = move   Mouse = look")
		print("  Left-click = grab/shoot")
		print("  Shift+Left-click = drop (held gun)")
		print("  Tab = spawn menu")
		print("=====================================")
		# Ensure the window starts with a sensible resolution for desktop play
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


## Report what the OpenXR session actually came up with — the numbers that explain
## how sharp any virtual screen can possibly look. On a Quest 3 this prints
## 1680x1760 per eye, which is the runtime's RECOMMENDED swapchain and is smaller
## than the 2064x2208 panel (the Godot window reports 4128x2208 for the pair), so
## the compositor upscales every frame ~1.23x. That soft resample is app-wide and
## is why RetroVR reads softer than comparable Unity titles; it also means 3c05e74's
## compositor sharpening is sharpening an upscale.
##
## Not fixed yet, and NOT for want of trying — read this before attempting it again:
##
##  * There is no `xr/openxr/render_target_size_multiplier` PROJECT setting (dumped
##    the whole xr/* list to check). It exists only as an OpenXRInterface property,
##    and Godot's docs are explicit that changing it needs the session restarted —
##    assigning it from _ready() resizes Godot's render target but not the swapchain
##    the runtime already allocated.
##  * `xr/openxr/foveation_level` / `foveation_dynamic` ARE real project settings and
##    do apply on Android — but level 2 (with Godot's default
##    foveation_with_subsampled_images=true) renders the ENTIRE eye buffer as one
##    flat brown fill on this stack: Godot 4.7 + vendors 5.1 + 4x MSAA + multiview,
##    Quest 3. Confirmed with `adb exec-out screencap -p` (4128x2208, uniform
##    (61,36,14) across both lens areas). VrApi timings looked perfect while the
##    image was garbage, which is why perf numbers alone are not verification.
##
## Measured GPU cost of the combination, kept for whoever picks this up (arcade
## scene, 72 Hz, 13.9 ms budget, RenderingServer.viewport_get_measured_render_time_gpu):
##
##   1680x1760, no foveation (current)   13.55 ms  68 fps
##   2065x2163, no foveation             17.04 ms  56 fps
##   2065x2163, foveation 2              12.92 ms  71 fps   <- cheaper than current
##   2352x2464, foveation 3 dynamic      13.95 ms  68 fps
##
## So panel-native IS affordable if foveation can be made to work (fixed foveation
## saves more in the periphery than the extra centre pixels cost). The route to try
## is: set the interface property, then restart the session (uninitialize/initialize)
## before the first XR frame, with foveation_with_subsampled_images=false — and
## verify by screencap, not by frame timings.
func _log_eye_buffer_quality(xri: XRInterface) -> void:
	print("XRInit: eye buffer %s per eye, window %s, foveation %s" % [
		xri.get_render_target_size(), get_viewport().size, xri.get("foveation_level")])
