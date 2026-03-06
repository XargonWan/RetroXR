## RetroCartridge — pickable cartridge carrying a ROM file path.
## Must be in the "cartridge" group to snap into a RetroSystem's CartridgeSlot.
class_name RetroCartridge
extends XRToolsPickable


## The full path to the ROM file this cartridge represents
@export_global_file var rom_path: String = ""

## Display label (game name, shown on the cartridge face and in spawn menu)
@export var game_label: String = "":
	set(v):
		game_label = v
		_update_label()


func _ready() -> void:
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.text = game_label


## Returns the ROM path — called by RetroSystem when the cartridge snaps in
func get_rom_path() -> String:
	return rom_path
