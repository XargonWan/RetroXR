## PDFBook — A VR-holdable book that displays PDF pages.
##
## Spawn via spawn menu (manual button) or instantiate and call load_pdf().
## Uses an "active leaf" system: only one physics hinge exists at a time for
## page turning; all other pages are static textures on stack meshes.
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

# ── Internal state ────────────────────────────────────────────────────────────

enum BookState { CLOSED, OPEN, LAST_PAGE }

var _state: BookState = BookState.CLOSED
var _page_count: int = 0
var _leaf_count: int = 0

## Current spread index. When open, the left page shows leaf[current_leaf].back,
## and the right page shows leaf[current_leaf+1].front.
## 0 = cover just opened (left = page 1, right = page 2).
var _current_leaf: int = 0

var _renderer: RefCounted = null  # PDFRenderer instance
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

# The currently active turning leaf (XRToolsInteractableHinge or similar)
var _active_leaf: Node3D = null
var _is_turning: bool = false
var _turn_direction: int = 0  # 1 = forward, -1 = backward
var _loading: bool = false  # re-entry guard for load_pdf ↔ setter

# VR page turning
var _controllers: Array = []  # all XRController3D nodes
var _turn_cooldown: float = 0.0
const TURN_COOLDOWN_TIME := 0.5
const GRIP_THRESHOLD := 0.3
const GRIP_DETECT_RADIUS := 0.15  # meters from page center

# Loading placeholder texture
var _loading_texture: ImageTexture = null


func _ready() -> void:
	super._ready()
	_create_loading_texture()
	# Cache XR controllers for page turn detection
	await get_tree().process_frame
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)
	if not pdf_path.is_empty():
		load_pdf(pdf_path)


## Open a PDF file and configure the book.
func load_pdf(path: String) -> void:
	_cleanup()
	_loading = true
	pdf_path = path
	_loading = false

	# Create PDFRenderer instance
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

	# Get page dimensions from first page (aspect ratio)
	var size: Vector2 = _renderer.GetPageSize(0)
	_page_width = size.x
	_page_height = size.y

	if _page_height > 0:
		var aspect := _page_width / _page_height
		_book_width = book_height * aspect
	else:
		_book_width = book_height * 0.7  # fallback ~letter ratio

	# Set up disk cache
	_cache_dir = "user://pdf_cache/" + path.md5_text() + "/"
	DirAccess.make_dir_recursive_absolute(_cache_dir)

	_configure_meshes()
	_set_state(BookState.CLOSED)
	_update_cover_texture()

	print("[PDFBook] Loaded: %s (%d pages, %d leaves, %.2f x %.2f m)" % [
		path, _page_count, _leaf_count, _book_width, book_height])


## Get a page texture, loading from cache or rendering on demand.
func _get_page_texture(page_index: int) -> ImageTexture:
	if page_index < 0 or page_index >= _page_count:
		return null

	# Check memory cache
	if _texture_cache.has(page_index):
		return _texture_cache[page_index]

	# Check disk cache
	var cache_path := _cache_dir + "page_%03d.png" % page_index
	if FileAccess.file_exists(cache_path):
		var img := Image.load_from_file(cache_path)
		if img:
			var tex := ImageTexture.create_from_image(img)
			_texture_cache[page_index] = tex
			return tex

	# Render the page
	if not _renderer or not _renderer.IsOpen():
		return _loading_texture

	var img: Image = _renderer.RenderPage(page_index, render_dpi)
	if not img:
		return _loading_texture

	# Save to disk cache
	img.save_png(cache_path)

	var tex := ImageTexture.create_from_image(img)
	_texture_cache[page_index] = tex
	return tex


## Unload textures that are far from the current spread to save VRAM.
func _trim_texture_cache() -> void:
	var keep_min := maxi(0, (_current_leaf * 2) - 4)
	var keep_max := mini(_page_count - 1, (_current_leaf * 2) + 6)
	var to_remove: Array[int] = []
	for key: int in _texture_cache:
		if key < keep_min or key > keep_max:
			to_remove.append(key)
	for key: int in to_remove:
		_texture_cache.erase(key)


## Configure mesh sizes based on PDF aspect ratio.
func _configure_meshes() -> void:
	# Cover mesh — full page size
	_set_mesh_size(_cover_mesh, _book_width, book_height)
	_set_mesh_size(_back_cover_mesh, _book_width, book_height)
	_set_mesh_size(_left_stack_top, _book_width, book_height)
	_set_mesh_size(_right_stack_top, _book_width, book_height)


