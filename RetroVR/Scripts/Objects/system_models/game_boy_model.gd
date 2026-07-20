## RetroSystemModelGameBoy — original DMG Game Boy (portrait, 160×144 LCD).
## Shell geometry lives in game_boy.tscn; this only adds the DMG LCD filter.
class_name RetroSystemModelGameBoy
extends RetroSystemModelHandheld

## Classic DMG dot-matrix green LCD filter, applied to the built-in screen.
const LCD_SHADER := preload("res://Shaders/gameboy_lcd.gdshader")


func _init() -> void:
	# Game Boy uses the base default cartridge size (57 × 65 × 8 mm).
	_lcd_shader = LCD_SHADER
