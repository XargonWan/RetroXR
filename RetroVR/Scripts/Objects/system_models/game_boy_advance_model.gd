## RetroSystemModelGameBoyAdvance — GBA (landscape, 240×160 LCD).
## Primitive stand-in shell lives in game_boy_advance.tscn (store-safe fallback);
## the detailed imported GLB is swapped in by the base when present (dev-only).
class_name RetroSystemModelGameBoyAdvance
extends RetroSystemModelHandheld


func _init() -> void:
	cart_size = Vector3(0.058, 0.036, 0.007)   # GBA cart


## Detailed GBA shell (an author imported, Arctic White). Export-excluded.
func _glb_path() -> String:
	return "res://imported-assets/game_boy_advance.glb"
