## SnapHighlight — attach as a child of an XRToolsSnapZone node alongside a
## HighlightMesh (MeshInstance3D) child.
##
## LOCAL PATCH (RetroVR): the old blue "ghost" preview is now superseded by the
## held-object snap PREVIEW (grab_driver.gd blends the real cartridge/disc/plug
## onto the socket while the hand hovers it in range). Showing the ghost on top
## of that just double-draws the same hint, so this node keeps the ghost mesh
## permanently hidden. The node is left in place (rather than deleted from every
## scene) so existing scene references stay valid.
extends Node3D


func _ready() -> void:
	# Hide the whole ghost subtree and leave it hidden — the snap preview draws
	# the real object in its place.
	visible = false
