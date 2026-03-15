## PDFBook — A VR-holdable book that displays PDF pages.
##
## Spawn via spawn menu (manual button) or instantiate and call load_pdf().
class_name PDFBook
extends XRToolsPickable

## Path to the PDF file to display.
@export_global_file("*.pdf") var pdf_path: String = "":
	set(value):
		pdf_path = value
		if not _loading and is_inside_tree() and not pdf_path.is_empty():
			load_pdf(pdf_path)

## Render DPI — higher = sharper but more memory. 150 is good for Quest.
@export_range(72, 300) var render_dpi: int = 150

## Fixed book height in meters (width is derived from PDF aspect ratio).
@export var book_height: float = 0.25

## Snap threshold in degrees — when a turning page is within this many degrees
## of fully open (180°) or fully closed (0°), it snaps to completion.
@export var snap_threshold_deg: float = 15.0

## Number of pages to pre-render ahead/behind the current spread.
@export var prefetch_pages: int = 6

# ── Internal state ────────────────────────────────────────────────────────────

enum BookState { CLOSED, OPEN, LAST_PAGE }
enum _Format { PDF, CBZ }

var _state: BookState = BookState.CLOSED
var _format: _Format = _Format.PDF
var _page_count: int = 0
var _leaf_count: int = 0

## Current spread index. When open, the left page shows leaf[current_leaf].back,
## and the right page shows leaf[current_leaf+1].front.
## 0 = cover just opened (left = page 1, right = page 2).
var _current_leaf: int = 0

var _renderer: RefCounted = null  # PDFRenderer instance (PDF only)
var _cbz_entries: Array[String] = []  # sorted image filenames inside the CBZ (CBZ only)
var _cbz_path: String = ""            # stored for per-task ZIPReader opens (CBZ only)
var _page_width: float = 0.0
var _page_height: float = 0.0
var _book_width: float = 0.0  # single page width in meters

# Texture cache (page_index -> ImageTexture)
var _texture_cache: Dictionary = {}

# PNG disk cache directory
var _cache_dir: String = ""

# Page mesh nodes (set up in _ready or after scene load)
@onready var _cover_mesh: MeshInstance3D = $Cover
@onready var _back_cover_mesh: MeshInstance3D = $BackCover
@onready var _left_stack: MeshInstance3D = $LeftStack
@onready var _left_stack_top: MeshInstance3D = $LeftStack/LeftStackTop
@onready var _right_stack: MeshInstance3D = $RightStack
@onready var _right_stack_top: MeshInstance3D = $RightStack/RightStackTop
@onready var _spine_node: Node3D = $Spine
@onready var _active_leaf_container: Node3D = $ActiveLeafContainer

# The currently active turning leaf
var _active_leaf: Node3D = null
var _is_turning: bool = false
var _turn_direction: int = 0  # 1 = forward, -1 = backward
var _loading: bool = false  # re-entry guard for load_pdf ↔ setter

# VR page turning
var _controllers: Array = []
var _turn_cooldown: float = 0.0
const TURN_COOLDOWN_TIME := 0.5
const GRIP_THRESHOLD := 0.3
const GRIP_DETECT_RADIUS := 0.15
const SPINE_WIDTH := 0.012          # width of the spine binding strip
const SPINE_HEIGHT_MARGIN := 0.004  # how much taller spine is than pages
const LEAF_THICKNESS := 0.001       # meters of depth per leaf
const COVER_THICKNESS := 0.004      # combined depth contribution of front + back covers
const COVER_GAP := 0.001            # gap between page stack face and cover quad
const STACK_BASE_DEPTH := 0.005     # BoxMesh baseline depth used as scale divisor
const ZFIGHT_MARGIN := 0.0005       # tiny margin to prevent Z-fighting on coplanar faces
const HINT_LABEL_OFFSET := 0.02     # distance outside the book edge for hint labels

# Async page rendering
var _render_mutex := Mutex.new()
var _pending_renders: Dictionary = {}  # page_index -> true

# Loading placeholder texture
var _loading_texture: ImageTexture = null

# Hint labels for page turning
var _next_label: Label3D = null
var _prev_label: Label3D = null


func _ready() -> void:
	super._ready()
	_create_loading_texture()
	_create_hint_labels()
	await get_tree().process_frame
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)
	if not pdf_path.is_empty():
		load_pdf(pdf_path)


