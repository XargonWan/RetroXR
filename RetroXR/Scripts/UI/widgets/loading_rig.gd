## LoadingRig — the only thing in the tree while one scene is torn down and the
## next is loaded.
##
## SceneManager carries the player's own rig across that gap, so normally this
## just adds a progress bar and a dark environment in front of wherever the player
## is standing — see prepare_for_player(). Without a player rig to borrow (a probe
## scene, a room that never had one) it falls back to its own origin and camera,
## so the headset still has a tracked view and something to look at.
class_name LoadingRig
extends Node3D


@onready var _own_origin := get_node_or_null("XROrigin3D") as XROrigin3D
@onready var _own_camera := get_node_or_null("XROrigin3D/XRCamera3D") as XRCamera3D
@onready var _screen: Node3D = $LoadingScreen
@onready var _label: Label3D = $LoadingScreen/TitleLabel

var _player_camera: XRCamera3D = null
var _player_origin: Node3D = null


## Hand over the player's rig, which the caller is keeping alive across the
## transition. Call this BEFORE adding this node to the tree: it drops our own
## origin and camera, which must never reach the tree while the player's are live
## — two XROrigin3Ds cannot both be current, and a second camera would be
## competing for a viewport that already has one.
func prepare_for_player(player: PlayerRig) -> void:
	if player == null:
		return
	_player_camera = player.camera
	_player_origin = player.origin
	var own := get_node_or_null("XROrigin3D")
	if own != null:
		remove_child(own)
		own.free()


func _ready() -> void:
	var camera := _player_camera
	if camera != null:
		# The screen is authored around a rig at the world origin, and the player
		# is wherever the old room left them. Track them rather than place it
		# once: a loading screen you can walk out of is worse than none.
		_follow_player()
	else:
		_own_origin.current = true
		_own_camera.current = true
		camera = _own_camera
		set_process(false)
	_screen.set_camera(camera)
	_screen.progress = 0.0


func _process(_delta: float) -> void:
	_follow_player()


func _follow_player() -> void:
	if not is_instance_valid(_player_camera):
		return
	var here := _player_camera.global_position
	here.y = _player_origin.global_position.y if is_instance_valid(_player_origin) else 0.0
	global_position = here


## Name of the room being loaded, shown above the bar.
func set_title(title: String) -> void:
	_label.text = title


func set_progress(value: float) -> void:
	_screen.progress = clampf(value, 0.0, 1.0)
