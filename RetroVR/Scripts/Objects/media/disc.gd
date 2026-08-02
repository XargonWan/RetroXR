## RetroDisc — pickable CD/DVD carrying a ROM (disc image) path, for disc-based
## consoles (PlayStation, GameCube, Dreamcast...). Extends RetroCartridge so it
## inherits the whole cartridge contract — CartridgeSlot snap-in ("cartridge"
## group), save_id battery-save identity, persistence file resolution, and the
## cartridge options panel — with a disc-shaped body instead of a box.
##
## Scraped "support" art (the round disc-label scan, usually with transparent
## corners) is applied to the top-face ArtQuad; without art the silver disc
## shows the game title as flat text, like a written-on CD-R.
class_name RetroDisc
extends RetroCartridge


## Whether the host should visually spin this disc while it plays (system.gd's
## _update_disc_spin rotates the whole node about its local Y — correct for a
## round CD/mini-disc, since the visible geometry IS the spinning platter, but
## wrong for a disc enclosed in an opaque caddy, where the real platter isn't
## visible from outside anyway). True for every disc except an override says
## otherwise (see RetroUMD).
func can_visually_spin() -> bool:
	return true


## Resize the disc to this system's diameter (12 cm CD/DVD, 8 cm GameCube
## mini-disc). Duplicates every mesh/shape resource before mutation — tscn
## sub_resources are shared across instances.
func _apply_system_size() -> void:
	var d := MediaDimensions.disc_diameter(systemid)

	var body := get_node_or_null("DiscMesh") as MeshInstance3D
	if body and body.mesh is CylinderMesh:
		var m := body.mesh.duplicate() as CylinderMesh
		m.top_radius = d / 2.0
		m.bottom_radius = d / 2.0
		body.mesh = m

	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is CylinderShape3D:
		var shape := col.shape.duplicate() as CylinderShape3D
		shape.radius = d / 2.0 + 0.005
		col.shape = shape

	var quad := get_node_or_null("ArtQuad") as MeshInstance3D
	if quad and quad.mesh is QuadMesh:
		var qm := quad.mesh.duplicate() as QuadMesh
		qm.size = Vector2(d * 0.94, d * 0.94)
		quad.mesh = qm

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.width = d * 1600.0

	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col and pointer_col.shape is CylinderShape3D:
		var pshape := pointer_col.shape.duplicate() as CylinderShape3D
		pshape.radius = d / 2.0 + 0.02
		pointer_col.shape = pshape


## Disc art goes on the top-face ArtQuad with alpha transparency (round scans
## have transparent corners — the silver disc shows through). No art: quad stays
## hidden and the flat title text is the fallback.
func _apply_label_art() -> void:
	var tex := MediaDimensions.load_label_texture(systemid, rom_path)
	var quad := get_node_or_null("ArtQuad") as MeshInstance3D
	if tex == null or quad == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad.set_surface_override_material(0, mat)
	quad.visible = true

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.visible = false