## Open a PDF or CBZ file and configure the book.
func load_pdf(path: String) -> void:
	_cleanup()
	_loading = true
	pdf_path = path
	_loading = false

	var ext := path.get_extension().to_lower()
	if ext == "cbz":
		_load_cbz(path)
	else:
		_load_pdf_internal(path)


func _load_pdf_internal(path: String) -> void:
	_format = _Format.PDF
	_renderer = ClassDB.instantiate("PDFRenderer")
	if not _renderer:
		push_error("[PDFBook] PDFRenderer class not available. Is the GDExtension loaded?")
		return

	if not _renderer.Open(path):
		push_error("[PDFBook] Failed to open PDF: %s" % path)
		_renderer = null
		return

	_page_count = _renderer.GetPageCount()
	if _page_count == 0:
		push_warning("[PDFBook] PDF has 0 pages: %s" % path)
		_renderer.Close()
		_renderer = null
		return

	_leaf_count = ceili(_page_count / 2.0)

	var size: Vector2 = _renderer.GetPageSize(0)
	_page_width = size.x
	_page_height = size.y

	if _page_height > 0:
		var aspect := _page_width / _page_height
		_book_width = book_height * aspect
	else:
		_book_width = book_height * 0.7

	_cache_dir = "user://pdf_cache/" + pdf_path.md5_text() + "/"
	DirAccess.make_dir_recursive_absolute(_cache_dir)

	_configure_meshes()
	_set_state(BookState.CLOSED)

	print("[PDFBook] Loaded PDF: %s (%d pages, %d leaves, %.2f x %.2f m)" % [
		pdf_path, _page_count, _leaf_count, _book_width, book_height])


func _load_cbz(path: String) -> void:
	_format = _Format.CBZ
	_cbz_path = path

	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		push_error("[PDFBook] Failed to open CBZ: %s (err %d)" % [path, err])
		return

	# Filter entries to supported image types, sort naturally
	var IMAGE_EXTS := ["jpg", "jpeg", "png", "webp"]
	var entries: Array[String] = []
	for entry: String in reader.get_files():
		if entry.get_extension().to_lower() in IMAGE_EXTS:
			entries.append(entry)
	entries.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0
	)
	reader.close()

	if entries.is_empty():
		push_warning("[PDFBook] CBZ has no image entries: %s" % path)
		return

	_cbz_entries = entries
	_page_count = entries.size()
	_leaf_count = ceili(_page_count / 2.0)

	# Decode the first image to get page dimensions
	var first_img := _decode_cbz_page(0)
	if first_img:
		_page_width = first_img.get_width()
		_page_height = first_img.get_height()
	else:
		_page_width = 1.0
		_page_height = 1.0

	if _page_height > 0:
		_book_width = book_height * (_page_width / _page_height)
	else:
		_book_width = book_height * 0.65

	_cache_dir = "user://pdf_cache/" + path.md5_text() + "/"
	DirAccess.make_dir_recursive_absolute(_cache_dir)

	_configure_meshes()
	_set_state(BookState.CLOSED)

	print("[PDFBook] Loaded CBZ: %s (%d pages, %d leaves, %.2f x %.2f m)" % [
		path, _page_count, _leaf_count, _book_width, book_height])


## Decode a CBZ page image by index. Opens and closes its own ZIPReader (thread-safe).
func _decode_cbz_page(page_index: int) -> Image:
	if page_index < 0 or page_index >= _cbz_entries.size():
		return null
	var reader := ZIPReader.new()
	if reader.open(_cbz_path) != OK:
		return null
	var data := reader.read_file(_cbz_entries[page_index])
	reader.close()
	if data.is_empty():
		return null
	var img := Image.new()
	var ext := _cbz_entries[page_index].get_extension().to_lower()
	var decode_err: Error
	if ext == "png":
		decode_err = img.load_png_from_buffer(data)
	elif ext == "webp":
		decode_err = img.load_webp_from_buffer(data)
	else:  # jpg / jpeg
		decode_err = img.load_jpg_from_buffer(data)
	if decode_err != OK:
		return null
	return img


# ── Async page texture loading ────────────────────────────────────────────────

