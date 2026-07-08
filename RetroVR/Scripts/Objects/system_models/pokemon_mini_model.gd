## RetroSystemModelPokemonMini — Nintendo Pokémon mini (96×64 LCD).
## Tiny; it has a real shake sensor + rumble, so our accelerometer plumbing
## (SetSensorAccel) gets a second customer beyond the tilt carts.
class_name RetroSystemModelPokemonMini
extends RetroSystemModelHandheld


func _init() -> void:
	# Pokémon mini: ~74 × 58 × 23 mm; small screen, 96×64 (1.5:1) landscape.
	body_size = Vector3(0.058, 0.023, 0.074)
	screen_size = Vector2(0.0267, 0.0178)
	screen_offset = Vector3(0.0, 0.0, -0.018)
	body_color = Color(0.30, 0.50, 0.85)     # blue
	accent_color = Color(0.90, 0.90, 0.30)
