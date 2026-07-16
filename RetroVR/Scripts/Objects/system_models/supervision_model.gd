## RetroSystemModelSupervision — Watara Supervision (160×160 LCD).
## A chunky Game Boy clone; square screen on a tall brick body.
class_name RetroSystemModelSupervision
extends RetroSystemModelHandheld


func _init() -> void:
	# Watara Supervision: tall brick; 2.9" screen, 160×160 (1:1, square).
	body_size = Vector3(0.09, 0.030, 0.16)
	screen_size = Vector2(0.05, 0.05)
	screen_offset = Vector3(0.0, 0.0, -0.03)
	body_color = Color(0.55, 0.55, 0.58)     # grey
	accent_color = Color(0.20, 0.20, 0.25)
	cart_size = Vector3(0.066, 0.070, 0.009)   # Supervision cart
