## RetroSystemModelGameBoyAdvance — GBA (landscape, 240×160 LCD).
## Detailed imported GLB (dev-only) is baked into game_boy_advance.tscn; the plain
## primitive stand-in lives in its own scene, spawned only as a store-safe fallback.
class_name RetroSystemModelGameBoyAdvance
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart


## Detailed GBA shell (an author imported, Arctic White). Export-excluded.
func _glb_path() -> String:
	return "res://imported-assets/game_boy_advance.glb"
