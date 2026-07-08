## RetroSystemModelN3DS — Nintendo 3DS (clamshell, asymmetric screens).
## citra/azahar default layout: 400×480 composite — top screen (400×240, 5:3)
## fills the top half; bottom touch screen (320×240, 4:3) is centered in the
## bottom half with 40px pillarboxes, hence the inset bottom UV rect.
## NOTE: the libretro 3DS cores render MONO — the stereoscopic 3D of the real
## hardware is not exposed as a core option (standalone-azahar only, for now).
class_name RetroSystemModelN3DS
extends RetroSystemModelDualScreen


func _init() -> void:
	# Original 3DS: 134 × 74 × 21 mm closed; top 3.53" 400×240 (~76.8×46.1 mm),
	# bottom 3.02" 320×240 (~61.4×46.1 mm).
	body_size = Vector3(0.134, 0.0105, 0.074)
	lid_size = Vector3(0.134, 0.0105, 0.074)
	lid_open_deg = 115.0
	top_screen_size = Vector2(0.0768, 0.0461)
	bottom_screen_size = Vector2(0.0614, 0.0461)
	top_uv_rect = Rect2(0.0, 0.0, 1.0, 0.5)
	bottom_uv_rect = Rect2(0.1, 0.5, 0.8, 0.5)   # 320 of 400 px, centered
	body_color = Color(0.12, 0.35, 0.65)     # aqua blue
	accent_color = Color(0.85, 0.85, 0.88)
