## PickableHighlight — add as a child of any XRToolsPickable.
## Automatically builds outline overlay meshes for every MeshInstance3D direct-child
## of the parent and manages three visual states:
##   - Ray hovering  → white   (highlight_updated signal on parent pickable)
##   - Ray held      → yellow  (has_picked_up on XRToolsFunctionPickup nodes, ray-grab path)
##   - Hand held     → blue    (picked_up / dropped signals on parent pickable, hand-grab path)
##
## Why the two separate paths: godot-xr-tools ray-grab bypasses the pickable's
## picked_up/grabbed signals entirely and only emits has_picked_up on the pickup
## function node. Hand-grab emits picked_up/dropped on the pickable as normal.
##
## Uses a two-pass fake-stencil technique (no SubViewport, works in VR stereo).
## See outline.gdshader for a detailed explanation.
extends Node3D

const OUTLINE_SHADER       := preload("res://Shaders/outline.gdshader")
const DEPTH_PREPASS_SHADER := preload("res://Shaders/outline_depth_prepass.gdshader")

## Color shown while the pointer ray is hovering over the object.
@export var hover_color: Color = Color(1.0, 1.0, 1.0, 1.0)
## Color shown while the object is held by the ray (ranged grab).
@export var ray_color:   Color = Color(1.0, 0.85, 0.0, 1.0)
## Color shown while the object is held by a physical hand grab.
@export var held_color:  Color = Color(0.25, 0.6, 1.0, 1.0)

@export_range(0.0, 0.05, 0.001) var shell_width: float = 0.012
## Primary outline thickness — screen-space, consistent at any distance.
@export_range(0.0, 2.0, 0.01)   var perspective_width: float = 0.8
## Width of the outline band. Small = crisp edge, large = wide glow halo.
@export_range(0.001, 1.0, 0.01) var edge_softness: float = 0.5
@export_range(0.0, 8.0, 0.1)    var glow_strength: float = 2.0
@export_range(0.0, 10.0, 0.1)   var fade_start: float = 0.0
@export_range(0.1, 50.0, 0.1)   var fade_end: float = 10.0

var _outline_material: ShaderMaterial
var _depth_material: ShaderMaterial
var _overlays: Array[MeshInstance3D] = []
var _overlay_sources: Array[MeshInstance3D] = []  # parallel to _overlays

var _is_highlighted: bool = false
var _is_ray_held:    bool = false
var _is_hand_held:   bool = false
var _ray_grabber:    Node = null   # which XRToolsFunctionPickup is ray-holding us


func _ready() -> void:
	set_process(false)  # enabled only while overlays are visible
	# Pass 2: the visible outline.
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = OUTLINE_SHADER
	_outline_material.render_priority = 2
	_sync_material_params()

	# Pass 1: invisible depth prepass — writes depth as the stencil mask.
	_depth_material = ShaderMaterial.new()
	_depth_material.shader = DEPTH_PREPASS_SHADER
	_depth_material.render_priority = 1
	_depth_material.next_pass = _outline_material

	var parent := get_parent()
	if parent and parent.has_signal("highlight_updated"):
		parent.highlight_updated.connect(_on_highlight_updated)
	else:
		push_warning("PickableHighlight: parent has no highlight_updated signal")
		return

	# Hand-grab path: these signals only fire for physical hand grabs.
	if parent.has_signal("picked_up"):
		parent.picked_up.connect(_on_hand_picked_up)
	if parent.has_signal("dropped"):
		parent.dropped.connect(_on_hand_dropped)

	# Ray-grab path: connect deferred so the full scene tree is available.
	_connect_pickup_nodes.call_deferred()
	_build_overlays.call_deferred()


func _build_overlays() -> void:
	var parent := get_parent()
	if not parent:
		return

	for child in parent.get_children():
		if child is MeshInstance3D and child != self:
			var overlay := MeshInstance3D.new()
			overlay.mesh = child.mesh
			overlay.transform = child.transform
			overlay.material_override = _depth_material  # pass 1 → pass 2 via next_pass
			overlay.visible = false
			overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			overlay.extra_cull_margin = 16.0
			add_child(overlay)
			_overlays.append(overlay)
			_overlay_sources.append(child as MeshInstance3D)


func _connect_pickup_nodes() -> void:
	# Find every XRToolsFunctionPickup in the scene and hook its ray-grab signals.
	for node in get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false):
		node.has_picked_up.connect(_on_ray_picked_up.bind(node))
		node.has_dropped.connect(_on_ray_dropped.bind(node))


# --- Signal handlers ---

func _on_highlight_updated(_object: Node, highlighted: bool) -> void:
	_is_highlighted = highlighted
	_update_state()


func _on_hand_picked_up(_pickable) -> void:
	_is_hand_held = true
	_update_state()


func _on_hand_dropped(_pickable) -> void:
	_is_hand_held = false
	_update_state()


func _on_ray_picked_up(what: Node3D, pickup: Node) -> void:
	if what != get_parent():
		return
	_is_ray_held = true
	_ray_grabber = pickup
	_update_state()


func _on_ray_dropped(pickup: Node) -> void:
	if pickup != _ray_grabber:
		return
	_is_ray_held = false
	_ray_grabber = null
	_update_state()


# --- State machine ---

func _update_state() -> void:
	if _is_hand_held:
		_set_color(held_color)
		_set_overlays_visible(true)
	elif _is_ray_held:
		_set_color(ray_color)
		_set_overlays_visible(true)
	elif _is_highlighted:
		_set_color(hover_color)
		_set_overlays_visible(true)
	else:
		_set_overlays_visible(false)


func _set_overlays_visible(show: bool) -> void:
	set_process(show)
	for i in range(_overlays.size()):
		var overlay := _overlays[i]
		if not is_instance_valid(overlay):
			continue
		if show and i < _overlay_sources.size() and is_instance_valid(_overlay_sources[i]):
			var src := _overlay_sources[i]
			overlay.transform = src.transform
			overlay.visible = src.visible
		else:
			overlay.visible = false


func _process(_delta: float) -> void:
	# Only runs while overlays are active (set_process toggles this).
	# Keeps overlay transforms and visibility in sync with source meshes
	# that move/hide as book state changes.
	for i in range(mini(_overlays.size(), _overlay_sources.size())):
		var overlay := _overlays[i]
		var src := _overlay_sources[i]
		if is_instance_valid(overlay) and is_instance_valid(src):
			overlay.transform = src.transform
			overlay.visible = src.visible


func _set_color(color: Color) -> void:
	_outline_material.set_shader_parameter("outline_color", color)


func _sync_material_params() -> void:
	if not _outline_material:
		return
	_outline_material.set_shader_parameter("outline_color", hover_color)
	_outline_material.set_shader_parameter("shell_width", shell_width)
	_outline_material.set_shader_parameter("perspective_width", perspective_width)
	_outline_material.set_shader_parameter("edge_softness", edge_softness)
	_outline_material.set_shader_parameter("glow_strength", glow_strength)
	_outline_material.set_shader_parameter("fade_start", fade_start)
	_outline_material.set_shader_parameter("fade_end", fade_end)
