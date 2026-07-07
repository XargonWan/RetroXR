## RetroCartridge — pickable cartridge carrying a ROM file path.
## Must be in the "cartridge" group to snap into a RetroSystem's CartridgeSlot.
##
## Battery saves: each physical cartridge owns a persistent save identity
## (save_id). Its .srm lives at save/<core>/<game_stem>/<save_id>.srm — like a
## real cartridge, two copies of the same game hold independent saves. Files
## are NEVER deleted; the cartridge options panel can bind any existing .srm
## for this game back onto this cartridge (save recovery).
class_name RetroCartridge
extends XRToolsPickable


const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/cartridge_options_panel.tscn")

## The full path to the ROM file this cartridge represents
@export_global_file var rom_path: String = ""

## Display label (game name, shown on the cartridge face and in spawn menu)
@export var game_label: String = "":
	set(v):
		game_label = v
		_update_label()

## Persistent battery-save identity. Generated once at first _ready; restored
## from saves/snapshots so the cartridge keeps its .srm across sessions.
@export var save_id: String = ""

## The systemid this game belongs to (e.g. "nes"). Set by the spawn menu and
## back-filled when the cartridge is inserted into a console — used to resolve
## the core name for the save-recovery list.
@export var systemid: String = ""

var _options_panel: Node3D = null


func _ready() -> void:
	if save_id.is_empty():
		save_id = "%08x%08x" % [randi(), randi()]
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.text = game_label


## Returns the ROM path — called by RetroSystem when the cartridge snaps in
func get_rom_path() -> String:
	return rom_path


## Toggle the floating save-management panel (mirrors PDFBook/VCR panels).
## Called by SpawnMenuController when the menu button is pressed while
## pointing at this cartridge.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)
