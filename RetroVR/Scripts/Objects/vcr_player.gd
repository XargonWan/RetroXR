## VCRPlayer — pickable VCR that plays a video from an inserted VCRTape and
## renders it onto a connected TV, reusing the same cable/plug/TV wiring as
## RetroSystem. Playback is driven by Godot's built-in VideoStreamPlayer with
## an FFmpegVideoStream (from the EIRTeam.FFmpeg addon).
class_name VCRPlayer
extends XRToolsPickable


## Fast-forward / rewind scan rate: seconds of video traversed per real second
## while scanning (e.g. 8.0 ≈ 8× speed).
@export var scan_speed: float = 8.0

## Human-readable label shown above the unit.
@export var vcr_label: String = "VCR"

## When true, the video is rendered through the VHS/VCR effect shader.
@export var vcr_effect_enabled: bool = true

const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")


# Runtime state
var video_path: String = ""
var connected_tv: RetroTV = null
var is_playing: bool = false
# Scan direction: 0 = normal, +1 = fast-forward scan, -1 = rewind scan.
# While scanning the player keeps PLAYING (so it presents frames) but we jump
# stream_position ahead/back in throttled steps so the picture visibly races,
# with audio muted (real-VCR feel).
var _scan_dir: int = 0
var _scan_accum: float = 0.0            # time since the last scan seek
var _pre_scan_volume_db: float = 0.0    # volume to restore when a scan ends
# How often (seconds) to seek while scanning. Seeking every frame overloads the
# decoder; ~12 seeks/sec still reads as a smooth fast-scan.
const SCAN_SEEK_INTERVAL := 0.08

# Cable scene to instantiate (shared with RetroSystem)
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# TV to connect to after the cable finishes spawning (used by save/load restore)
var _pending_tv_restore: RetroTV = null
var _snapped_tape: Node3D = null

var _screen_material: Material = null


@onready var _vcr_body: MeshInstance3D = $VCRBody
@onready var _tape_slot: XRToolsSnapZone = $TapeSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _video_player: VideoStreamPlayer = $VideoViewport/VideoStreamPlayer
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _rewind_button: VRButton = $RewindButton
@onready var _ff_button: VRButton = $FastForwardButton
@onready var _name_label: Label3D = $NameLabel
@onready var _options_panel: VCROptionsPanel = $VCROptionsPanel
@onready var _clock: VCRClock = $VCRClock

# Last known total duration (seconds), remembered so the readout keeps showing
# the tape length when paused/stopped. -1 = unknown.
var _last_total: float = -1.0


func _ready() -> void:
	super._ready()
	add_to_group("vcr_player")
	_tape_slot.has_picked_up.connect(_on_tape_inserted)
	_tape_slot.has_dropped.connect(_on_tape_removed)
	_play_button.button_pressed.connect(_on_play_pressed)
	_pause_button.button_pressed.connect(_on_pause_pressed)
	_stop_button.button_pressed.connect(_on_stop_pressed)
	_rewind_button.button_pressed.connect(_on_rewind_pressed)
	_ff_button.button_pressed.connect(_on_ff_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))     # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))     # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))      # red
	_rewind_button.set_color(Color(0.1, 0.4, 0.9))    # blue
	_ff_button.set_color(Color(0.1, 0.4, 0.9))        # blue
	_video_player.finished.connect(_on_video_finished)
	# A larger audio buffer reduces crackle/underruns during playback.
	_video_player.buffering_msec = 1000
	_spawn_cable()
	_update_name_label()


func _update_name_label() -> void:
	if _name_label:
		_name_label.text = vcr_label.to_upper()


func _process(delta: float) -> void:
	_update_scan(delta)
	if _clock == null:
		return
	if is_playing:
		_last_total = _video_player.get_stream_length()
		_clock.set_times(_video_player.get_stream_position(), _last_total)
	elif not video_path.is_empty():
		# Tape inserted but stopped/paused-at-start — show 0 against the last
		# known length (unknown until first played).
		_clock.set_times(0.0, _last_total)
	else:
		_last_total = -1.0
		_clock.set_blank()