## Get a page texture if cached, otherwise return placeholder and start background render.
func _get_page_texture(page_index: int) -> ImageTexture:
	if page_index < 0 or page_index >= _page_count:
		return null

	if _texture_cache.has(page_index):
		return _texture_cache[page_index]

	# Check disk cache (fast — no PDF render needed)
	var cache_path := _cache_dir + "page_%03d.png" % page_index
	if FileAccess.file_exists(cache_path):
		var img := Image.load_from_file(cache_path)
		if img:
			var tex := ImageTexture.create_from_image(img)
			_texture_cache[page_index] = tex
			return tex

	# Queue background render
	_request_page_render(page_index)
	return _loading_texture


## Queue a page for background rendering if not already pending.
func _request_page_render(page_index: int) -> void:
	if _pending_renders.has(page_index):
		return
	_pending_renders[page_index] = true

	if _format == _Format.CBZ:
		var cache_dir := _cache_dir
		WorkerThreadPool.add_task(func():
			var img := _decode_cbz_page(page_index)
			if img:
				img.save_png(cache_dir + "page_%03d.png" % page_index)
			call_deferred("_on_page_rendered", page_index, img)
		)
		return

	# PDF path
	if not _renderer or not _renderer.IsOpen():
		_pending_renders.erase(page_index)
		return
	var renderer_ref := _renderer
	var dpi := render_dpi
	var cache_dir := _cache_dir
	WorkerThreadPool.add_task(func():
		_render_mutex.lock()
		var img: Image = null
		if renderer_ref and renderer_ref.IsOpen():
			img = renderer_ref.RenderPage(page_index, dpi)
		_render_mutex.unlock()
		if img:
			img.save_png(cache_dir + "page_%03d.png" % page_index)
		call_deferred("_on_page_rendered", page_index, img)
	)


## Called on main thread when a background page render completes.
func _on_page_rendered(page_index: int, img: Image) -> void:
	_pending_renders.erase(page_index)
	if not img:
		return
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[page_index] = tex
	_refresh_visible_textures()


## Re-apply textures to currently visible meshes (after async render completes).
func _refresh_visible_textures() -> void:
	match _state:
		BookState.CLOSED:
			_update_cover_texture()
			_update_back_cover_texture()
		BookState.OPEN:
			_update_cover_texture()
			_update_back_cover_texture()
			_update_spread_textures()
		BookState.LAST_PAGE:
			_update_cover_texture()
			_update_back_cover_texture()


## Unload textures that are far from the current spread to save VRAM.
func _trim_texture_cache() -> void:
	var keep_min := maxi(0, (_current_leaf * 2) - prefetch_pages)
	var keep_max := mini(_page_count - 1, (_current_leaf * 2) + prefetch_pages + 2)
	# Always keep cover and back cover
	var to_remove: Array[int] = []
	for key: int in _texture_cache:
		if key == 0 or key == _page_count - 1:
			continue
		if key < keep_min or key > keep_max:
			to_remove.append(key)
	for key: int in to_remove:
		_texture_cache.erase(key)


# ── Mesh configuration ────────────────────────────────────────────────────────

