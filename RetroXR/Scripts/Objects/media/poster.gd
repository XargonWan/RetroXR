## Poster — a user image hung on a wall or stuck to an object.
##
## The image comes from ~/retroxr/posters/ (RomLibrary.scan_posters). Spawned from
## the menu, carried, and stuck to whatever surface it is released against; a stuck
## poster rides the object it is stuck to.
##
## PNG alpha is supported, so a die-cut sticker is as valid as a rectangle. The
## material for one is TRANSPARENCY_ALPHA_SCISSOR rather than ALPHA: scissor renders
## in the OPAQUE pass and keeps writing depth, and a poster that stops writing depth
## sorts per-triangle against the wall behind it and against the next poster along.
## That is the same trap paper.gdshader documents. An image with no alpha at all is
## left fully opaque — alpha testing costs early-Z on a tile GPU, so the cheap case
## must stay cheap.
class_name Poster
extends XRToolsPickable

## How the sheet is fitted to the surface it is stuck to. FLAT is always the
## default: a mode that picks itself reads as a bug, and a wall — where most
## posters go — is flat anyway.
enum FitMode { FLAT, CONFORM, DECAL }

## Longest edge, in metres, at size_scale 1.0. The short edge follows the image's
## own aspect, so a poster is never stretched.
const BASE_LONG_EDGE := 0.5
## Decoded texture cap. A runtime image gets no ETC2/ASTC, so it is resident at
## full RGBA: 2048 square is 16 MB, and a phone-camera JPEG would be far worse.
const MAX_PX_DESKTOP := 2048
const MAX_PX_QUEST := 1024
## Print has no light of its own; this is the trace the room's own posters carry.
## 0.30 was measured too hot — see BedroomScene.tscn.
const EMISSION_ENERGY := 0.1

@export var image_path: String = "":
	set(value):
		image_path = value
		if is_inside_tree():
			_load_image()

@export_range(0.25, 3.0) var size_scale: float = 1.0:
	set(value):
		size_scale = clampf(value, 0.25, 3.0)
		if is_inside_tree():
			_apply_dimensions()

@export var fit_mode: FitMode = FitMode.FLAT

@onready var _surface: Node3D = $Surface
@onready var _flat_mesh: MeshInstance3D = $Surface/FlatMesh
@onready var _body_shape: CollisionShape3D = $CollisionShape3D
@onready var _pointer_shape: CollisionShape3D = $PointerArea/CollisionShape3D
@onready var _ray: RayCast3D = $SurfaceRay

var _stick: SurfaceStick = null
## Set from a save before _ready, so a restored poster re-parks itself instead of
## dropping off the wall while the room finishes loading.
var stuck_from_save := false

## Image aspect (width / height). 1.0 until an image loads.
var _aspect: float = 1.0
var _texture: Texture2D = null


func _ready() -> void:
	super._ready()
	add_to_group("poster")
	_stick = SurfaceStick.attach(self, _ray)
	# A grab IS the peel: every hold restores `freeze` itself, so there is no
	# separate verb and nothing to teach.
	picked_up.connect(func(_p: Node3D) -> void: _stick.peel())
	if not image_path.is_empty():
		_load_image()
	else:
		_apply_dimensions()
	if stuck_from_save:
		# Deferred twice over: the body has not reached its restored pose at
		# _ready, and the restore's own _let_go hands gravity back to everything
		# it froze a pass later.
		_repark_after_restore.call_deferred()


## True while the sheet is committed to a surface.
func is_stuck() -> bool:
	return _stick != null and _stick.is_stuck()


func stick_target() -> Node3D:
	return _stick.target if _stick != null else null


## A restored poster comes back at its saved WORLD pose, parented to the room —
## not under the host it was riding, because the walk that saves it is over the
## "spawned" group and _base() records a global transform.
##
## So it re-probes rather than restoring a reference: the surface it was stuck to
## has been restored to its own saved pose too, and the sheet still sits 2 mm off
## it, so the same short ray that stuck it the first time finds it again. That also
## self-heals when the room changed underneath the save, where a stored reference
## would only be able to fail.
func _repark_after_restore() -> void:
	if _stick == null:
		return
	_stick.try_stick()


## Metres, as currently sized. Width first.
func get_sheet_size() -> Vector2:
	var long_edge := BASE_LONG_EDGE * size_scale
	if _aspect >= 1.0:
		return Vector2(long_edge, long_edge / _aspect)
	return Vector2(long_edge * _aspect, long_edge)


# ── Image ─────────────────────────────────────────────────────────────────────

## Decode the user's file and build the sheet's material.
##
## A file dropped in the posters folder never passes through Godot's import
## pipeline, so the three things an imported texture would have arrived with have
## to be done by hand here: a size cap, mipmaps, and an alpha-edge fix.
func _load_image() -> void:
	_texture = null
	if not image_path.is_empty():
		var img := Image.load_from_file(image_path)
		if img == null:
			push_warning("Poster: cannot read image '%s'" % image_path)
		else:
			var cap := MAX_PX_DESKTOP if QualityManager.is_desktop() else MAX_PX_QUEST
			_fit_within(img, cap)
			var alpha := img.detect_alpha()
			if alpha != Image.ALPHA_NONE:
				# Bleeds colour into fully transparent texels. Without it, mip
				# averaging pulls their (often black) RGB into the cut edge and the
				# sticker wears a dark fringe — and the emission pass would print
				# that fringe a second time.
				img.fix_alpha_edges()
			img.generate_mipmaps()
			_texture = ImageTexture.create_from_image(img)
			_aspect = float(img.get_width()) / maxf(1.0, float(img.get_height()))
			_flat_mesh.set_surface_override_material(0, _build_material(_texture, alpha))
	_apply_dimensions()


func _build_material(tex: Texture2D, alpha: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = 0.9
	# A sheet has no back worth culling, and a poster on a pillar is read from both
	# sides of the doorway.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if alpha != Image.ALPHA_NONE:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
	mat.emission_enabled = true
	mat.emission_texture = tex
	mat.emission_energy_multiplier = EMISSION_ENERGY
	return mat


## Aspect-preserving downscale to a square bound. One scalar in, both edges out —
## which is also why size_scale cannot stretch a poster.
static func _fit_within(img: Image, cap: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0 or (w <= cap and h <= cap):
		return
	var factor: float = minf(float(cap) / float(w), float(cap) / float(h))
	img.resize(maxi(1, int(round(w * factor))), maxi(1, int(round(h * factor))),
		Image.INTERPOLATE_LANCZOS)


# ── Dimensions ────────────────────────────────────────────────────────────────

## The one place the sheet's size is written. Everything that has to agree with it
## — the quad, the body's collider and the pointer target — is set from the same
## two numbers, so none of them can drift apart.
func _apply_dimensions() -> void:
	if _flat_mesh == null:
		return
	var size := get_sheet_size()
	var quad := _flat_mesh.mesh as QuadMesh
	if quad != null:
		quad.size = size
	# 2 mm of thickness: enough for a grab and for the pointer to find, thin enough
	# that a poster flat against a wall does not read as a board.
	var box := _body_shape.shape as BoxShape3D
	if box != null:
		box.size = Vector3(size.x, size.y, 0.002)
	var ptr := _pointer_shape.shape as BoxShape3D
	if ptr != null:
		# Slightly proud of the sheet so aiming at a poster is not a pixel hunt.
		ptr.size = Vector3(size.x + 0.02, size.y + 0.02, 0.02)
