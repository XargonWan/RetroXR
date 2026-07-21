## RetroSystemModelPS2Silver — PlayStation 2 Slim in the Satin Silver finish.
## Same hardware as the black Slim; the GLB shares node names + animations, so this
## reuses every bit of the PS2 model wiring and only swaps the shell.
##
## Registered as the "playstation2:silver" variant (dev-only). GLB export-excluded.
class_name RetroSystemModelPS2Silver
extends RetroSystemModelPS2


func _model_path() -> String:
	return "res://imported-assets/ps2_slim_silver.glb"
