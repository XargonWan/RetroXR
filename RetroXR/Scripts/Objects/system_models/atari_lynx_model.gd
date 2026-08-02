## RetroSystemModelAtariLynx — Atari Lynx (landscape, 160×102 LCD).
## Flippable in real life for left-handers; in VR you just turn it over.
## Shell geometry lives in atari_lynx.tscn; this only sets the cart size.
class_name RetroSystemModelAtariLynx
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.073, 0.086, 0.006)   # Lynx card
