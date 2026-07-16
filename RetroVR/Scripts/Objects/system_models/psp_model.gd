## RetroSystemModelPSP — Sony PlayStation Portable (480×272 widescreen LCD).
## Single wide 16:9 screen; the ROM ("disc") loads from the back edge. The core
## (ppsspp) is the heavyweight part — the shell itself is trivial.
class_name RetroSystemModelPSP
extends RetroSystemModelHandheld


func _init() -> void:
	# PSP-1000: ~170 × 74 × 23 mm; 4.3" screen, 480×272 (≈16:9, 1.765:1).
	body_size = Vector3(0.17, 0.023, 0.074) 
	screen_size = Vector2(0.0953, 0.054)
	screen_offset = Vector3(0.0, 0.0, 0.0)
	body_color = Color(0.05, 0.05, 0.06)     # glossy black
	accent_color = Color(0.16, 0.16, 0.20)
