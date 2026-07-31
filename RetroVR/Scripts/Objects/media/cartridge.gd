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


## Real per-system cartridge models (imported). Export-excluded, so a store build
## silently falls back to the procedural box.
const _CART_MODELS := {
	"nds": "res://imported-assets/nds_cart.glb",
	"3ds": "res://imported-assets/n3ds_cart.glb",
	# Grey Game Boy / Game Boy Color cart (GBC games group under game_boy).
	"game_boy": "res://imported-assets/game_boy_cart.glb",
	"game_boy_advance": "res://imported-assets/game_boy_advance_cart.glb",
	"atari_2600": "res://imported-assets/atari_2600_cart.glb",
	"atari_5200": "res://imported-assets/atari_5200_cart.glb",
	"virtual_boy": "res://imported-assets/virtual_boy_cart.glb",
	# One EU-styled cart serves Genesis and Mega Drive alike (the shells differ,
	# the cartridge does not).
	"mega_drive": "res://imported-assets/genesis_cart.glb",
	"playstation_portable": "res://imported-assets/psp_umd.glb",
}

## Name of the model's swappable label face. Almost every imported media model calls
## it "media_label"; the PSP UMD prints its disc-face art on "vetro" (Italian for
## glass) instead, with a separate "media_label" quad buried behind it — so the
## game art has to land on vetro or it hides under the caddy's placeholder print.
const _LABEL_MESH := {
	"playstation_portable": "vetro",
}

## The model's own swappable label face, when a real cart model is in use.
var _model_label: MeshInstance3D = null


func _ready() -> void:
	if save_id.is_empty():
		save_id = "%08x%08x" % [randi(), randi()]
	_update_label()
	_apply_system_size()
	_apply_cart_model()
	_apply_label_art()


## Swap the procedural box for this system's real cartridge model when one ships.
## The GLB's body runs +Y from its connector at the origin with the label on +Z —
## the same frame the framework uses — so centring its AABB lands it correctly
## (connector -Y, grip +Y, label +Z) and everything downstream (snap pose, seated
## grab stub, insert animation) keeps working unchanged.
func _apply_cart_model() -> void:
	if _model_label != null or has_node("CartModel"):
		return
	var path: String = _CART_MODELS.get(systemid, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var glb := scene.instantiate() as Node3D
	glb.name = "CartModel"
	add_child(glb)
	var ab := _cart_model_aabb(glb)
	if ab.size.y <= 0.0001:
		return
	# Scale the (oversized) model down to the system's real card dimensions.
	var s := MediaDimensions.cart_size(systemid)
	var k: float = minf(s.x / maxf(ab.size.x, 0.0001), s.y / maxf(ab.size.y, 0.0001))
	glb.scale = Vector3(k, k, k)
	glb.position = -(ab.position + ab.size * 0.5) * k
	var desync := glb.find_child("Desync", true, false) as MeshInstance3D
	if desync != null:
		desync.visible = false
	_model_label = glb.find_child(_LABEL_MESH.get(systemid, "media_label"), true, false) as MeshInstance3D
	# The procedural stand-ins are replaced by the real shell. Includes the disc
	# body meshes (DiscMesh/HubMesh/ArtQuad) so a RetroDisc with a real media
	# model — the PSP UMD caddy — doesn't show a generic CD poking through it.
	for nm in ["CartridgeMesh", "LabelMesh", "GameLabel", "DiscMesh", "HubMesh", "ArtQuad"]:
		var n := get_node_or_null(nm) as Node3D
		if n != null:
			n.visible = false


## Bounds of the flat face of a model's label mesh, in cartridge space.
##
## A label mesh is not always the flat quad the art quad wants to cover. The
## Atari 2600 and Mega Drive labels wrap over the top edge of the shell the way
## the printed ones do, so the mesh AABB straddles the cart's whole depth and
## its centre sits several millimetres inside the plastic — art placed there is
## swallowed by the body. Keeping only the polygons that face along the label
## normal leaves the flat front the sticker actually lives on. Either sign of
## the normal counts: some models have the quad's winding inverted, and the
## polygon lies in the label plane either way.
func _label_face_bounds(mi: MeshInstance3D) -> AABB:
	var xf := global_transform.affine_inverse() * mi.global_transform
	var full: AABB = xf * mi.get_aabb()
	var mesh := mi.mesh
	if mesh == null:
		return full
	var acc := AABB()
	var first := true
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_NORMAL:
			continue
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_NORMAL] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if norms.size() != verts.size():
			continue
		for i in verts.size():
			if absf((xf.basis * norms[i]).normalized().z) < 0.95:
				continue
			var p := xf * verts[i]
			if first:
				acc = AABB(p, Vector3.ZERO)
				first = false
			else:
				acc = acc.expand(p)
	# No face-on geometry (the 3DS quad's normals point along +Y) — the mesh is
	# flat enough that its own AABB is the label plane.
	if first or acc.size.x < 0.0001 or acc.size.y < 0.0001:
		return full
	return acc


