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
		_apply_eye_buffer_quality(xr_interface)
		# Enable XR rendering — this also signals desktop support nodes to disable
		# themselves (xr_start_shim.gd returns get_viewport().use_xr).
		get_viewport().use_xr = true
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


## Quest: render each eye at the PANEL's resolution and pay for it with fixed
## foveation.
##
## Measured on a Quest 3 (arcade scene, 72 Hz, 13.9 ms budget). Godot asks OpenXR
## for the runtime's *recommended* swapchain, which is 1680x1760 per eye — but the
## panel is 2064x2208 (the Godot window reports 4128x2208 = both eyes), so the
## compositor was UPSCALING every frame by 1.23x. That soft resample is on top of
## everything, which is why the whole app read softer than comparable Unity
## titles regardless of core/screen settings (see also 3c05e74, compositor
## sharpening — a sharpen pass over an upscale, not a fix for it).
##
##   1680x1760, no foveation (shipped)  13.55 ms  68 fps
##   2065x2163, no foveation            17.04 ms  56 fps   <- can't afford alone
##   2065x2163, foveation 2             12.92 ms  71 fps   <- CHEAPER than shipped
##   2352x2464, foveation 3 dynamic     13.95 ms  68 fps
##
## Fixed foveation shades the periphery at reduced rate, and on this scene it saves
## more than the extra centre pixels cost — panel-native comes out ahead of what
## was shipping. Anything held up and looked at sits in the full-rate centre.
## 4x MSAA is kept: it resolves in tile memory on Adreno, and dropping to 2x
## measured no cheaper (13.38 ms).
##
## Desktop/PCVR is left alone — those runtimes size and supersample their own
## swapchains, and the GPU budget isn't ours to spend.
const QUEST_EYE_BUFFER_SCALE := 1.229   # 2064/1680 — recommended -> panel native
const QUEST_FOVEATION_LEVEL := 2        # 0 off .. 3 highest

func _apply_eye_buffer_quality(xri: XRInterface) -> void:
	if OS.get_name() != "Android":
		return
	xri.set("render_target_size_multiplier", QUEST_EYE_BUFFER_SCALE)
	xri.set("foveation_level", QUEST_FOVEATION_LEVEL)
	# Dynamic lets the runtime relax foveation when a frame is cheap (menus, an
	# empty room) and lean on it when the arcade is busy.
	xri.set("foveation_dynamic", true)
	print("XRInit: eye buffer %s (x%.3f), foveation %d dynamic" % [
		xri.get_render_target_size(), QUEST_EYE_BUFFER_SCALE, QUEST_FOVEATION_LEVEL])
