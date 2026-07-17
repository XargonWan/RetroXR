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


func _ready() -> void:
	if save_id.is_empty():
		save_id = "%08x%08x" % [randi(), randi()]
	_update_label()
	_apply_system_size()
	_apply_label_art()


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
		pshape.size = Vector3(s.x + 0.01, depth + 0.006, s.z + 0.01)
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
