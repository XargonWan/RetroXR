## PickableHighlight — add as a child of any XRToolsPickable.
## Automatically builds blue outline overlay meshes for every MeshInstance3D
## direct-child of the parent, and shows/hides them via highlight_updated.
extends Node3D

const OUTLINE_SHADER := preload("res://Shaders/outline.gdshader")

var _outline_material: ShaderMaterial
var _overlays: Array[MeshInstance3D] = []


func _ready() -> void:
	_outline_material = ShaderMaterial.new()
	_outline_material.shader = OUTLINE_SHADER

	# Connect to parent pickable's highlight signal
	var parent := get_parent()
	if parent and parent.has_signal("highlight_updated"):
		parent.highlight_updated.connect(_on_highlight_updated)
	else:
		push_warning("PickableHighlight: parent has no highlight_updated signal")
		return

	# Build overlay meshes after the scene is fully ready
	_build_overlays.call_deferred()


func _build_overlays() -> void:
	var parent := get_parent()
	if not parent:
		return

	for child in parent.get_children():
		if child is MeshInstance3D and child != self:
			var overlay := MeshInstance3D.new()
			overlay.mesh = child.mesh
			overlay.transform = child.transform
			# Apply the outline material to every surface
			for i in child.get_surface_override_material_count():
				overlay.set_surface_override_material(i, _outline_material)
			# Ensure the outline material covers all mesh surfaces
			if overlay.get_surface_override_material_count() == 0:
				overlay.set_surface_override_material(0, _outline_material)
			overlay.visible = false
			overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(overlay)
			_overlays.append(overlay)


func _on_highlight_updated(_object: Node, highlighted: bool) -> void:
	for overlay in _overlays:
		if is_instance_valid(overlay):
			overlay.visible = highlighted
