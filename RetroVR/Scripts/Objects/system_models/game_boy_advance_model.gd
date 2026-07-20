## RetroSystemModelGameBoyAdvance — GBA (landscape, 240×160 LCD).
## Shell geometry lives in game_boy_advance.tscn; this only sets the cart size.
class_name RetroSystemModelGameBoyAdvance
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart
