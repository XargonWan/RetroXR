## RetroSystemModelGameBoy — original DMG Game Boy (portrait, 160×144 LCD).
## The primitive stand-in shell lives in game_boy.tscn (store-safe fallback); when
## the detailed imported DMG GLB is present it's swapped in by the base (dev-only).
class_name RetroSystemModelGameBoy
extends RetroSystemModelHandheld

## Classic DMG dot-matrix green LCD filter, applied to the built-in screen.
const LCD_SHADER := preload("res://Shaders/gameboy_lcd.gdshader")


func _init() -> void:
	# Game Boy uses the base default cartridge size (57 × 65 × 8 mm).
	_lcd_shader = LCD_SHADER


## Detailed DMG shell (an author imported). Export-excluded — store builds fall back to
## the primitive shell authored in game_boy.tscn.
func _glb_path() -> String:
	return "res://imported-assets/game_boy_dmg.glb"
