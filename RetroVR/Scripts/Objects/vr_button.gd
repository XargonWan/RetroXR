## VRButton — Node3D that emits button_pressed when a VR controller touches it.
## Attach to any Area3D that has a child MeshInstance3D named "ButtonMesh".
## Uses direct XRController3D proximity checks each frame instead of physics
## bodies, so it reliably fires exactly where the controller/hand visually is.
## Also supports desktop reticle pointer hover/press.
class_name VRButton
extends Area3D


signal button_pressed

const POINTABLE_LAYER := 1 << 20
const OUTLINE_SHADER := preload("res://Shaders/outline.gdshader")
const DEPTH_PREPASS_SHADER := preload("res://Shaders/outline_depth_prepass.gdshader")
const HOVER_OUTLINE_COLOR := Color(0.65, 1.0, 0.65, 1.0)


## How close (metres) the controller tip must be to trigger the button.
## The button face is at the top of the mesh, so ~half the mesh height is a
## good starting threshold.
@export var trigger_radius: float = 0.04

## How much the mesh travels when pressed (metres)
@export var depress_depth: float = 0.008

## Direction the mesh moves when pressed, in the mesh PARENT's local space.
## Default (0,-1,0) pushes down on Y.  For front-face buttons derive it from
## the model's Finger Button empty's -Z axis via set_depress_axis_from_node().
@export var depress_axis: Vector3 = Vector3(0, -1, 0)

# Cached original local position of the active mesh (in its parent's space)
var _mesh_local_origin: Vector3
# Parent node of the active mesh — used for direction-space conversion
var _mesh_depress_parent: Node3D = null

# Visual state
var _touch_pressed: bool = false
var _pointer_pressed: bool = false
var _pointer_hovered: bool = false
var _latched_pressed: bool = false

@onready var _mesh: MeshInstance3D = $ButtonMesh

# Controller nodes — resolved once in _ready
var _controllers: Array[XRController3D] = []
var _outline_overlay: MeshInstance3D = null
var _outline_material: ShaderMaterial = null


func _ready() -> void:
	collision_layer |= POINTABLE_LAYER
	_mesh_local_origin = _mesh.position
	_mesh_depress_parent = _mesh.get_parent() as Node3D
	_rebuild_outline()
	# Controllers aren't added until the first frame, so wait one frame
	await get_tree().process_frame
	# Find all XRController3D nodes in the scene by type
	var all := get_tree().root.find_children("*", "XRController3D", true, false)
	for node in all:
		_controllers.append(node as XRController3D)


func _process(_delta: float) -> void:
	_sync_outline()

	if _controllers.is_empty():
		return

	# Check whether any controller tip is inside our trigger radius
	var touching := false
	for controller in _controllers:
		if not controller.get_is_active():
			continue
		var dist: float = global_position.distance_to(PokeTip.tip_of(controller))
		if dist <= trigger_radius:
			touching = true
			break

	if touching and not _touch_pressed:
		_touch_pressed = true
		_update_visual_state()
		button_pressed.emit()
	elif not touching and _touch_pressed:
		_touch_pressed = false
		_update_visual_state()


func pointer_event(event: XRToolsPointerEvent) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_hovered = true
			_update_visual_state()
		XRToolsPointerEvent.Type.EXITED:
			_pointer_hovered = false
			_pointer_pressed = false
			_update_visual_state()
		XRToolsPointerEvent.Type.PRESSED:
			_pointer_hovered = true
			_pointer_pressed = true
			_update_visual_state()
			button_pressed.emit()
		XRToolsPointerEvent.Type.RELEASED:
			_pointer_pressed = false
			_update_visual_state()


## Swap the mesh used for the depress animation and hide the original ButtonMesh child.
## Call this from a system model after the GLB has loaded to drive the real geometry.
func set_button_mesh(mesh: MeshInstance3D) -> void:
	var old := get_node_or_null("ButtonMesh") as MeshInstance3D
	if old:
		old.hide()
	_mesh = mesh
	_mesh_local_origin = mesh.position
	_mesh_depress_parent = mesh.get_parent() as Node3D
	_rebuild_outline()
	_update_visual_state()