## While scanning, jump the (still-playing) player's position forward/back in
## throttled steps so frames visibly race by at scan_speed. Hitting either end
## stops the scan and holds there.
func _update_scan(delta: float) -> void:
	if _scan_dir == 0 or not is_playing:
		return
	_scan_accum += delta
	if _scan_accum < SCAN_SEEK_INTERVAL:
		return
	var length := _video_player.get_stream_length()
	var pos := _video_player.get_stream_position() + _scan_accum * scan_speed * float(_scan_dir)
	_scan_accum = 0.0
	if pos <= 0.0:
		_video_player.set_stream_position(0.0)
		_end_scan_hold()   # reached the start; hold here
	elif length > 0.0 and pos >= length:
		_video_player.set_stream_position(length)
		_end_scan_hold()   # reached the end; hold here
	else:
		_video_player.set_stream_position(pos)


## Stop an in-progress scan and freeze on the current frame (used at either end).
func _end_scan_hold() -> void:
	_scan_dir = 0
	_video_player.set_paused(true)
	_video_player.volume_db = _pre_scan_volume_db
	_osd("PAUSE", true)


## Toggle the floating VCR settings panel (mirrors RetroSystem.toggle_options_ui).
## Called by SpawnMenuController when the menu button is pressed while pointing
## at this VCR.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


# --- Tape slot callbacks ---

func _on_tape_inserted(tape: Node3D) -> void:
	_snapped_tape = tape
	add_collision_exception_with(tape)
	if tape.has_method("get_video_path"):
		video_path = tape.get_video_path()


func _on_tape_removed() -> void:
	if _snapped_tape:
		remove_collision_exception_with(_snapped_tape)
		_snapped_tape = null
	stop()
	video_path = ""


# --- Playback controls ---

func _on_play_pressed() -> void:
	if is_playing:
		# Leaving a scan or resuming from pause both mean "back to normal play".
		if _scan_dir != 0 or _video_player.is_paused():
			_set_scan(0)
			_osd("PLAY", false)
			return
	play()


func _on_pause_pressed() -> void:
	if is_playing:
		_scan_dir = 0
		_video_player.set_paused(true)
		_osd("PAUSE", true)


func _on_stop_pressed() -> void:
	stop()


## Rewind button: toggle reverse scan (press again, or Play/Pause, to exit).
func _on_rewind_pressed() -> void:
	if not is_playing:
		return
	if _scan_dir == -1:
		_set_scan(0)
		_osd("PLAY", false)
	else:
		_set_scan(-1)
		_osd("<< REW", true)


## Fast-forward button: toggle forward scan (press again, or Play/Pause, to exit).
func _on_ff_pressed() -> void:
	if not is_playing:
		return
	if _scan_dir == 1:
		_set_scan(0)
		_osd("PLAY", false)
	else:
		_set_scan(1)
		_osd("FF >>", true)


## Show an on-screen message on the connected TV (sticky, or auto-hiding after 3s).
func _osd(text: String, sticky: bool) -> void:
	if connected_tv == null:
		return
	if sticky:
		connected_tv.show_osd(text)
	else:
		connected_tv.show_osd_timed(text, 3.0)


## Enter (dir = ±1) or leave (dir = 0) a fast-forward/rewind scan.
## The player keeps playing during a scan (so frames present) but is muted;
## leaving restores normal-speed playback and the prior volume.
func _set_scan(dir: int) -> void:
	if dir != 0 and _scan_dir == 0:
		_pre_scan_volume_db = _video_player.volume_db
	_scan_dir = dir
	_scan_accum = 0.0
	_video_player.set_paused(false)
	_video_player.volume_db = -80.0 if dir != 0 else _pre_scan_volume_db


func play() -> void:
	if connected_tv == null:
		push_error("VCRPlayer: Cannot play - no TV connected")
		return
	if video_path.is_empty():
		push_error("VCRPlayer: Cannot play - no tape inserted")
		return

	var stream := ClassDB.instantiate("FFmpegVideoStream") as VideoStream
	if stream == null:
		push_error("VCRPlayer: FFmpegVideoStream unavailable (FFmpeg addon not loaded)")
		return
	stream.set_file(video_path)
	_video_player.stream = stream
	_video_player.play()
	is_playing = true
	_scan_dir = 0
	_bind_screen_to_tv()
	_osd("PLAY", false)


