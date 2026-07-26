## WidgetOutline — a single-mesh stencil outline overlay for the physical VR
## widgets (VRButton, VRSlider). Create one with WidgetOutline.attach(self), point
## it at a source MeshInstance3D with set_source(), then call sync(show) each frame.
##
## This is the single-mesh sibling of PickableHighlight (which walks a whole
## pickable's mesh tree). Both draw the same two-pass stencil outline:
##   1. outline_mask.gdshader   (render_priority 1) stamps the mesh's screen
##      footprint into the stencil buffer as ref 2, invisibly.
##   2. outline.gdshader        (render_priority 2, chained via next_pass) draws
##      the normal-inflated hull where the stencil is NOT 2 — i.e. only the ring
##      outside the footprint.
##
## The ref values MUST match: outline.gdshader reads `compare_not_equal, 2`, so a
## mask that writes anything else leaves the test passing over the mesh interior
## and the "outline" fills in solid. (VRButton used to chain the stale
## outline_depth_prepass.gdshader, which writes ref 1 — that is exactly the bug
## this helper exists to stop recurring.)
##
## The overlay mesh is PickableHighlight's smoothed-normal copy, not the raw mesh:
## hard edges duplicate vertices with diverging normals, and inflating along those
## tears the hull open at corners — very visible on box-shaped button caps. That
## helper is static and caches by mesh RID, so overlays share one copy repo-wide.
class_name WidgetOutline
extends MeshInstance3D

## Armed — the fingertip is inside the interaction box and the trigger will act.
const HOVER_COLOR := Color(0.35, 1.0, 0.45, 1.0)
## Engaged — the trigger is down. Matches VRHinge's ICON_HELD amber.
const ACTIVE_COLOR := Color(1.0, 0.82, 0.28, 1.0)

const OUTLINE_SHADER := preload("res://Shaders/outline.gdshader")
const OUTLINE_MASK_SHADER := preload("res://Shaders/outline_mask.gdshader")

# Mild HDR glow — enough to read as "hovered" without blooming out under the
# room's glow post-process (2.0 rendered green x3, far too bright).
const GLOW_STRENGTH := 0.3
# Wider than PickableHighlight's 1.0: a pickable's outline only has to say "this
# is the thing under your ray", while this one is an affordance you read at arm's
# length on a 1680x1760 eye buffer. At 1.0 it aliases into a dashed hairline.
const OUTLINE_WIDTH := 2.0
const FADE_START := 0.0
const FADE_END := 10.0

var _outline_material: ShaderMaterial = null
var _source: MeshInstance3D = null
# Source mesh the current overlay was built from, so sync() can notice a swap
# (set_button_mesh / set_knob_mesh adopt GLB geometry after load).
var _built_from: Mesh = null


## Build an outline overlay and parent it to owner_node.
static func attach(owner_node: Node3D) -> WidgetOutline:
	var overlay := WidgetOutline.new()
	overlay.name = "WidgetOutline"
	owner_node.add_child(overlay)
	return overlay


func _init() -> void:
	# top_level: the overlay is driven from the source's GLOBAL transform in
	# sync(), so it must not inherit the widget Area3D's transform as well.
	top_level = true
	visible = false
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The inflated hull can reach outside the source mesh's AABB; without this the
	# overlay pops out at glancing angles.
	extra_cull_margin = 16.0

	_outline_material = ShaderMaterial.new()
	_outline_material.shader = OUTLINE_SHADER
	_outline_material.render_priority = 2
	_outline_material.set_shader_parameter("outline_color", HOVER_COLOR)
	_outline_material.set_shader_parameter("outline_width", OUTLINE_WIDTH)
	_outline_material.set_shader_parameter("glow_strength", GLOW_STRENGTH)
	_outline_material.set_shader_parameter("fade_start", FADE_START)
	_outline_material.set_shader_parameter("fade_end", FADE_END)

	var mask := ShaderMaterial.new()
	mask.shader = OUTLINE_MASK_SHADER
	mask.render_priority = 1
	mask.next_pass = _outline_material
	material_override = mask


## Point the overlay at the mesh it should trace. Safe to call repeatedly.
func set_source(src: MeshInstance3D) -> void:
	_source = src
	_rebuild()


func set_color(color: Color) -> void:
	if _outline_material:
		_outline_material.set_shader_parameter("outline_color", color)


## Draw even when the source mesh is hidden. Off by default — an outline around
## something you cannot see is normally a bug.
##
## VRSlider turns it on. Its authored "KnobMesh" is a deliberately hidden
## PLACEHOLDER: the baked handheld scenes size and place it over the shell's real
## switch cap, then hide it because the GLB already draws that cap. So the thing
## being outlined IS on screen, just not the node the outline is sourced from —
## which this check cannot tell apart from a genuinely hidden widget.
var outline_hidden_source: bool = false


## Show or hide the outline and keep it locked to the source. Call every frame.
func sync(show: bool) -> void:
	if not is_instance_valid(_source):
		visible = false
		return
	# Pick up a runtime mesh swap on the source itself.
	if _source.mesh != _built_from:
		_rebuild()
	if not show or mesh == null \
			or not (outline_hidden_source or _source.is_visible_in_tree()):
		visible = false
		return
	global_transform = _source.global_transform
	visible = true


func _rebuild() -> void:
	if not is_instance_valid(_source) or _source.mesh == null:
		mesh = null
		_built_from = null
		visible = false
		return
	_built_from = _source.mesh
	mesh = PickableHighlight._get_outline_mesh(_built_from)