## Configure mesh sizes and create unique materials for each mesh.
func _configure_meshes() -> void:
	var half_w := _book_width / 2.0
	var spine_half := SPINE_WIDTH / 2.0
	# Stack center X: pages start at the outer edge of the spine
	var stack_x := half_w + spine_half

	_set_mesh_size(_cover_mesh, _book_width, book_height)
	_set_mesh_size(_back_cover_mesh, _book_width, book_height)
	_set_mesh_size(_left_stack_top, _book_width, book_height)
	_set_mesh_size(_right_stack_top, _book_width, book_height)

	# Duplicate shared box meshes so stacks are independent
	if _left_stack.mesh:
		_left_stack.mesh = _left_stack.mesh.duplicate()
	if _right_stack.mesh:
		_right_stack.mesh = _right_stack.mesh.duplicate()

	# Stack box sizes and positions — offset outward so they don't overlap the spine
	if _left_stack.mesh is BoxMesh:
		(_left_stack.mesh as BoxMesh).size = Vector3(_book_width, book_height, STACK_BASE_DEPTH)
	if _right_stack.mesh is BoxMesh:
		(_right_stack.mesh as BoxMesh).size = Vector3(_book_width, book_height, STACK_BASE_DEPTH)
	_left_stack.position = Vector3(-stack_x, 0, 0)
	_right_stack.position = Vector3(stack_x, 0, 0)

	# Spine initial setup: full closed-book depth, centered at Z=0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)
	var closed_spine_depth := total_thick + COVER_THICKNESS + ZFIGHT_MARGIN
	var spine_mesh := _spine_node.get_node("SpineMesh") as MeshInstance3D
	if spine_mesh and spine_mesh.mesh is BoxMesh:
		spine_mesh.mesh = spine_mesh.mesh.duplicate()
		(spine_mesh.mesh as BoxMesh).size = Vector3(SPINE_WIDTH, book_height + SPINE_HEIGHT_MARGIN, closed_spine_depth)
	_spine_node.position.z = 0.0

	# Hint label positions — just outside the full book width
	_next_label.position = Vector3(stack_x + half_w + HINT_LABEL_OFFSET, 0, 0)
	_prev_label.position = Vector3(-(stack_x + half_w + HINT_LABEL_OFFSET), 0, 0)

	# Collision shape will be sized per-state in _update_collision_shape()

	# Create unique materials so textures don't bleed between meshes
	_ensure_unique_material(_cover_mesh)
	_ensure_unique_material(_back_cover_mesh)
	_ensure_unique_material(_left_stack_top)
	_ensure_unique_material(_right_stack_top)


func _set_mesh_size(mesh_node: MeshInstance3D, w: float, h: float) -> void:
	if not mesh_node:
		return
	var mesh := mesh_node.mesh
	if mesh is QuadMesh:
		(mesh as QuadMesh).size = Vector2(w, h)
	elif mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(w, h)


func _ensure_unique_material(mesh_node: MeshInstance3D) -> void:
	if not mesh_node:
		return
	var mat := mesh_node.get_active_material(0)
	if mat:
		mesh_node.set_surface_override_material(0, mat.duplicate())


## Apply a texture to a MeshInstance3D's material albedo.
func _apply_texture(mesh_node: MeshInstance3D, tex: Texture2D) -> void:
	if not mesh_node or not tex:
		return
	var mat := mesh_node.get_active_material(0)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).albedo_color = Color.WHITE
		(mat as StandardMaterial3D).albedo_texture = tex
	elif mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("front_texture", tex)


## Apply a texture to the back face of a double-sided page shader.
func _apply_back_texture(mesh_node: MeshInstance3D, tex: Texture2D) -> void:
	if not mesh_node or not tex:
		return
	var mat := mesh_node.get_active_material(0)
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("back_texture", tex)


# ── State management ──────────────────────────────────────────────────────────

func _set_state(new_state: BookState) -> void:
	_state = new_state
	var half_w := _book_width / 2.0
	var stack_x := half_w + SPINE_WIDTH / 2.0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)

	match new_state:
		BookState.CLOSED:
			_cover_mesh.visible = true
			_cover_mesh.position = Vector3(stack_x, 0, total_thick / 2.0 + COVER_GAP)
			_cover_mesh.rotation_degrees = Vector3.ZERO
			_back_cover_mesh.visible = true
			_back_cover_mesh.position = Vector3(stack_x, 0, -(total_thick / 2.0 + COVER_GAP))
			_back_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_right_stack.visible = true
			_right_stack.position = Vector3(stack_x, 0, 0)
			_right_stack.scale.z = total_thick / STACK_BASE_DEPTH
			_right_stack_top.visible = false
			_left_stack.visible = false
			_set_spine_closed(total_thick)
			_update_cover_texture()
			_update_back_cover_texture()
			_prefetch_nearby_pages()
			_update_collision_shape()

		BookState.OPEN:
			_cover_mesh.visible = true
			_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_back_cover_mesh.visible = true
			_back_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_left_stack.visible = true
			_left_stack.position = Vector3(-stack_x, 0, 0)
			_left_stack_top.visible = true
			_right_stack.visible = true
			_right_stack.position = Vector3(stack_x, 0, 0)
			_right_stack_top.visible = true
			_update_cover_texture()
			_update_back_cover_texture()
			_update_spread_textures()
			_update_stack_thickness()
			_prefetch_nearby_pages()
			_update_collision_shape()

		BookState.LAST_PAGE:
			_back_cover_mesh.visible = true
			_back_cover_mesh.position = Vector3(-stack_x, 0, total_thick / 2.0 + COVER_GAP)
			_back_cover_mesh.rotation_degrees = Vector3.ZERO
			_cover_mesh.visible = true
			_cover_mesh.position = Vector3(-stack_x, 0, -(total_thick / 2.0 + COVER_GAP))
			_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_left_stack.visible = true
			_left_stack.position = Vector3(-stack_x, 0, 0)
			_left_stack.scale.z = total_thick / STACK_BASE_DEPTH
			_left_stack_top.visible = false
			_right_stack.visible = false
			_set_spine_closed(total_thick)
			_update_cover_texture()
			_update_back_cover_texture()
			_prefetch_nearby_pages()
			_update_collision_shape()


