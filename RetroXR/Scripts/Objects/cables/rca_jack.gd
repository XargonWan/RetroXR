@tool
## A panel-mount RCA socket — the female half of the connector on cable.tscn's plug.
##
## The mesh is baked by Tools/gen_rca_jack.gd with surface 0 the coloured
## insulator and surface 1 the chrome shell, so a jack is recoloured by tinting
## surface 0 and nothing else. That is the same split gen_rca_plug.gd uses, and the
## same one system.gd's _decorate_channel_plug relies on at the plug end.
##
## @tool so a colour set in the inspector shows without pressing play, which is the
## whole point of having it exported.
class_name RcaJack
extends MeshInstance3D


## The RCA colour code, for the audio pair this composite jack will eventually sit
## beside. Named rather than left as raw Colors so a red jack is `AUDIO_RED` in the
## scene that wants one.
const COMPOSITE_YELLOW := Color(0.95, 0.74, 0.02)
const AUDIO_WHITE := Color(0.87, 0.87, 0.84)
const AUDIO_RED := Color(0.72, 0.08, 0.08)

## Colour of the plastic insulator. The metal is not tintable on purpose: plated
## shells are the same on every jack, and letting a scene recolour one would only
## produce jacks that do not exist.
@export var jack_color: Color = COMPOSITE_YELLOW:
	set(value):
		jack_color = value
		_apply_color()


func _ready() -> void:
	# The exported value may have been assigned before `mesh` was, in which case the
	# setter had nothing to write to.
	_apply_color()


func _apply_color() -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var mat := get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		var base := mesh.surface_get_material(0) as StandardMaterial3D
		if base == null:
			return
		# The baked material belongs to the .res, which every jack in the room
		# shares. Writing a colour straight into it would recolour all of them.
		mat = base.duplicate() as StandardMaterial3D
		set_surface_override_material(0, mat)
	mat.albedo_color = jack_color
