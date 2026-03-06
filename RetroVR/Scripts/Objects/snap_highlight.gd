## SnapHighlight — attach as a child of an XRToolsSnapZone node alongside a
## HighlightMesh (MeshInstance3D) child. Shows the ghost mesh when a compatible
## object enters the snap zone's grab radius; hides it once something snaps in.
extends Node3D


func _ready() -> void:
	visible = false
	var zone := get_parent() as XRToolsSnapZone
	if not zone:
		push_warning("SnapHighlight: parent is not an XRToolsSnapZone")
		return
	zone.close_highlight_updated.connect(_on_close_highlight)
	zone.has_picked_up.connect(_on_snapped)
	zone.has_dropped.connect(_on_dropped)


func _on_close_highlight(_zone: Node, show: bool) -> void:
	visible = show


func _on_snapped(_what: Node) -> void:
	visible = false


func _on_dropped() -> void:
	# Zone is empty again — highlight is ready to show on next approach
	pass
