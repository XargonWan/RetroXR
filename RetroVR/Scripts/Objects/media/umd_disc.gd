## RetroUMD — PSP UMD caddy. The one disc in the room that isn't round: a flat
## SQUARE caddy (~64mm, ~4mm thick) whose glb ships label-face-forward on its
## own native +Z (thin along Z) rather than RetroDisc's usual thin-along-Y
## convention (round, radius in XZ). Isolated in its own subclass rather than
## a systemid check inside disc.gd since it's the only non-round case.
class_name RetroUMD
extends RetroDisc


## The UMD's platter is sealed inside the opaque caddy — spinning the whole
## caddy (system.gd's disc-spin effect) would spin the shell itself, not just
## the disc inside, and isn't visible from outside anyway. No-op.
func can_visually_spin() -> bool:
	return false


## Swap the shared CylinderShape3D collision for a box matching the caddy's
## real footprint (a round collider under a square caddy reads wrong), and
## hide the procedural CD stand-ins — the real caddy (CartModel) replaces
## them entirely once _apply_cart_model runs.
func _apply_system_size() -> void:
	var size := MediaDimensions.cart_size(systemid)   # (0.064, 0.064, 0.0042) — width, depth, thin-Y
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		var box := BoxShape3D.new()
		box.size = Vector3(size.x, size.z, size.y)
		col.shape = box
	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col:
		var pbox := BoxShape3D.new()
		pbox.size = Vector3(size.x, size.z, size.y) + Vector3(0.02, 0.02, 0.02)
		pointer_col.shape = pbox
	for nm in ["DiscMesh", "HubMesh", "ArtQuad"]:
		var n := get_node_or_null(nm) as Node3D
		if n:
			n.visible = false


## The UMD glb ships label-face-forward on its own native +Z with a square XY
## footprint (thin along Z) — every other disc in this pickable lies flat with
## its thin axis along Y (the CollisionShape3D's cylinder convention). Rotate
## it to match.
func _apply_cart_model() -> void:
	super._apply_cart_model()
	var m := get_node_or_null("CartModel") as Node3D
	if m == null:
		return
	# The base class centred m assuming identity rotation (position = -centre*scale,
	# composed through an identity basis) — rotating in place afterward composes
	# that same offset through the NEW basis instead, leaving a residual drift
	# whenever the model's native centre wasn't already zero on the rotation axis
	# (it isn't: the glb's thickness band sits a couple mm off its own origin).
	# Recompute the same local-frame centre the base used and re-solve position
	# through the rotated basis instead of guessing a constant fudge offset.
	var acc := AABB(); var first := true
	for n in m.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var ab: AABB = mi.transform * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	if acc.size.length() < 0.0001:
		return
	var local_center := acc.position + acc.size * 0.5
	m.rotation_degrees.x = -90.0
	m.position = -(m.transform.basis * local_center)
