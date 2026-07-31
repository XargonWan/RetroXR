## XRStartShim — minimal stub that satisfies the XRTools desktop-support
## node lookup for "StartXR".
##
## Desktop-support nodes (movement, mouse-capture, pointer) look for a child
## named "StartXR" under the "*Staging" ancestor and call is_xr_active() on it
## to decide whether to disable themselves.
##
## This script delegates to get_viewport().use_xr, which is set to true by
## xr_init.gd when OpenXR initialises successfully. In desktop mode (no headset)
## it remains false, so the desktop nodes stay active.
extends Node

func is_xr_active() -> bool:
	return get_viewport().use_xr
