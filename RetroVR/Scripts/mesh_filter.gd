## Hides named meshes inside an instanced GLB.
##
## Some downloaded sets merge several objects into one mesh per material rather
## than one mesh per object — the bedroom's bed/desk/chair set is two meshes for
## three pieces of furniture. They cannot be placed independently as-is, so the
## scene instances the GLB twice and each instance hides what it does not want.
##
## Cheaper than splitting the mesh in Blender and keeps the asset as-shipped, at
## the cost of loading the geometry twice. Fine for a 14k-tri set; reconsider if
## it is ever used on something large.
@tool
extends Node3D

## Mesh node names to hide. Matched exactly against MeshInstance3D.name.
@export var hide_meshes: PackedStringArray = []


func _ready() -> void:
	if hide_meshes.is_empty():
		return
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if hide_meshes.has(mi.name):
			mi.visible = false