## Update the CollisionShape3D so the grab/highlight area matches the visible book.
func _update_collision_shape() -> void:
	var col_shape := $CollisionShape3D as CollisionShape3D
	if not col_shape or not col_shape.shape is BoxShape3D:
		return
	var half_w := _book_width / 2.0
	var spine_half := SPINE_WIDTH / 2.0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)
	var depth := total_thick + COVER_THICKNESS + COVER_GAP * 2 + ZFIGHT_MARGIN
	match _state:
		BookState.CLOSED:
			# Only the right stack + spine + cover is visible
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3(half_w, 0, 0)
		BookState.OPEN:
			# Both page stacks visible, spanning the full open width
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width * 2.0 + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3.ZERO
		BookState.LAST_PAGE:
			# Only the left stack + spine + back cover is visible
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3(-half_w, 0, 0)


## Set spine to full closed-book depth, centered at Z=0.
func _set_spine_closed(total_thick: float) -> void:
	var spine_mesh := _spine_node.get_node("SpineMesh") as MeshInstance3D
	if spine_mesh and spine_mesh.mesh is BoxMesh:
		(spine_mesh.mesh as BoxMesh).size.z = total_thick + COVER_THICKNESS + ZFIGHT_MARGIN
	_spine_node.position.z = 0.0


func _update_cover_texture() -> void:
	var tex := _get_page_texture(0)
	_apply_texture(_cover_mesh, tex)


func _update_back_cover_texture() -> void:
	var tex := _get_page_texture(_page_count - 1)
	_apply_texture(_back_cover_mesh, tex)


func _update_spread_textures() -> void:
	# Left page = back of current leaf (odd page index)
	var left_page_idx := _current_leaf * 2 + 1
	var left_tex := _get_page_texture(left_page_idx)
	_apply_texture(_left_stack_top, left_tex)

	# Right page = front of next leaf (even page index)
	var right_page_idx := (_current_leaf + 1) * 2
	var right_tex := _get_page_texture(right_page_idx) if right_page_idx < _page_count else null
	_apply_texture(_right_stack_top, right_tex)

	_trim_texture_cache()


func _update_stack_thickness() -> void:
	var left_count := _current_leaf + 1
	var right_count := _leaf_count - _current_leaf - 1

	var left_thick := maxf(left_count * LEAF_THICKNESS, LEAF_THICKNESS)
	var right_thick := maxf(right_count * LEAF_THICKNESS, LEAF_THICKNESS)

	if _left_stack:
		_left_stack.scale.z = left_thick / STACK_BASE_DEPTH
	if _right_stack:
		_right_stack.scale.z = right_thick / STACK_BASE_DEPTH

	# Spine spans the full book thickness in OPEN state, same as closed — centered at Z=0.
	var max_thick := maxf(left_thick, right_thick)
	var open_spine_depth := max_thick + COVER_THICKNESS + ZFIGHT_MARGIN
	var spine_mesh := _spine_node.get_node("SpineMesh") as MeshInstance3D
	if spine_mesh and spine_mesh.mesh is BoxMesh:
		(spine_mesh.mesh as BoxMesh).size.z = open_spine_depth
	_spine_node.position.z = 0.0

	# Position covers just behind their respective stacks
	var half_w := _book_width / 2.0
	var stack_x := half_w + SPINE_WIDTH / 2.0
	_cover_mesh.position = Vector3(-stack_x, 0, -(left_thick / 2.0 + COVER_GAP))
	_back_cover_mesh.position = Vector3(stack_x, 0, -(right_thick / 2.0 + COVER_GAP))


