## passthrough_init.gd — Root script for PassthroughScene.tscn.
##
## Enables OpenXR passthrough so the user sees the real world.
## Spawned objects float in AR space against the physical environment.
extends Node3D


var _xr_interface: XRInterface = null


func _ready() -> void:
	_xr_interface = XRServer.find_interface("OpenXR")
	if not _xr_interface or not _xr_interface.is_initialized():
		push_warning("PassthroughInit: OpenXR not initialized, running in flat screen mode")
		return

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_xr_interface.set_play_area_mode(XRInterface.XR_PLAY_AREA_ROOMSCALE)
	get_viewport().use_xr = true

	# Enable passthrough — real world visible through headset
	if _xr_interface.is_passthrough_supported():
		_xr_interface.start_passthrough()
		get_viewport().transparent_bg = true
	else:
		push_warning("PassthroughInit: passthrough not supported on this device")


func _exit_tree() -> void:
	if _xr_interface:
		_xr_interface.stop_passthrough()
		get_viewport().transparent_bg = false
