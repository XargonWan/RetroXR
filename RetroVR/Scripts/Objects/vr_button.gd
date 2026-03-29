## VRButton — Node3D that emits button_pressed when a VR controller touches it.
## Attach to any Area3D that has a child MeshInstance3D named "ButtonMesh".
## Uses direct XRController3D proximity checks each frame instead of physics
## bodies, so it reliably fires exactly where the controller/hand visually is.
class_name VRButton
extends Area3D


signal button_pressed


## How close (metres) the controller tip must be to trigger the button.
## The button face is at the top of the mesh, so ~half the mesh height is a
## good starting threshold.
@export var trigger_radius: float = 0.04

## How much the mesh travels when pressed (metres)
@export var depress_depth: float = 0.008

## Direction the mesh moves when pressed, in the mesh's LOCAL space.
## Default (0,-1,0) pushes down on Y.  For front-face buttons use (0,0,-1) or
## derive it from the model's Finger Button empty's -Z axis via set_depress_axis_from_node().
@export var depress_axis: Vector3 = Vector3(0, -1, 0)

# Cached original local position of ButtonMesh
var _mesh_origin: Vector3

# Whether the button is currently held down
var _is_pressed: bool = false

@onready var _mesh: MeshInstance3D = $ButtonMesh

# Controller nodes — resolved once in _ready
var _controllers: Array[XRController3D] = []


func _ready() -> void:
	_mesh_origin = _mesh.position
	# Controllers aren't added until the first frame, so wait one frame
	await get_tree().process_frame
	# Find all XRController3D nodes in the scene by type
	var all := get_tree().root.find_children("*", "XRController3D", true, false)
	for node in all:
		_controllers.append(node as XRController3D)


func _process(_delta: float) -> void:
	if _controllers.is_empty():
		return

	# Check whether any controller tip is inside our trigger radius
	var touching := false
	for controller in _controllers:
		if not controller.get_is_active():
			continue
		var dist: float = global_position.distance_to(controller.global_position)
		if dist <= trigger_radius:
			touching = true
			break

	if touching and not _is_pressed:
		_is_pressed = true
		_mesh.position = _mesh_origin + depress_axis.normalized() * depress_depth
		button_pressed.emit()
	elif not touching and _is_pressed:
		_is_pressed = false
		_mesh.position = _mesh_origin


## Swap the mesh used for the depress animation and hide the original ButtonMesh child.
## Call this from a system model after the GLB has loaded to drive the real geometry.
func set_button_mesh(mesh: MeshInstance3D) -> void:
	var old := get_node_or_null("ButtonMesh") as MeshInstance3D
	if old:
		old.hide()
	_mesh = mesh
	_mesh_origin = mesh.position


## Derive the depress axis from a GLB "Finger Button" empty node.
## GLTF finger-button empties are oriented so their local -Z points in the direction
## of travel.  This converts that to the button mesh's local space.
func set_depress_axis_from_node(finger_node: Node3D) -> void:
	# Global -Z of the finger empty = travel direction in world space
	var world_dir := -finger_node.global_transform.basis.z
	# Convert to the button mesh's local space
	if _mesh:
		depress_axis = _mesh.global_transform.basis.inverse() * world_dir


## Set the button's visual color by changing its material albedo
func set_color(color: Color) -> void:
	if not _mesh:
		return
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
