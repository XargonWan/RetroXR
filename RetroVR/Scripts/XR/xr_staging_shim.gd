## XRStagingShim — minimal stub that satisfies the XRTools desktop-support
## node lookup pattern.
##
## The desktop-support movement and pointer nodes (XRToolsDesktopMovementDirect,
## XRToolsDesktopMovementTurn, XRToolsDesktopMouseCapture, etc.) search for an
## ancestor whose name matches "*Staging" and whose is_xr_class() reports
## "XRToolsStaging", then look for a "StartXR" child to call is_xr_active() on.
##
## This script is placed on a Node3D named "Staging" that wraps XROrigin3D
## inside player_rig.tscn, making that lookup succeed without requiring the
## full XRToolsStaging scene-management machinery.
extends Node3D

func is_xr_class(xr_name: String) -> bool:
	return xr_name == "XRToolsStaging"
