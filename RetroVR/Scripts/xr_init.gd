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
