class_name RoomAcoustics
extends Node3D

## Drives the Meta XR Audio shoebox room model from a box placed in the scene.
##
## Shoebox only, on purpose. The SDK does have a geometric acoustic ray tracer,
## but it is bake-oriented with Unity/Unreal-only tooling and no Godot path, so
## it is not reachable here. A shoebox is also a fair model of these rooms --
## they are rectangular already.
##
## Drop one of these into a room scene, size the box to the walls, and pick a
## reflectivity. Does nothing when the SDK is unavailable, so the fallback path
## is unaffected.

## Room extent in metres. Defaults to a fairly typical living room.
@export var room_size: Vector3 = Vector3(5.0, 2.6, 6.0):
	set(v):
		room_size = v
		_apply()

## 0 = anechoic, 1 = bare hard walls. Carpet, a bed and soft furnishings pull
## this down; a bare floor and plaster push it up.
@export_range(0.0, 1.0) var reflectivity: float = 0.55:
	set(v):
		reflectivity = v
		_apply()

## Stands in for furniture: higher values shorten the decay, more so at high
## frequencies. A cluttered den is not the same room as an empty one.
@export_range(0.0, 1.0) var clutter: float = 0.4:
	set(v):
		clutter = v
		_apply()

## Draw the box in the editor so the room can be sized against the geometry.
@export var show_gizmo: bool = false:
	set(v):
		show_gizmo = v
		_update_gizmo()

var _mx: Object = null
var _gizmo: MeshInstance3D = null


func _ready() -> void:
	if Engine.has_singleton("MetaXRAudio"):
		_mx = Engine.get_singleton("MetaXRAudio")
	_apply()
	_update_gizmo()


func _exit_tree() -> void:
	# Leaving a room should not leave its reverb behind on the next scene.
	if _mx != null and _mx.is_available():
		_mx.clear_room()


func _apply() -> void:
	if _mx == null or not is_inside_tree():
		return
	if not _mx.is_available():
		return
	_mx.set_room(room_size, global_position, reflectivity, clutter)


func _update_gizmo() -> void:
	if not is_inside_tree():
		return
	if not show_gizmo:
		if _gizmo != null:
			_gizmo.queue_free()
			_gizmo = null
		return
	if _gizmo == null:
		_gizmo = MeshInstance3D.new()
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.2, 0.8, 1.0, 0.12)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_gizmo.material_override = m
		add_child(_gizmo)
	var box := BoxMesh.new()
	box.size = room_size
	_gizmo.mesh = box
