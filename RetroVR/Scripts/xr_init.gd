extends Node3D

func _ready():
	DesktopBindings.load_and_apply()
	var xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		# Use roomscale tracking so Y=0 is the physical floor
		xr_interface.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
		# Request the highest available refresh rate (system setting alone is not enough)
		var supported_rates: Array = xr_interface.get_available_display_refresh_rates()
		if not supported_rates.is_empty():
			var best: float = supported_rates.max()
			xr_interface.set_display_refresh_rate(best)
			print("XRInit: display refresh rate set to %s Hz (available: %s)" % [best, supported_rates])
		# Enable XR rendering — this also signals desktop support nodes to disable
		# themselves (xr_start_shim.gd returns get_viewport().use_xr).
		get_viewport().use_xr = true
		print("XRInit: VR mode active")
	else:
		push_warning("OpenXR not initialized — desktop mode active")
		# Ensure the window starts with a sensible resolution for desktop play
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
