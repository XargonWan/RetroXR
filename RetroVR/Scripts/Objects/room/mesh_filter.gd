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

## Material applied to every mesh that SURVIVES the filter. Downloaded props tend
## to ship a single colourway — Poly Haven's throw pillows are saturated rust —
## and this re-skins them per instance without touching the GLB, so one download
## supplies a whole scatter of cushions in different colours.
@export var skin: Material = null


func _ready() -> void:
	if hide_meshes.is_empty() and skin == null:
		return
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if hide_meshes.has(mi.name):
			mi.visible = false
		elif skin != null:
			for si in mi.get_surface_override_material_count():
				mi.set_surface_override_material(si, skin)
