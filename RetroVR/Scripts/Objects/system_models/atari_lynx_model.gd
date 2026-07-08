## RetroSystemModelAtariLynx — Atari Lynx (landscape, 160×102 LCD).
## Flippable in real life for left-handers; in VR you just turn it over.
class_name RetroSystemModelAtariLynx
extends RetroSystemModelHandheld


func _init() -> void:
	# Lynx I: ~210 × 110 × 45 mm; 3.5" screen, 160×102 (~1.57:1) landscape.
	body_size = Vector3(0.21, 0.045, 0.11)
	screen_size = Vector2(0.088, 0.056)
	screen_offset = Vector3(0.0, 0.0, 0.0)
	body_color = Color(0.10, 0.10, 0.11)     # black brick
	accent_color = Color(0.65, 0.12, 0.12)   # red A/B buttons
