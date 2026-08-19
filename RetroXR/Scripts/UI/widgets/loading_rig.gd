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
@onready var _title_label: Label3D = $LoadingScreen/TitleLabel
@onready var _status_label: Label3D = $LoadingScreen/StatusLabel
@onready var _percent_label: Label3D = $LoadingScreen/PercentLabel
@onready var _progress_material: ShaderMaterial = \
	$LoadingScreen/ProgressBar.get_surface_override_material(0) as ShaderMaterial

var _player_camera: XRCamera3D = null
var _player_origin: Node3D = null
var _progress: float = 0.0
var _animation_time: float = 0.0
var _status_text: String = "PREPARING ROOM"
var _last_percent: int = -1
var _last_status_rendered: String = ""


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
	if _player_camera != null:
		# Snap on the first frame so the panel cannot briefly appear at the old
		# room's origin. Subsequent motion is player-relative and yaw is smoothed
		# with a capped interpolation, rather than the stock screen's uncapped
		# angular step (which could overshoot and wobble around the target).
		_follow_player(0.0, true)
	else:
		_own_origin.current = true
		_own_camera.current = true
	set_progress(0.0)


func _process(delta: float) -> void:
	_animation_time += delta
	if _player_camera != null:
		_follow_player(delta)
	_update_status_label()


func _follow_player(delta: float, snap: bool = false) -> void:
	if not is_instance_valid(_player_camera):
		return
	var here := _player_camera.global_position
	here.y = _player_origin.global_position.y if is_instance_valid(_player_origin) else 0.0
	global_position = here
	var target_yaw := _player_camera.global_rotation.y
	if snap:
		_screen.global_rotation.y = target_yaw
	else:
		# Fast enough to follow a deliberate turn, slow enough not to copy every
		# tiny headset movement. lerp_angle cannot overshoot the way the addon
		# loading screen's fixed angular step can.
		var weight := 1.0 - exp(-6.0 * delta)
		_screen.global_rotation.y = lerp_angle(_screen.global_rotation.y, target_yaw, weight)


## Name of the room being loaded, shown above the bar.
func set_title(title: String) -> void:
	_title_label.text = title


func set_progress(value: float) -> void:
	# Threaded-loader progress should be monotonic, but individual dependency
	# reports can briefly move backwards. A loading bar must never do the same.
	_progress = maxf(_progress, clampf(value, 0.0, 1.0))
	_progress_material.set_shader_parameter("progress", _progress)
	var percent := roundi(_progress * 100.0)
	if percent != _last_percent:
		_last_percent = percent
		_percent_label.text = "%d%%" % percent
	if _progress >= 1.0:
		_status_text = "READY"
	elif _progress >= 0.9:
		_status_text = "FINISHING SETUP"
	elif _progress >= 0.05:
		_status_text = "LOADING ROOM DATA"
	else:
		_status_text = "PREPARING ROOM"
	_update_status_label()


func _update_status_label() -> void:
	var rendered := _status_text
	if _progress >= 1.0:
		rendered += "   "
	else:
		var dot_count := int(_animation_time / 0.35) % 4
		rendered += ".".repeat(dot_count) + " ".repeat(3 - dot_count)
	if rendered != _last_status_rendered:
		_last_status_rendered = rendered
		_status_label.text = rendered
