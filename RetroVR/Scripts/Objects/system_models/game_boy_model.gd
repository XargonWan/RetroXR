## RetroSystemModelGameBoy — original DMG Game Boy (portrait, 160×144 LCD).
class_name RetroSystemModelGameBoy
extends RetroSystemModelHandheld


func _init() -> void:
	# Real DMG: 90 × 148 × 32 mm; screen 47 × 43 mm (160:144 ≈ 10:9).
	body_size = Vector3(0.09, 0.032, 0.148)
	screen_size = Vector2(0.047, 0.043)
	screen_offset = Vector3(0.0, 0.0, -0.033)
	body_color = Color(0.75, 0.73, 0.70)
	accent_color = Color(0.55, 0.15, 0.45)
