## Root Control of a ToastPanel's viewport — the surface the notification stack
## is reparented onto.
##
## Exists only so the panel goes through XRToolsViewport2DIn3D's `scene`
## property. The addon can technically render a Control added straight to its
## SubViewport, but that path leaves scene_node null and the quad never draws;
## DropdownPanel takes the `scene` route and works.
class_name ToastHost2D
extends Control


## Where ToastPanel parents the stack.
func mount(stack: Control) -> void:
	if stack.get_parent() != null:
		stack.get_parent().remove_child(stack)
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.offset_top = 0.0
	stack.offset_bottom = 0.0
	stack.offset_left = 0.0
	stack.offset_right = 0.0
	add_child(stack)
