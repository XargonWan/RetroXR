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


## Store-safe primitive stand-in (spawned only when the detailed DMG GLB is absent).
func _primitive_path() -> String:
	return "res://Scenes/Objects/system_models/game_boy_primitive.tscn"


## Align the cart with the shell's own slot marker ACROSS the body — the base
## centres it on the body's mid-plane, but the DMG's connector sits ~1 cm below
## that, so on a 3 cm-thick shell the card sat visibly off the real slot.
##
## Only x/y come from the marker; the depth is set so the cart's outer end lands
## FLUSH with the top of the shell, like real hardware — a Game Boy cartridge
## drops fully into the back recess rather than standing proud. (Seating the
## contacts on the marker instead left 30 mm of a 65 mm cart hanging out, and
## the base's _cart_protrude() convention still left ~18 mm.) The marker's basis
## already encodes the right pose — length running out of the top mouth, label
## facing the console's back.
## Falls back to the base placement when the detailed GLB is absent.
func configure_cartridge_slot(slot: Node3D) -> void:
	super(slot)
	var sock := find_child("socket_media", true, false) as Node3D
	if sock == null:
		return
	var b: Basis = (global_transform.basis.inverse() * sock.global_transform.basis).orthonormalized()
	var p: Vector3 = to_local(sock.global_position)
	var seat_z := -body_size.z * 0.5 + cart_size.y * 0.5
	slot.transform = Transform3D(b, Vector3(p.x, p.y, seat_z))