## Derive the depress axis from a GLB "Finger Button" empty node.
## GLTF finger-button empties are oriented so their local -Z points in the direction
## of travel.  This converts that to the button mesh's local space.
func set_depress_axis_from_node(finger_node: Node3D) -> void:
	# Global -Z of the finger empty = travel direction in world space.
	# Convert to mesh parent's local space so that _mesh.position offsets work correctly.
	var world_dir := -finger_node.global_transform.basis.z.normalized()
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir
	else:
		depress_axis = world_dir


## Set the depress travel direction from a WORLD-space direction (converted to the
## button mesh's parent local space). Use when a GLB's finger-button empties don't
## encode the travel axis reliably — e.g. after the model itself has been rotated.
func set_depress_axis_world(world_dir: Vector3) -> void:
	var parent := _mesh_depress_parent if _mesh_depress_parent else _mesh.get_parent() as Node3D
	if parent:
		depress_axis = parent.global_transform.basis.inverse() * world_dir.normalized()
	else:
		depress_axis = world_dir.normalized()


## Set the button's visual color by changing its material albedo
func set_color(color: Color) -> void:
	if not _mesh:
		return
	_apply_mesh_color(color)


func set_latched_pressed(pressed: bool) -> void:
	_latched_pressed = pressed
	_update_visual_state()


func _update_visual_state() -> void:
	if not _mesh:
		return

	if _touch_pressed or _pointer_pressed or _latched_pressed:
		# depress_axis may already encode inverse parent scale from
		# set_depress_axis_from_node(), so do not renormalize it here.
		_mesh.position = _mesh_local_origin + depress_axis * depress_depth
	else:
		_mesh.position = _mesh_local_origin

func _apply_mesh_color(color: Color) -> void:
	# Get or create a per-instance material override.
	# Scene sub-resources are shared across instances, so duplicate on first use.
	var mat := _mesh.get_surface_override_material(0)
	if not mat or not mat is StandardMaterial3D:
		mat = StandardMaterial3D.new()
		_mesh.set_surface_override_material(0, mat)
	elif not mat.resource_local_to_scene:
		mat = mat.duplicate() as StandardMaterial3D
		_mesh.set_surface_override_material(0, mat)
	(mat as StandardMaterial3D).albedo_color = color


func _rebuild_outline() -> void:
	if is_instance_valid(_outline_overlay):
		_outline_overlay.queue_free()
	_outline_overlay = null
	_outline_material = null

	if not _mesh or not _mesh.mesh:
		return

	_outline_material = ShaderMaterial.new()
	_outline_material.shader = OUTLINE_SHADER
	_outline_material.render_priority = 2
	_outline_material.set_shader_parameter("outline_color", HOVER_OUTLINE_COLOR)
	_outline_material.set_shader_parameter("outline_width", 1.0)
	_outline_material.set_shader_parameter("glow_strength", 2.0)
	_outline_material.set_shader_parameter("fade_start", 0.0)
	_outline_material.set_shader_parameter("fade_end", 10.0)
	_outline_material.set_shader_parameter("mesh_center", _mesh.mesh.get_aabb().get_center())

	var depth_mat := ShaderMaterial.new()
	depth_mat.shader = DEPTH_PREPASS_SHADER
	depth_mat.render_priority = 1
	depth_mat.next_pass = _outline_material

	_outline_overlay = MeshInstance3D.new()
	_outline_overlay.top_level = true
	_outline_overlay.mesh = _mesh.mesh
	_outline_overlay.material_override = depth_mat
	_outline_overlay.visible = false
	_outline_overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_outline_overlay.extra_cull_margin = 16.0
	add_child(_outline_overlay)
	_sync_outline()


func _sync_outline() -> void:
	if not is_instance_valid(_outline_overlay) or not is_instance_valid(_mesh):
		return

	if _outline_overlay.mesh != _mesh.mesh:
		_outline_overlay.mesh = _mesh.mesh
		if _outline_material and _mesh.mesh:
			_outline_material.set_shader_parameter("mesh_center", _mesh.mesh.get_aabb().get_center())

	_outline_overlay.global_transform = _mesh.global_transform
	_outline_overlay.visible = _pointer_hovered and _mesh.is_visible_in_tree()
