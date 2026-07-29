## Puts everything under this node on render layer 2 so the street can be lit
## independently of the room.
##
## Why this is needed: QualityManager turns shadows OFF on Quest, and an
## unshadowed DirectionalLight3D lights a room's interior as though the walls
## were not there. So the room's "Dusk" light has to stay very dim (0.15) or it
## flattens everything indoors — which leaves the exterior almost black.
##
## Splitting them by cull mask lets the street have a proper golden-hour sun
## while the bedroom keeps its lamplight. The room light masks to layer 1, the
## exterior sun to layer 2, and neither touches the other.
##
## Done in code rather than the .tscn because the houses and trees are instanced
## GLB scenes: their MeshInstance3D nodes live inside the imported hierarchy and
## cannot be given a `layers` value from here without making every one an
## editable child.
extends Node3D

const EXTERIOR_LAYER := 2

## Kenney's houses ship a bright toy palette (salmon walls, mint roofs) and
## Quaternius' trees a vivid summer green. Both read as cartoon next to the
## room's muted dusk. Pull the saturation down and darken slightly so the street
## sits back where it belongs — this is a view through a window, not the subject.
@export var desaturate: float = 0.62
@export var darken: float = 0.62


func _ready() -> void:
	for node in find_children("*", "VisualInstance3D", true, false):
		var vi := node as VisualInstance3D
		vi.layers = EXTERIOR_LAYER
		var mi := vi as MeshInstance3D
		if mi != null:
			_tone_down(mi)


func _tone_down(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		# Surface override first: the ground/road/kerb set theirs in the .tscn and
		# are already the colour we want, so leave those alone.
		if mi.get_surface_override_material(i) != null:
			continue
		var src := mi.mesh.surface_get_material(i) as BaseMaterial3D
		if src == null:
			continue
		# GLB materials are shared across every instance of the scene, so mutating
		# one in place would retint the other houses too. Duplicate first — the
		# same rule ModelMaterialFix follows.
		var mat := src.duplicate() as BaseMaterial3D
		var c := mat.albedo_color
		var grey := c.get_luminance()
		mat.albedo_color = Color(
			lerp(c.r, grey, desaturate) * darken,
			lerp(c.g, grey, desaturate) * darken,
			lerp(c.b, grey, desaturate) * darken,
			c.a)
		mi.set_surface_override_material(i, mat)
