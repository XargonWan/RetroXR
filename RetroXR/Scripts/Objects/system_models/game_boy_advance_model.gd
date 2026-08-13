## RetroSystemModelGameBoyAdvance — GBA (landscape, 240×160 LCD).
## The stand-in shell lives in game_boy_advance_primitive.tscn.
class_name RetroSystemModelGameBoyAdvance
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart
	# Keep the VideoHandler's nearest-filtered material instead of wrapping the
	# picture with the shared pixel-AA shader. This gives the GBA a raw point-
	# sampled image, matching frontends that present the core texture directly.
	_lcd_shader = null
