## LoadingRig — the only thing in the tree while one scene is torn down and the
## next is loaded.
##
## Scene changes free the outgoing scene BEFORE the incoming one is instantiated,
## which means the player's XR rig, camera and WorldEnvironment all go away for a
## while. Without something to look at, the headset renders whatever was last in
## the swapchain (or black) with no head tracking — nauseating, and there is no
## feedback that anything is happening. This carries its own origin, camera and
## environment so tracking keeps working, and shows a progress bar.
class_name LoadingRig
extends Node3D


@onready var _origin: XROrigin3D = $XROrigin3D
@onready var _camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var _screen: Node3D = $LoadingScreen
@onready var _label: Label3D = $LoadingScreen/TitleLabel


func _ready() -> void:
	_origin.current = true
	_camera.current = true
	_screen.set_camera(_camera)
	_screen.progress = 0.0


## Name of the room being loaded, shown above the bar.
func set_title(title: String) -> void:
	_label.text = title


func set_progress(value: float) -> void:
	_screen.progress = clampf(value, 0.0, 1.0)
