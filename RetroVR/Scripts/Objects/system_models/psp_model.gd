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


## UMD drive slit on the back, not a cartridge mouth (PSP media is a disc).
func _build_cart_slot_mouth() -> void:
	var slit := MeshInstance3D.new()
	slit.name = "UMDSlit"
	var slit_mesh := BoxMesh.new()
	slit_mesh.size = Vector3(0.070, 0.007, 0.004)
	slit.mesh = slit_mesh
	var slit_mat := StandardMaterial3D.new()
	slit_mat.albedo_color = Color(0.03, 0.03, 0.04)
	slit.set_surface_override_material(0, slit_mat)
	slit.position = Vector3(0, 0, -body_size.z / 2.0)
	add_child(slit)


## UMD slot keeps the legacy flat placement at the back edge — the slot-load
## disc ride (system._play_slot_insert) travels along the zone's -Z, so the
## cartridge-style -90° zone rotation must not apply to the disc.
func configure_cartridge_slot(slot: Node3D) -> void:
	slot.position = Vector3(0, 0, -body_size.z / 2.0 - 0.01)
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
