## RetroSystemModelNDS — Nintendo DS, the original "Phat" (clamshell, two
## 256×192 screens). This is the DEFAULT nds model; the later DS Lite is the
## "nds:lite" variant (nds_lite_model.gd), which subclasses this and swaps only
## the shell GLB — every dual-screen behaviour below is shared.
##
## melonDS/desmume default layout: top/bottom stacked in one 256×384
## framebuffer — top half = top screen, bottom half = touch screen.
## Two video-out cables (TOP / BOTTOM, from the dual-screen base); tapping a
## TV connected to the BOTTOM cable feeds the touch screen.
## Shell geometry lives in nds.tscn; this sets the composite UV mapping + cart.
class_name RetroSystemModelNDS
extends RetroSystemModelDualScreen


## The UV windows assume the stacked composite, and taps (device pad or
## the BOTTOM TV) arrive as RETRO_DEVICE_POINTER — both DS cores default to a
## MOUSE-style pointer that ignores it (melonDS "Mouse" mode, DeSmuME
## pointer_type "mouse"). Force touch mode on both; each core ignores the
## other's keys.
func get_forced_core_options() -> Dictionary:
	return {
		"melonds_touch_mode": "Touch",
		"melonds_screen_layout": "Top/Bottom",
		"melonds_screen_gap": "0",
		"desmume_pointer_type": "touch",
		"desmume_screens_layout": "top/bottom",
	}


func _init() -> void:
	# Stacked 256×384 composite: top half / bottom half.
	top_uv_rect = Rect2(0.0, 0.0, 1.0, 0.5)
	bottom_uv_rect = Rect2(0.0, 0.5, 1.0, 0.5)
	cart_size = Vector3(0.033, 0.035, 0.004)   # DS Game Card


## Detailed DS Phat shell (an author imported). Export-excluded — store builds keep
## the primitive clamshell authored in nds.tscn.
##
## Unlike nds_lite.tscn, this scene is NOT baked (no dual_glb_baked meta and no
## authored Shell child), so the dual-screen base instantiates the GLB and does
## the lid split / screen placement / collision fit at runtime.
func _glb_path() -> String:
	return "res://imported-assets/ds_phat.glb"


## The upper clamshell half (folds with the hinge); the top screen lens + its
## dark backing panel are handled by the base. Everything else = the base half.
func _lid_mesh_names() -> PackedStringArray:
	return PackedStringArray(["Top"])
