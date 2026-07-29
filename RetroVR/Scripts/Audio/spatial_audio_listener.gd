extends Node

## Feeds the head pose to the Meta XR Audio SDK once per frame.
##
## Autoloaded rather than parented to the XRCamera3D so it survives scene
## changes and needs no edit to player_rig.tscn. It reads the viewport's current
## 3D camera, which is the XRCamera3D in VR and the desktop fallback camera
## otherwise, so it follows whichever is active without special-casing.
##
## Orientation is the point: Godot's built-in 3D audio only ever used listener
## position, and head rotation is what HRTF needs to place a source in front of
## or behind you.

var _active := false
var _mx: Object = null


func _ready() -> void:
	if not Engine.has_singleton("MetaXRAudio"):
		set_process(false)
		return
	_mx = Engine.get_singleton("MetaXRAudio")
	if _mx == null:
		set_process(false)
		return
	_active = _mx.is_available()
	set_process(_active)
	if _active:
		print("[MetaXRAudio] listener tracking active — SDK ", _mx.get_version())
	else:
		print("[MetaXRAudio] not available (", _mx.get_last_error(),
			  "); emitters will use Godot panning")


func _process(_delta: float) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var vp := tree.root.get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_3d()
	if cam == null:
		return
	_mx.set_listener_transform(cam.global_transform)


## True when the SDK is driving spatialisation. Probes and the settings UI read
## this rather than poking the singleton directly.
func is_spatialised() -> bool:
	return _active