func _cart_model_aabb(root: Node3D) -> AABB:
	var acc := AABB(); var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var ab: AABB = mi.transform * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return acc


func _update_label() -> void:
	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.text = game_label


## Resize the generic cartridge to this system's real-world dimensions
## (MediaDimensions.CART_SIZES). All mesh/shape resources are DUPLICATED before
## mutation — tscn sub_resources are shared across instances, so editing them
## in place would resize every cartridge in the room.
func _apply_system_size() -> void:
	if not MediaDimensions.CART_SIZES.has(systemid):
		return
	var s := MediaDimensions.cart_size(systemid)

	var body := get_node_or_null("CartridgeMesh") as MeshInstance3D
	if body and body.mesh is BoxMesh:
		var m := body.mesh.duplicate() as BoxMesh
		m.size = s
		body.mesh = m

	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		var shape := col.shape.duplicate() as BoxShape3D
		# Grab padding: keep tiny carts (nds is 3.3 cm) comfortably pickable.
		shape.size = Vector3(maxf(s.x, 0.05), maxf(s.y, 0.05), maxf(s.z + 0.025, 0.04))
		col.shape = shape

	var label_mesh := get_node_or_null("LabelMesh") as MeshInstance3D
	if label_mesh and label_mesh.mesh is BoxMesh:
		var lm := label_mesh.mesh.duplicate() as BoxMesh
		lm.size = Vector3(s.x * 0.8, s.y * 0.62, 0.002)
		label_mesh.mesh = lm
		label_mesh.position = Vector3(0, s.y * 0.125, s.z / 2.0 + 0.001)

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.position = Vector3(0, s.y * 0.125, s.z / 2.0 + 0.0045)
		lbl.width = s.x * 2000.0

	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col and pointer_col.shape is BoxShape3D and col:
		var pshape := pointer_col.shape.duplicate() as BoxShape3D
		pshape.size = (col.shape as BoxShape3D).size + Vector3(0.04, 0.04, 0)
		pointer_col.shape = pshape


## While seated in a handheld's recessed slot only the grip end pokes out of
## the body — limit grabbing (VR hands, desktop reticle, laser) to that stub.
## The normal grab padding (a ≥5 cm box around a 3.3 cm card) otherwise pokes
## through the thin shell and swallows clicks meant for the device itself.
## `depth` is the exposed length along the cart's +Y (grip) end.
func set_seated_grab_stub(depth: float) -> void:
	if not MediaDimensions.CART_SIZES.has(systemid):
		return
	var s := MediaDimensions.cart_size(systemid)
	var stub_center := Vector3(0, s.y / 2.0 - depth / 2.0, 0)
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		var shape := col.shape.duplicate() as BoxShape3D
		shape.size = Vector3(s.x, depth, s.z + 0.004)
		col.shape = shape
		col.position = stub_center
	var pcol := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol and pcol.shape is BoxShape3D:
		var pshape := pcol.shape.duplicate() as BoxShape3D
		# Keep the pointer target to the exposed stub. It used to pad +1 cm on
		# every axis, and that +1 cm of DEPTH pushed the grab volume ~6 mm past
		# the slot mouth toward the screen — so pointing at the console just above
		# a seated cart grabbed the cart. Match the grab box's depth (no bleed) and
		# only pad x/y a hair so the small stub is still targetable.
		pshape.size = Vector3(s.x + 0.004, depth + 0.002, s.z + 0.004)
		pcol.shape = pshape
		pcol.position = stub_center


