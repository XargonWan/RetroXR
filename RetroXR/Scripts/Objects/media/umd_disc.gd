## RetroUMD — PSP UMD caddy. The one disc in the room that isn't round: a flat
## SQUARE caddy (~64mm, ~4mm thick) rather than a platter. Isolated in its own
## subclass rather than a systemid check inside disc.gd since it's the only
## non-round case.
##
## This used to be a thin adapter over an imported caddy mesh — it hid the
## procedural disc meshes and let the GLB stand in for them. That mesh went with
## the rest of the imported models on 2026-08-02, so the caddy is built here instead,
## out of the same box-and-quad parts every other stand-in uses. It keeps its own
## subclass because the SHAPE is the thing that differs, and that is still true.
class_name RetroUMD
extends RetroDisc


## The UMD's platter is sealed inside the opaque caddy — spinning the whole
## caddy (system.gd's disc-spin effect) would spin the shell itself, not just
## the disc inside, and isn't visible from outside anyway. No-op.
func can_visually_spin() -> bool:
	return false


## Rebuild the round platter as a square caddy: box body, box colliders, and the
## art quad sized and lifted to sit on the caddy's top face.
##
## Everything is laid out in RetroDisc's frame — thin along Y, footprint in XZ —
## so the caddy drops into the snap poses, the seated grab stub and the insert
## animation without any of them knowing it isn't round. MediaDimensions gives the
## footprint as (width, depth, thickness), hence the y/z swap on the way in.
func _apply_system_size() -> void:
	var size := MediaDimensions.cart_size(systemid)   # (0.064, 0.064, 0.0042)
	var body_size := Vector3(size.x, size.z, size.y)
	var half_thick := size.z / 2.0

	# The platter becomes the shell. Duplicate before mutating: the .tscn's
	# sub_resources are shared across every disc instance in the room.
	var body := get_node_or_null("DiscMesh") as MeshInstance3D
	if body != null:
		var bm := BoxMesh.new()
		bm.size = body_size
		body.mesh = bm

	# A caddy has no spindle hub showing.
	var hub := get_node_or_null("HubMesh") as Node3D
	if hub != null:
		hub.visible = false

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

	# The quad is authored for a 12 cm platter and parked 1.8 mm up, which is
	# inside a 4.2 mm caddy. Shrink it to the caddy face and lift it clear.
	var quad := get_node_or_null("ArtQuad") as MeshInstance3D
	if quad != null and quad.mesh is QuadMesh:
		var qm := quad.mesh.duplicate() as QuadMesh
		qm.size = Vector2(size.x * 0.9, size.y * 0.9)
		quad.mesh = qm
		quad.position.y = half_thick + 0.0003

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl != null:
		lbl.width = size.x * 1600.0
		lbl.position.y = half_thick + 0.0005
