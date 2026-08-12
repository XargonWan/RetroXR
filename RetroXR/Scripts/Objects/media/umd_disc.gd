## RetroUMD — PSP UMD caddy. The one disc in the room that isn't round: a flat
## SQUARE caddy (~64mm, ~4mm thick) rather than a platter. Isolated in its own
## subclass rather than a systemid check inside disc.gd since it's the only
## non-round case.
##
## The caddy is built here out of the same box-and-quad parts every other stand-in
## uses: RetroDisc's lathed platter is replaced by a box, and because that box
## carries none of the UV2 zone data Shaders/disc.gdshader reads off the platter,
## it takes a plain StandardMaterial3D and its own art quad instead. The subclass
## earns its keep because the SHAPE is what differs.
class_name RetroUMD
extends RetroDisc


## The UMD's platter is sealed inside the opaque caddy — spinning the whole
## caddy (system.gd's disc-spin effect) would spin the shell itself, not just
## the disc inside, and isn't visible from outside anyway. No-op.
func can_visually_spin() -> bool:
	return false


## Rebuild the round platter as a square caddy: box body, box colliders, and a
## plain moulded-plastic material in place of the disc shader.
##
## Everything is laid out in RetroDisc's frame — thin along Y, footprint in XZ —
## so the caddy drops into the snap poses, the seated grab stub and the insert
## animation without any of them knowing it isn't round. MediaDimensions gives the
## footprint as (width, depth, thickness), hence the y/z swap on the way in.
func _apply_system_size() -> void:
	var size := MediaDimensions.cart_size(systemid)   # (0.064, 0.064, 0.0042)
	var body_size := Vector3(size.x, size.z, size.y)
	var half_thick := size.z / 2.0

	# The platter becomes the shell.
	var body := get_node_or_null("DiscMesh") as MeshInstance3D
	if body != null:
		var bm := BoxMesh.new()
		bm.size = body_size
		body.mesh = bm
		# The disc shader reads the (face, radius) UV2 pair the lathed platter
		# bakes. A BoxMesh carries no such thing and would shade as garbage zones,
		# so the caddy drops off the shader entirely.
		var shell := StandardMaterial3D.new()
		shell.albedo_color = Color(0.16, 0.16, 0.18)
		shell.roughness = 0.55
		shell.metallic = 0.0
		body.set_surface_override_material(0, shell)

	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null:
		var box := BoxShape3D.new()
		box.size = body_size
		col.shape = box

	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col != null:
		var pbox := BoxShape3D.new()
		pbox.size = body_size + Vector3(0.02, 0.02, 0.02)
		pointer_col.shape = pbox

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl != null:
		lbl.width = size.x * 1600.0
		lbl.position.y = half_thick + 0.0005


## A caddy is printed on, not lacquered, so the art goes on a quad sitting on its
## top face rather than into the disc shader's label layer.
func _apply_label_art() -> void:
	var tex := MediaDimensions.load_label_texture(systemid, rom_path)
	if tex == null:
		return
	var size := MediaDimensions.cart_size(systemid)

	var art := get_node_or_null("CaddyArt") as MeshInstance3D
	if art == null:
		art = MeshInstance3D.new()
		art.name = "CaddyArt"
		art.add_to_group("outline_exclude")
		add_child(art)
	var qm := QuadMesh.new()
	qm.size = Vector2(size.x * 0.9, size.y * 0.9)
	art.mesh = qm
	art.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	art.position = Vector3(0.0, size.z / 2.0 + 0.0003, 0.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	art.set_surface_override_material(0, mat)

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl != null:
		lbl.visible = false
