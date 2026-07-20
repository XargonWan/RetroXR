## RetroSystemModelSupervision — Watara Supervision (160×160 LCD).
## A chunky Game Boy clone; square screen on a tall brick body.
## Shell geometry lives in supervision.tscn; this only sets the cart size.
class_name RetroSystemModelSupervision
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.066, 0.070, 0.009)   # Supervision cart
