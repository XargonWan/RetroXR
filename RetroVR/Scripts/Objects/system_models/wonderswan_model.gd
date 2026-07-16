## RetroSystemModelWonderSwan — Bandai WonderSwan / Color (224×144 LCD).
## Real games switch between landscape and portrait — physically rotating the
## device in VR is exactly how it was meant to be played.
class_name RetroSystemModelWonderSwan
extends RetroSystemModelHandheld


func _init() -> void:
	# WonderSwan: ~121 × 74.3 × 24.3 mm; 2.49" screen, 224×144 (14:9 ≈ 1.56:1).
	body_size = Vector3(0.0743, 0.024, 0.121)
	screen_size = Vector2(0.045, 0.029)
	screen_offset = Vector3(0.0, 0.0, -0.028)
	body_color = Color(0.70, 0.70, 0.72)     # silver
	accent_color = Color(0.30, 0.30, 0.35)
	cart_size = Vector3(0.048, 0.052, 0.008)   # WonderSwan cart
