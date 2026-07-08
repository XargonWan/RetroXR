## RetroSystemModelNeoGeoPocket — SNK Neo Geo Pocket Color (160×152 LCD).
## Near-square screen; landscape body with a clicky microswitch stick.
class_name RetroSystemModelNeoGeoPocket
extends RetroSystemModelHandheld


func _init() -> void:
	# NGPC: ~129.5 × 74.5 × 24.5 mm; 2.1" screen, 160×152 (≈1.05:1, near square).
	body_size = Vector3(0.1295, 0.0245, 0.0745)
	screen_size = Vector2(0.0379, 0.036)
	screen_offset = Vector3(0.0, 0.0, -0.006)
	body_color = Color(0.20, 0.35, 0.60)     # a classic blue shell
	accent_color = Color(0.90, 0.85, 0.20)