## Set a MeshInstance3D's QuadMesh size (assumes QuadMesh or PlaneMesh).
func _set_mesh_size(mesh_node: MeshInstance3D, w: float, h: float) -> void:
	if not mesh_node:
		return
	var mesh := mesh_node.mesh
	if mesh is QuadMesh:
		(mesh as QuadMesh).size = Vector2(w, h)
	elif mesh is PlaneMesh:
		(mesh as PlaneMesh).size = Vector2(w, h)


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
	match new_state:
		BookState.CLOSED:
			_cover_mesh.visible = true
			_back_cover_mesh.visible = true
			_left_stack.visible = false
			_right_stack.visible = false
			_update_back_cover_texture()
		BookState.OPEN:
			_cover_mesh.visible = false
			_back_cover_mesh.visible = false
			_left_stack.visible = true
			_right_stack.visible = true
			_update_spread_textures()
			_update_stack_thickness()
		BookState.LAST_PAGE:
			_cover_mesh.visible = false
			_back_cover_mesh.visible = true
			_left_stack.visible = false
			_right_stack.visible = false
			_update_back_cover_texture()


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
	# Each leaf ≈ 0.001m thick
	var leaf_thickness := 0.001
	var left_count := _current_leaf + 1  # leaves that have been turned
	var right_count := _leaf_count - _current_leaf - 1  # leaves remaining

	if _left_stack:
		var left_thick := maxf(left_count * leaf_thickness, 0.001)
		_left_stack.scale.z = left_thick / 0.001  # assuming base mesh is 0.001m thick
	if _right_stack:
		var right_thick := maxf(right_count * leaf_thickness, 0.001)
		_right_stack.scale.z = right_thick / 0.001


# ── Page turning ──────────────────────────────────────────────────────────────

## Called when the user grips the right stack to turn forward.
func turn_page_forward() -> void:
	if _is_turning:
		return

	match _state:
		BookState.CLOSED:
			# Open the cover
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
		BookState.LAST_PAGE:
			pass  # Already at the end


## Called when the user grips the left stack to turn backward.
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
		BookState.CLOSED:
			pass  # Already at the beginning


# ── Active leaf hinge system ──────────────────────────────────────────────────

## Spawn the active turning leaf for a forward page turn.
func _spawn_active_leaf_forward() -> void:
	if _active_leaf:
		_despawn_active_leaf()

	_is_turning = true
	_turn_direction = 1

	# The leaf being turned: front = right page (even), back = left page after turn (odd)
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


## Spawn the active turning leaf for a backward page turn.
func _spawn_active_leaf_backward() -> void:
	if _active_leaf:
		_despawn_active_leaf()

	_is_turning = true
	_turn_direction = -1

	var front_page_idx := _current_leaf * 2
	var back_page_idx := front_page_idx + 1

	_active_leaf = _create_leaf_mesh(front_page_idx, back_page_idx)
	_active_leaf.rotation_degrees.y = 180.0  # starts fully turned
	_active_leaf_container.add_child(_active_leaf)


## Create a thin leaf mesh with front and back textures.
func _create_leaf_mesh(front_page_idx: int, back_page_idx: int) -> Node3D:
	var leaf := Node3D.new()
	leaf.name = "ActiveLeaf"

	# Front face
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
	front_mesh.position.x = _book_width / 2.0  # pivot at left edge (spine)
	leaf.add_child(front_mesh)

	# Back face (rotated 180° around Y so it faces the other direction)
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


## Remove the active leaf and finalize the page turn.
func _despawn_active_leaf() -> void:
	if _active_leaf:
		_active_leaf.queue_free()
		_active_leaf = null
	_is_turning = false
	_turn_direction = 0


## Snap the active leaf to completion with a short tween.
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


## Check if the active leaf is close enough to snap (called from _process).
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
		return
	_detect_page_grip()


## Detect a second controller gripping near the left/right page to turn.
func _detect_page_grip() -> void:
	if not is_picked_up() or _page_count == 0:
		return

	var holding_ctrl: XRController3D = get_picked_up_by_controller()
	if not holding_ctrl:
		return

	for ctrl: XRController3D in _controllers:
		if not ctrl or not ctrl.get_is_active() or ctrl == holding_ctrl:
			continue
		if ctrl.get_float("grip") < GRIP_THRESHOLD:
			continue

		# Check if this controller is close enough to the book
		var ctrl_pos_local: Vector3 = to_local(ctrl.global_position)
		# Book is oriented with pages along X axis; left is -X, right is +X
		if absf(ctrl_pos_local.y) > book_height * 0.6:
			continue
		if absf(ctrl_pos_local.z) > 0.08:
			continue
		if absf(ctrl_pos_local.x) > _book_width + 0.05:
			continue

		if ctrl_pos_local.x > 0.0:
			# Gripping right side → turn forward
			turn_page_forward()
			_turn_cooldown = TURN_COOLDOWN_TIME
			return
		else:
			# Gripping left side → turn backward
			turn_page_backward()
			_turn_cooldown = TURN_COOLDOWN_TIME
			return


## Complete a forward page turn (called when hinge reaches ~180°).
func _complete_forward_turn() -> void:
	_despawn_active_leaf()
	turn_page_forward()


## Complete a backward page turn (called when hinge reaches ~0°).
func _complete_backward_turn() -> void:
	_despawn_active_leaf()
	turn_page_backward()


# ── Utilities ─────────────────────────────────────────────────────────────────

func _create_loading_texture() -> void:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.9, 0.85))  # cream/paper color
	_loading_texture = ImageTexture.create_from_image(img)


func _cleanup() -> void:
	if _renderer and _renderer.IsOpen():
		_renderer.Close()
	_renderer = null
	_texture_cache.clear()
	_despawn_active_leaf()
	_page_count = 0
	_leaf_count = 0
	_current_leaf = 0
