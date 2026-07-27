## RetroSystemModelMegaDrive — Sega Mega Drive (Model 1), the JP/EU regional badge
## of the Genesis. Same hardware; the GLB shares the Genesis node layout, so this
## reuses every bit of the Genesis wiring and only swaps the shell.
##
## Registered as the "mega_drive:megadrive" variant (dev-only). GLB export-excluded.
class_name RetroSystemModelMegaDrive
extends RetroSystemModelGenesis


func _model_path() -> String:
	return "res://unbundled-models/consoles/sega_megadrive.glb"
