## passthrough_init.gd — Root script for PassthroughScene.tscn.
##
## Enables OpenXR passthrough so the user sees the real world.
## Requires project setting xr/openxr/extensions/meta/passthrough=true so the
## XR_FB_passthrough extension wrapper is registered and ALPHA_BLEND is available.
## See: https://docs.godotengine.org/en/4.6/tutorials/xr/ar_passthrough.html
extends Node3D


@onready var _viewport: Viewport = get_viewport()
@onready var _environment: Environment = $WorldEnvironment.environment


func _ready() -> void:
	var xr_interface := XRServer.find_interface("OpenXR")
	if not xr_interface or not xr_interface.is_initialized():
		push_warning("PassthroughInit: OpenXR not initialized, running in flat screen mode")
		return

	# XR is already running from the arcade scene (use_xr, roomscale were set there).
	# Defer so the viewport is fully settled after the scene change.
	call_deferred("_enable_passthrough")


func _enable_passthrough() -> void:
	var xr_interface: XRInterface = XRServer.primary_interface
	if not xr_interface:
		push_warning("PassthroughInit: no primary XR interface")
		return

	var modes := xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
	elif XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
	else:
		push_warning("PassthroughInit: no passthrough blend mode supported — modes: %s" % str(modes))
		return

	_viewport.transparent_bg = true

	# BG_COLOR with fully transparent black so the passthrough layer shows through.
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR

	print("PassthroughInit: passthrough enabled (blend_mode=%d)" % xr_interface.environment_blend_mode)


func _disable_passthrough() -> void:
	var xr_interface: XRInterface = XRServer.primary_interface
	if not xr_interface:
		return

	var modes := xr_interface.get_supported_environment_blend_modes()
	if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE

	_viewport.transparent_bg = false


func _exit_tree() -> void:
	_disable_passthrough()