# ── Page turning ──────────────────────────────────────────────────────────────

func turn_page_forward() -> void:
	if _is_turning:
		return

	match _state:
		BookState.CLOSED:
			_current_leaf = 0
			if _leaf_count <= 1:
				_set_state(BookState.LAST_PAGE)
			else:
				_set_state(BookState.OPEN)
		BookState.OPEN:
			_current_leaf += 1
			if _current_leaf >= _leaf_count - 1:
				_set_state(BookState.LAST_PAGE)
			else:
				_update_spread_textures()
				_update_stack_thickness()
				_prefetch_nearby_pages()
		BookState.LAST_PAGE:
			pass


func turn_page_backward() -> void:
	if _is_turning:
		return

	match _state:
		BookState.LAST_PAGE:
			_current_leaf = _leaf_count - 2
			if _current_leaf < 0:
				_set_state(BookState.CLOSED)
			else:
				_set_state(BookState.OPEN)
		BookState.OPEN:
			_current_leaf -= 1
			if _current_leaf < 0:
				_set_state(BookState.CLOSED)
			else:
				_update_spread_textures()
				_update_stack_thickness()
				_prefetch_nearby_pages()
		BookState.CLOSED:
			pass


# ── Active leaf hinge system ──────────────────────────────────────────────────

func _spawn_active_leaf_forward() -> void:
	if _active_leaf:
		_despawn_active_leaf()

	_is_turning = true
	_turn_direction = 1

	var front_page_idx: int
	var back_page_idx: int

	if _state == BookState.CLOSED:
		front_page_idx = 0
		back_page_idx = 1
	else:
		front_page_idx = (_current_leaf + 1) * 2
		back_page_idx = front_page_idx + 1

	_active_leaf = _create_leaf_mesh(front_page_idx, back_page_idx)
	_active_leaf_container.add_child(_active_leaf)


func _spawn_active_leaf_backward() -> void:
	if _active_leaf:
		_despawn_active_leaf()

	_is_turning = true
	_turn_direction = -1

	var front_page_idx := _current_leaf * 2
	var back_page_idx := front_page_idx + 1

	_active_leaf = _create_leaf_mesh(front_page_idx, back_page_idx)
	_active_leaf.rotation_degrees.y = 180.0
	_active_leaf_container.add_child(_active_leaf)


func _create_leaf_mesh(front_page_idx: int, back_page_idx: int) -> Node3D:
	var leaf := Node3D.new()
	leaf.name = "ActiveLeaf"

	var front_mesh := MeshInstance3D.new()
	front_mesh.name = "FrontFace"
	var front_quad := QuadMesh.new()
	front_quad.size = Vector2(_book_width, book_height)
	front_mesh.mesh = front_quad
	var front_mat := StandardMaterial3D.new()
	front_mat.cull_mode = BaseMaterial3D.CULL_BACK
	var front_tex := _get_page_texture(front_page_idx)
	if front_tex:
		front_mat.albedo_texture = front_tex
	front_mesh.material_override = front_mat
	front_mesh.position.x = _book_width / 2.0
	leaf.add_child(front_mesh)

	var back_mesh := MeshInstance3D.new()
	back_mesh.name = "BackFace"
	var back_quad := QuadMesh.new()
	back_quad.size = Vector2(_book_width, book_height)
	back_mesh.mesh = back_quad
	var back_mat := StandardMaterial3D.new()
	back_mat.cull_mode = BaseMaterial3D.CULL_BACK
	if back_page_idx < _page_count:
		var back_tex := _get_page_texture(back_page_idx)
		if back_tex:
			back_mat.albedo_texture = back_tex
	back_mesh.material_override = back_mat
	back_mesh.position.x = _book_width / 2.0
	back_mesh.rotation_degrees.y = 180.0
	leaf.add_child(back_mesh)

	return leaf


func _despawn_active_leaf() -> void:
	if _active_leaf:
		_active_leaf.queue_free()
		_active_leaf = null
	_is_turning = false
	_turn_direction = 0


func _snap_leaf_to_completion(target_angle: float) -> void:
	if not _active_leaf:
		return
	var tween := create_tween()
	tween.tween_property(_active_leaf, "rotation_degrees:y", target_angle, 0.15)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_QUAD)
	if _turn_direction == 1:
		tween.tween_callback(_complete_forward_turn)
	else:
		tween.tween_callback(_complete_backward_turn)


