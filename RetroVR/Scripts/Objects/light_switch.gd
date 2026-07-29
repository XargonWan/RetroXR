## Wall light switch — a VRButton over the toggle that kills the room's ceiling
## lights.
##
## Toggles `visible`, never `light_energy`. QualityManager._adjust_lights() owns
## the energy of every node in the "ceiling_light" group (0.8 desktop, 0.6 Quest)
## and rewrites it whenever the quality tier changes, so a switch that wrote an
## energy back would be silently undone.
##
## The GLB ships two plate variants side by side as one mesh each; `hide_meshes`
## drops the one this scene does not want.
class_name LightSwitch
extends Node3D


## Mesh node names inside the plate GLB to hide, matched exactly.
@export var hide_meshes: PackedStringArray = []

## Starting state. The room is authored lit, so this is true.
@export var lights_on: bool = true

## How far the lever travels between its two positions, in radians about the
## button's local X. The model's own moulded lever cannot move — it is baked into
## the same mesh as the plate — so ButtonMesh is a separate lever laid over it.
const LEVER_TILT := 0.30

var _button: VRButton = null
var _lever: Node3D = null


func _ready() -> void:
	for node in find_children("*", "MeshInstance3D", true, false):
		if hide_meshes.has(node.name):
			(node as MeshInstance3D).visible = false

	_button = find_child("Button", true, false) as VRButton
	if _button == null:
		return
	_button.button_pressed.connect(_on_pressed)
	_lever = _button.get_node_or_null("ButtonMesh") as Node3D
	_apply()


func _on_pressed() -> void:
	lights_on = not lights_on
	_apply()


func _apply() -> void:
	for node in get_tree().get_nodes_in_group("ceiling_light"):
		var light := node as Light3D
		if light != null:
			light.visible = lights_on
	if _lever != null:
		_lever.rotation.x = LEVER_TILT if lights_on else -LEVER_TILT
