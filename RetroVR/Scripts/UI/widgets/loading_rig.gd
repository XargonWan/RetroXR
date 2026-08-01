## LoadingRig — the only thing in the tree while one scene is torn down and the
## next is loaded.
##
## Scene changes free the outgoing scene BEFORE the incoming one is instantiated.
## SceneManager carries the player's own rig across that gap, so normally this
## just adds a progress bar and a dark environment in front of wherever the
## player is standing — see prepare_for_player(). Without a player rig to borrow
## (a probe scene, a room that never had one) it falls back to its own origin and
## camera, so the headset still has a tracked view and something to look at.
class_name LoadingRig
extends Node3D


@onready var _origin := get_node_or_null("XROrigin3D") as XROrigin3D
@onready var _camera := get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
@onready var _screen: Node3D = $LoadingScreen
@onready var _label: Label3D = $LoadingScreen/TitleLabel

var _player: Node3D = null


## Hand over the player's rig, which the caller is keeping alive across the
## transition. Call this BEFORE adding this node to the tree: it drops our own
## origin and camera, which must never reach the tree while the player's are
## live — two XROrigin3Ds cannot both be current, and a second camera would be
## competing for a viewport that already has one.
func prepare_for_player(player: Node3D) -> void:
	_player = player
	if _player == null:
		return
	var own_origin := get_node_or_null("XROrigin3D")
	if own_origin != null:
		remove_child(own_origin)
		own_origin.free()


func _ready() -> void:
	var cam := _find_player_camera()
	if cam != null:
		# Stand the screen where the player is standing: it is authored around a
		# rig at the world origin, and the player is wherever the old room left
		# them.
		var here := cam.global_position
		var origin := _first_of_type(_player, "XROrigin3D")
		here.y = origin.global_position.y if origin != null else 0.0
		global_position = here
	else:
		_origin.current = true
		_camera.current = true
		cam = _camera
	_screen.set_camera(cam)
	_screen.progress = 0.0


## Name of the room being loaded, shown above the bar.
func set_title(title: String) -> void:
	_label.text = title


func set_progress(value: float) -> void:
	_screen.progress = clampf(value, 0.0, 1.0)


func _find_player_camera() -> XRCamera3D:
	return _first_of_type(_player, "XRCamera3D") as XRCamera3D


func _first_of_type(root: Node3D, type: String) -> Node3D:
	if root == null:
		return null
	var found := root.find_children("*", type, true, false)
	return found[0] as Node3D if not found.is_empty() else null