func _check_snap() -> void:
	if not _active_leaf or not _is_turning:
		return
	var angle: float = _active_leaf.rotation_degrees.y
	if _turn_direction == 1 and angle >= (180.0 - snap_threshold_deg):
		_snap_leaf_to_completion(180.0)
	elif _turn_direction == -1 and angle <= snap_threshold_deg:
		_snap_leaf_to_completion(0.0)


func _process(delta: float) -> void:
	_check_snap()
	if _turn_cooldown > 0.0:
		_turn_cooldown -= delta
	_update_hints_and_detect_grip()


## Check controller proximity for hints, and detect grip for page turn.
func _update_hints_and_detect_grip() -> void:
	_next_label.visible = false
	_prev_label.visible = false

	if not is_picked_up() or _page_count == 0:
		return

	var holding_ctrl: XRController3D = get_picked_up_by_controller()
	if not holding_ctrl:
		return

	for ctrl: XRController3D in _controllers:
		if not ctrl or not ctrl.get_is_active() or ctrl == holding_ctrl:
			continue

		var ctrl_pos_local: Vector3 = to_local(ctrl.global_position)
		if absf(ctrl_pos_local.y) > book_height * 0.6:
			continue
		if absf(ctrl_pos_local.z) > 0.08:
			continue
		if absf(ctrl_pos_local.x) > _book_width + 0.05:
			continue

		# Controller is in range — show appropriate hint
		var is_right := ctrl_pos_local.x > 0.0
		if is_right and _state != BookState.LAST_PAGE:
			_next_label.visible = true
		elif not is_right and _state != BookState.CLOSED:
			_prev_label.visible = true

		# Check grip for actual page turn
		if ctrl.get_float("grip") < GRIP_THRESHOLD:
			continue
		if _turn_cooldown > 0.0:
			continue

		if is_right:
			turn_page_forward()
			_turn_cooldown = TURN_COOLDOWN_TIME
		else:
			turn_page_backward()
			_turn_cooldown = TURN_COOLDOWN_TIME
		return


func _complete_forward_turn() -> void:
	_despawn_active_leaf()
	turn_page_forward()


func _complete_backward_turn() -> void:
	_despawn_active_leaf()
	turn_page_backward()


# ── Utilities ─────────────────────────────────────────────────────────────────

func _create_loading_texture() -> void:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.9, 0.85))
	_loading_texture = ImageTexture.create_from_image(img)


func _create_hint_labels() -> void:
	_next_label = Label3D.new()
	_next_label.text = "Next Page →"
	_next_label.font_size = 32
	_next_label.pixel_size = 0.001
	_next_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_next_label.no_depth_test = true
	_next_label.modulate = Color(1, 1, 1, 0.8)
	_next_label.outline_modulate = Color(0, 0, 0, 0.6)
	_next_label.outline_size = 4
	_next_label.visible = false
	add_child(_next_label)

	_prev_label = Label3D.new()
	_prev_label.text = "← Prev Page"
	_prev_label.font_size = 32
	_prev_label.pixel_size = 0.001
	_prev_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prev_label.no_depth_test = true
	_prev_label.modulate = Color(1, 1, 1, 0.8)
	_prev_label.outline_modulate = Color(0, 0, 0, 0.6)
	_prev_label.outline_size = 4
	_prev_label.visible = false
	add_child(_prev_label)


## Pre-render pages near the current spread so they're ready before the user turns.
func _prefetch_nearby_pages() -> void:
	if _page_count == 0:
		return
	var center := _current_leaf * 2
	for i in range(maxi(0, center - prefetch_pages), mini(_page_count, center + prefetch_pages + 2)):
		_get_page_texture(i)  # triggers background render if not cached


func _cleanup() -> void:
	_render_mutex.lock()
	if _renderer and _renderer.IsOpen():
		_renderer.Close()
	_renderer = null
	_render_mutex.unlock()
	_cbz_entries.clear()
	_cbz_path = ""
	_texture_cache.clear()
	_pending_renders.clear()
	_despawn_active_leaf()
	_page_count = 0
	_leaf_count = 0
	_current_leaf = 0
