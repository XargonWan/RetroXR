## RetroSystemModelNDS — Nintendo DS (clamshell, two 256×192 screens).
## melonDS/desmume default layout: top/bottom stacked in one 256×384
## framebuffer — top half = top screen, bottom half = touch screen.
## Two video-out cables (TOP / BOTTOM, from the dual-screen base); tapping a
## TV connected to the BOTTOM cable feeds the touch screen.
class_name RetroSystemModelNDS
extends RetroSystemModelDualScreen


## The UV windows above assume the stacked composite, and taps (device pad or
## the BOTTOM TV) arrive as RETRO_DEVICE_POINTER — melonDS only reads the
## pointer in "Touch" mode (its default "Mouse" ignores it).
func get_forced_core_options() -> Dictionary:
	return {
		"melonds_touch_mode": "Touch",
		"melonds_screen_layout": "Top/Bottom",
		"melonds_screen_gap": "0",
	}


func _init() -> void:
	# DS Lite: 133 × 73.9 × 21.5 mm closed (base ≈ half the thickness);
	# both screens 3.0" 256×192 (4:3), ~61 × 45.7 mm.
	body_size = Vector3(0.133, 0.011, 0.0739)
	lid_size = Vector3(0.133, 0.011, 0.0739)
	lid_open_deg = 112.0
	top_screen_size = Vector2(0.061, 0.0457)
	bottom_screen_size = Vector2(0.061, 0.0457)
	top_uv_rect = Rect2(0.0, 0.0, 1.0, 0.5)
	bottom_uv_rect = Rect2(0.0, 0.5, 1.0, 0.5)
	body_color = Color(0.92, 0.92, 0.94)     # DS Lite polar white
	accent_color = Color(0.25, 0.25, 0.28)
	cart_size = Vector3(0.033, 0.035, 0.004)   # DS Game Card
