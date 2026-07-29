## Makes named meshes inside an instanced GLB read as lit.
##
## Downloaded fixtures usually ship ONE material shared by every part — the
## ceiling fan uses `Ceiling_Fan_Mat` for its blades, housing, downrod and glass
## alike — so emission cannot simply be switched on at the material or the whole
## fixture glows. This duplicates the material on the named meshes only, the same
## way bedroom_exterior.gd duplicates before retinting.
##
## Registers in the "light_glow" group so a switch can darken the glass at the
## same time it kills the light; otherwise flipping the switch leaves a glowing
## shade over an unlit room.
class_name GlowMesh
extends Node3D


## Mesh node names to make emissive, matched exactly against MeshInstance3D.name.
## The ceiling fan's glass globe exports as "defaultMaterial4" — the GLB names
## every part after the material it uses, so these are positional, not
## descriptive. Re-check them if the model is ever replaced.
@export var glow_meshes: PackedStringArray = []

@export var glow_color: Color = Color(1, 0.85, 0.6)
@export var glow_energy: float = 1.6

## Starting state, matched to whatever the room's lights are authored at.
@export var lit: bool = true

var _mats: Array[BaseMaterial3D] = []


func _ready() -> void:
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not glow_meshes.has(mi.name):
			continue
		for si in mi.mesh.get_surface_count():
			var src: Material = mi.get_active_material(si)
			var dup: BaseMaterial3D = null
			if src is BaseMaterial3D:
				dup = (src as BaseMaterial3D).duplicate() as BaseMaterial3D
			else:
				dup = StandardMaterial3D.new()
			dup.emission_enabled = true
			dup.emission = glow_color
			mi.set_surface_override_material(si, dup)
			_mats.append(dup)
	add_to_group("light_glow")
	_apply()


func set_lit(on: bool) -> void:
	lit = on
	_apply()


func _apply() -> void:
	for mat in _mats:
		mat.emission_energy_multiplier = glow_energy if lit else 0.0
