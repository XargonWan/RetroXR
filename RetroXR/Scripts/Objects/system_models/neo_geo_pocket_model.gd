## RetroSystemModelNeoGeoPocket — SNK Neo Geo Pocket Color (160×152 LCD).
## Near-square screen; landscape body with a clicky microswitch stick.
## Shell geometry lives in neo_geo_pocket.tscn; this only sets the cart size.
class_name RetroSystemModelNeoGeoPocket
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.048, 0.052, 0.008)   # NGP cart
