## RetroSystemModelGameBoyAdvance — GBA (landscape, 240×160 LCD).
class_name RetroSystemModelGameBoyAdvance
extends RetroSystemModelHandheld


func _init() -> void:
	# Real GBA: 144.5 × 24.5 × 82 mm; screen 61 × 41 mm (240:160 = 3:2).
	body_size = Vector3(0.1445, 0.0245, 0.082)
	screen_size = Vector2(0.061, 0.041)
	screen_offset = Vector3(0.0, 0.0, 0.0)
	body_color = Color(0.35, 0.30, 0.55)   # indigo
	accent_color = Color(0.85, 0.85, 0.9)
