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

## How much the mesh travels down when pressed (metres)
@export var depress_depth: float = 0.008

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
		_mesh.position = _mesh_origin + Vector3(0, -depress_depth, 0)
		button_pressed.emit()
	elif not touching and _is_pressed:
		_is_pressed = false
		_mesh.position = _mesh_origin


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