## Restore the normal (padded) grab shapes after leaving a handheld slot.
func reset_grab_shapes() -> void:
	if not MediaDimensions.CART_SIZES.has(systemid):
		return
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		col.position = Vector3.ZERO
	var pcol := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol:
		pcol.position = Vector3.ZERO
	_apply_system_size()


## Apply the scraped "support" label art onto the label face. Missing art keeps
## the existing generic label + title text fallback. Fresh material every time —
## never mutate the shared Mat_label sub_resource.
func _apply_label_art() -> void:
	var tex := MediaDimensions.load_label_texture(systemid, rom_path)
	if tex == null:
		return
	# Real cart model: cover the model's own label face with a quad of our own
	# rather than repainting theirs.
	#
	# Painting onto the author's quad means inheriting the author's UVs, and the
	# models agree on no convention at all — normals point in or out, u runs
	# across on one card and up the face on another. Every "detect it and mirror
	# the UV" rule got some cart backwards (the Virtual Boy label read in
	# reverse; the rule that fixed it flipped Super Mario 64 DS). The label plane
	# is a flat quad in the cart's XY facing +Z on all of them, so building a
	# fresh quad over it from its measured bounds is right by construction and
	# stays right for models we haven't imported yet.
	if _model_label != null:
		var ab := _label_face_bounds(_model_label)
		if ab.size.x > 0.0001 and ab.size.y > 0.0001:
			_model_label.visible = false
			var art := MeshInstance3D.new()
			art.name = "ModelLabelArt"
			add_child(art)
			# Fit-within, so art of any aspect is never stretched to the recess.
			var fitted := Vector2(ab.size.x, ab.size.y)
			var aspect := float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)
			if fitted.x / maxf(fitted.y, 0.0001) > aspect:
				fitted.x = fitted.y * aspect
			else:
				fitted.y = fitted.x / aspect
			var qm := QuadMesh.new()
			qm.size = fitted
			art.mesh = qm
			var c := ab.get_center()
			art.position = Vector3(c.x, c.y, ab.position.z + ab.size.z + 0.0003)
			var lm := StandardMaterial3D.new()
			lm.albedo_color = Color.WHITE
			lm.albedo_texture = tex
			# A disc's scraped label art is a round scan with transparent corners
			# (see disc.gd's own ArtQuad path) — this quad is square, so without
			# alpha the corners show as an opaque black box instead of the silver
			# disc showing through. Harmless no-op on a cart's opaque rectangular
			# label (alpha stays 1.0 throughout).
			lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			art.set_surface_override_material(0, lm)
		var glbl := get_node_or_null("GameLabel") as Label3D
		if glbl != null:
			glbl.visible = false
		return
	var label_mesh := get_node_or_null("LabelMesh") as MeshInstance3D
	if label_mesh == null or not (label_mesh.mesh is BoxMesh):
		return
	# Fit-within: shrink one axis of the label region to the texture's aspect so
	# the art is never stretched (region set by _apply_system_size or the scene).
	var region := (label_mesh.mesh as BoxMesh).size
	var aspect := float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)
	var fitted := Vector2(region.x, region.y)
	if region.x / maxf(region.y, 0.0001) > aspect:
		fitted.x = region.y * aspect
	else:
		fitted.y = region.x / aspect
	# QuadMesh, not BoxMesh: a BoxMesh atlases the texture across its six faces
	# (the front face would show only a crop). The quad faces +Z like the label.
	var qm := QuadMesh.new()
	qm.size = fitted
	label_mesh.mesh = qm
	label_mesh.position.z += region.z / 2.0 + 0.0002   # sit on the old face plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	label_mesh.set_surface_override_material(0, mat)

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.visible = false


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