func stop() -> void:
	if not is_playing:
		return
	if _scan_dir != 0:
		_video_player.volume_db = _pre_scan_volume_db
	_scan_dir = 0
	_video_player.stop()
	is_playing = false
	_blank_screen()
	if connected_tv:
		connected_tv.hide_osd()


# --- TV connection contract (identical to RetroSystem's) ---

## Called by the TV's cable plug when it connects to a TV
func on_tv_connected(tv: RetroTV) -> void:
	connected_tv = tv
	if is_playing:
		_bind_screen_to_tv()


## Called by the TV's cable plug when it disconnects
func on_tv_disconnected() -> void:
	if connected_tv:
		connected_tv.hide_osd()
	connected_tv = null


## Set the audio volume (0.0 = silent, 1.0 = 100%). Called by the TV volume buttons.
func set_audio_volume(volume: float) -> void:
	_video_player.volume_db = linear_to_db(volume) if volume > 0.001 else -80.0


## Show or hide the screen output. Called by the TV toggle button.
func set_screen_enabled(enabled: bool) -> void:
	if not connected_tv:
		return
	if enabled and is_playing:
		_bind_screen_to_tv()
	else:
		_blank_screen()


# --- Screen routing ---

## Route the VideoStreamPlayer's frame texture onto the connected TV screen mesh.
func _bind_screen_to_tv() -> void:
	if connected_tv == null:
		return
	var mesh := connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var tex := _video_player.get_video_texture()
	if tex == null:
		return
	if _screen_material == null or not _material_matches_effect():
		_screen_material = _make_screen_material()
	if _screen_material is ShaderMaterial:
		(_screen_material as ShaderMaterial).set_shader_parameter("video_tex", tex)
	else:
		var std := _screen_material as StandardMaterial3D
		std.albedo_texture = tex
		std.emission_texture = tex
	mesh.set_surface_override_material(0, _screen_material)


## True if the current material already matches the vcr_effect_enabled setting.
func _material_matches_effect() -> bool:
	if vcr_effect_enabled:
		return _screen_material is ShaderMaterial
	return _screen_material is StandardMaterial3D


## Build the screen material for the current vcr_effect_enabled setting.
func _make_screen_material() -> Material:
	if vcr_effect_enabled:
		var mat := ShaderMaterial.new()
		mat.shader = VCR_SHADER
		return mat
	var std := StandardMaterial3D.new()
	std.emission_enabled = true
	std.emission = Color(1, 1, 1)
	std.emission_energy_multiplier = 1.0
	return std


## Toggle the VHS effect at runtime; rebinds the screen if currently playing.
func set_vcr_effect_enabled(enabled: bool) -> void:
	if vcr_effect_enabled == enabled:
		return
	vcr_effect_enabled = enabled
	if is_playing:
		_bind_screen_to_tv()


func _blank_screen() -> void:
	if connected_tv == null:
		return
	var mesh := connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0, 0, 0, 1)
	mesh.set_surface_override_material(0, black)


func _on_video_finished() -> void:
	# Leave the last frame; mark as not playing so Play restarts from the top.
	is_playing = false


# --- Cable management (mirrors RetroSystem) ---

func _spawn_cable() -> void:
	_cable_instance = CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("CablePlug") as CablePlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_system(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.1)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length
	if _pending_tv_restore != null:
		_snap_cable_to_tv(_pending_tv_restore)
		_pending_tv_restore = null


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	if connected_tv != null or _cable_plug.is_picked_up():
		return
	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()
	if dist > _max_rope_length:
		var dir := diff / dist
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward_vel := dir.dot(_cable_plug.linear_velocity)
		if outward_vel > 0.0:
			_cable_plug.linear_velocity -= dir * outward_vel


# --- Save/load restore (mirrors RetroSystem) ---

func get_snapped_tape() -> Node3D:
	return _snapped_tape


func restore_cable_connection(tv: RetroTV) -> void:
	if _cable_plug != null:
		_snap_cable_to_tv(tv)
	else:
		_pending_tv_restore = tv


func _snap_cable_to_tv(tv: RetroTV) -> void:
	tv.accept_plug_restore(_cable_plug)


func restore_tape(tape: Node3D) -> void:
	_tape_slot.pick_up_object(tape)
