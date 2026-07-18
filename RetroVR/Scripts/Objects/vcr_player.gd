## VCRPlayer — pickable VCR that plays a video from an inserted VCRTape and
## renders it onto a connected TV, reusing the same cable/plug/TV wiring as
## RetroSystem. Playback is driven by the libVLC-backed VlcPlayer GDExtension
## (the same engine as DVDPlayer): video is decoded to a texture and audio to a
## PCM ring buffer drained into a spatialised AudioStreamPlayer3D at the TV.
## Using libVLC gives broad codec support (incl. HEVC/x265) with one shared
## video backend.
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

# Tunable VHS/VCR shader uniforms (vcr_effect.gdshader). Adjustable from the VCR
# options panel's "VHS Effect" tab; applied to the screen ShaderMaterial. Defaults
# mirror the shader's own defaults. (CRT display-stage uniforms are owned by the
# connected TV and tuned from the TV panel, so they're not duplicated here.)
var _vcr_params := {
	"effect_amount": 1.0,
	"aberration": 0.0025,
	"scanline_strength": 0.22,
	"noise_strength": 0.10,
	"wobble_strength": 0.0016,
	"tracking_strength": 0.02,
	"desaturation": 0.15,
	"brightness": 1.12,
	"roll_amount": 0.008,
	"roll_speed": 0.5,
	"banded_noise_opacity": 0.15,
	"noise_speed": 8.0,
	"vhs_contrast": 1.12,
	"pixelate": true,
}


# Runtime state
var video_path: String = ""
var connected_tv: RetroTV = null
var is_playing: bool = false
# Scan direction: 0 = normal, +1 = fast-forward scan, -1 = rewind scan.
# While scanning the player keeps PLAYING (so it presents frames) but we jump
# the position ahead/back in throttled steps so the picture visibly races, with
# audio muted (real-VCR feel).
var _scan_dir: int = 0
var _scan_accum: float = 0.0            # time since the last scan seek
# How often (seconds) to seek while scanning. Seeking every frame overloads the
# decoder; ~12 seeks/sec still reads as a smooth fast-scan.
const SCAN_SEEK_INTERVAL := 0.08

# libVLC-backed engine (shared with DVDPlayer) + Godot-routed spatial audio.
# libVLC decodes PCM into VlcPlayer's ring buffer; we drain it into an
# AudioStreamGenerator on a 3D player at the connected TV, so VHS sound is
# spatialised (and the TV volume knob scales it) like the console/DVD audio.
var _vlc: Object = null                 # VlcPlayer (GDExtension)
var _audio_player: AudioStreamPlayer3D = null
var _audio_playback: AudioStreamGeneratorPlayback = null
var _volume_linear: float = 1.0
var _paused: bool = false

# Cable scene to instantiate (shared with RetroSystem)
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# TV to connect to after the cable finishes spawning (used by save/load restore)
var _pending_tv_restore: RetroTV = null
var _snapped_tape: Node3D = null

# Slot loader (front-loading like a real VCR): a tape brought to the front slot
# rides IN flat and is swallowed by the opaque body; Eject rides it back OUT the
# front where it protrudes, frozen and grabbable. Mirrors DVDPlayer/RetroSystem.
const TAPE_HALF_DEPTH := 0.04   # tape depth/2 once laid flat (0.08 m deep)
const SLOT_INSET := 0.10        # how far inside the VCR a loaded tape rides
const SLOT_PROTRUDE := 0.02     # how far the ejected tape pokes out the front
var _slot_ejecting := false     # slide-out animation in flight

var _screen_material: Material = null


@onready var _vcr_body: MeshInstance3D = $VCRBody
@onready var _tape_slot: XRToolsSnapZone = $TapeSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _rewind_button: VRButton = $RewindButton
@onready var _ff_button: VRButton = $FastForwardButton
@onready var _eject_button: VRButton = $EjectButton
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
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))     # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))     # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))      # red
	_rewind_button.set_color(Color(0.1, 0.4, 0.9))    # blue
	_ff_button.set_color(Color(0.1, 0.4, 0.9))        # blue
	_eject_button.set_color(Color(0.8, 0.8, 0.85))    # light grey

	if ClassDB.class_exists("VlcPlayer"):
		_vlc = ClassDB.instantiate("VlcPlayer")
		_vlc.finished.connect(_on_video_finished)
	else:
		push_error("VCRPlayer: VlcPlayer extension not loaded — video playback unavailable")

	_setup_audio()
	_spawn_cable()
	_update_name_label()


## Build the spatial audio player fed by VlcPlayer's PCM ring buffer.
func _setup_audio() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(_vlc.get_audio_rate()) if _vlc else 48000.0
	gen.buffer_length = 0.25
	_audio_player = AudioStreamPlayer3D.new()
	_audio_player.name = "AudioStreamPlayer3D"
	_audio_player.stream = gen
	_audio_player.unit_size = 3.0
	_audio_player.max_distance = 15.0
	add_child(_audio_player)


func _update_name_label() -> void:
	if _name_label:
		_name_label.text = vcr_label.to_upper()


func _process(delta: float) -> void:
	if _vlc:
		# Pump the latest decoded frame + PCM every frame.
		_vlc.update_frame()
		if is_playing and connected_tv != null:
			_bind_screen_to_tv()
		_pump_audio()
		# Emanate the sound from the connected TV so it's spatialised there.
		if _audio_player and connected_tv != null and is_instance_valid(connected_tv):
			_audio_player.global_position = connected_tv.global_position
	_update_scan(delta)
	if _clock == null:
		return
	if is_playing:
		_last_total = _vlc_length_sec()
		_clock.set_times(_vlc_time_sec(), _last_total)
	elif not video_path.is_empty():
		# Tape inserted but stopped/paused-at-start — show 0 against the last
		# known length (unknown until first played).
		_clock.set_times(0.0, _last_total)
	else:
		_last_total = -1.0
		_clock.set_blank()


## Drain decoded PCM from VlcPlayer into the generator (fills only what's free).
func _pump_audio() -> void:
	if _audio_playback == null:
		return
	var avail := _audio_playback.get_frames_available()
	if avail <= 0:
		return
	var frames: PackedVector2Array = _vlc.read_audio(avail)
	if frames.size() > 0:
		_audio_playback.push_buffer(frames)


# --- Position helpers (VlcPlayer reports ms / 0..1; the VCR works in seconds) ---

func _vlc_time_sec() -> float:
	return (float(_vlc.get_time()) / 1000.0) if _vlc else 0.0


func _vlc_length_sec() -> float:
	if _vlc == null:
		return -1.0
	var ms: int = _vlc.get_length()
	return (float(ms) / 1000.0) if ms > 0 else -1.0


## Seek to an absolute time in seconds (needs a known length — libVLC seeks by
## fraction). No-op when the length isn't known yet.
func _vlc_seek_sec(sec: float) -> void:
	if _vlc == null:
		return
	var length := _vlc_length_sec()
	if length > 0.0:
		_vlc.set_position(clampf(sec / length, 0.0, 1.0))


## While scanning, jump the (still-playing) player's position forward/back in
## throttled steps so frames visibly race by at scan_speed. Hitting either end
## stops the scan and holds there.
func _update_scan(delta: float) -> void:
	if _scan_dir == 0 or not is_playing:
		return
	_scan_accum += delta
	if _scan_accum < SCAN_SEEK_INTERVAL:
		return
	var length := _vlc_length_sec()
	var pos := _vlc_time_sec() + _scan_accum * scan_speed * float(_scan_dir)
	_scan_accum = 0.0
	if pos <= 0.0:
		_vlc_seek_sec(0.0)
		_end_scan_hold()   # reached the start; hold here
	elif length > 0.0 and pos >= length:
		_vlc_seek_sec(length)
		_end_scan_hold()   # reached the end; hold here
	else:
		_vlc_seek_sec(pos)


## Stop an in-progress scan and freeze on the current frame (used at either end).
func _end_scan_hold() -> void:
	_scan_dir = 0
	if _vlc:
		_vlc.set_paused(true)
	_paused = true
	_apply_volume()
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
	# Ride the tape into the VCR (front slot-load look) — laid flat, swallowed by
	# the opaque body and held frozen inside until Eject.
	_play_slot_insert(tape)
	NetworkManager.report_event(NetObjectSync.EV_TAPE_INSERT,
		{"vcr": self, "tape": tape})


func _on_tape_removed() -> void:
	if _snapped_tape:
		remove_collision_exception_with(_snapped_tape)
		_snapped_tape = null
	stop()
	video_path = ""
	NetworkManager.report_event(NetObjectSync.EV_TAPE_REMOVE, {"vcr": self})


## Basis that lays the tape flat (label up) — the tape mesh is authored standing
## with its label on +Z, so rotate -90 deg about the VCR's right axis.
func _tape_flat_basis() -> Basis:
	return global_transform.basis * Basis(Vector3(1, 0, 0), -PI / 2.0)


## Ride a freshly-snapped tape from just outside the front slot to its seated
## position inside the opaque body. Frozen for the whole ride (an unfrozen body
## sags under gravity while the tween drives it). Mirrors DVDPlayer._play_slot_insert.
func _play_slot_insert(tape: Node3D) -> void:
	var slot_pos := _tape_slot.global_position
	var into := -global_transform.basis.z            # front -> back, into the body
	var flat := _tape_flat_basis()
	var start := slot_pos - into * (TAPE_HALF_DEPTH + 0.01)
	if tape is RigidBody3D:
		(tape as RigidBody3D).freeze = true
	tape.global_transform = Transform3D(flat, start)
	# The snap driver writes the zone pose once on the frame after pick-up — cover
	# it with a deferred re-set, and interpolate with an EXPLICIT from->to
	# (_set_ride_pos re-asserts the flat basis every step).
	tape.set_deferred("global_transform", Transform3D(flat, start))
	var tween := tape.create_tween()
	tween.tween_method(_set_ride_pos.bind(tape, flat), start,
		slot_pos + into * SLOT_INSET, 0.9) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_reanchor_tape_grab.bind(tape))


## The snap-zone's grab driver freezes the tape's offset from the slot at the
## moment it was grabbed — right at the slot mouth, before this ride-in tween
## seats it deeper inside. That stale offset is what the driver falls back to
## reproducing the instant the slot itself moves, so without this the tape
## would visibly slide back out to the mouth the moment the VCR is picked up.
## Re-anchor the grab transform to the just-reached seated pose so the tape
## stays put relative to the VCR from here on.
func _reanchor_tape_grab(tape: Node3D) -> void:
	if not is_instance_valid(tape):
		return
	var driver: Variant = tape.get("_grab_driver")
	if driver and driver.primary and driver.primary.by == _tape_slot:
		driver.primary.transform = tape.global_transform.affine_inverse() * _tape_slot.global_transform


## tween_method target for the slot ride: sets the tape's full transform so the
## flat orientation holds throughout (explicit from->to interpolation).
func _set_ride_pos(p: Vector3, tape: Node3D, b: Basis) -> void:
	if is_instance_valid(tape):
		tape.global_transform = Transform3D(b, p)


func _on_eject_pressed() -> void:
	_slot_eject()


## Slide the loaded tape out of the front slot, then release it from the snap zone
## so it can be grabbed. It ends frozen and protruding (held by the mechanism, not
## falling) until someone takes it. drop_object() fires has_dropped ->
## _on_tape_removed, which stops playback and clears state.
func _slot_eject() -> void:
	var tape := _snapped_tape
	if tape == null or not is_instance_valid(tape) or _slot_ejecting:
		return
	_slot_ejecting = true
	var flat := _tape_flat_basis()
	var out_pos: Vector3 = _tape_slot.global_position \
		+ global_transform.basis.z * SLOT_PROTRUDE
	var tween := tape.create_tween()
	tween.tween_method(_set_ride_pos.bind(tape, flat), tape.global_position, out_pos, 0.9) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		_slot_ejecting = false
		# The released tape still overlaps the zone's grab sphere and the zone
		# re-stashes anything dropped inside it — disarm it around the release, then
		# leave the tape frozen protruding from the slot until someone takes it.
		_tape_slot.enabled = false
		_tape_slot.drop_object()
		if is_instance_valid(tape) and tape is RigidBody3D:
			(tape as RigidBody3D).freeze = true
			(tape as RigidBody3D).global_transform = Transform3D(flat, out_pos)
		get_tree().create_timer(0.25).timeout.connect(func() -> void:
			if is_instance_valid(_tape_slot):
				_tape_slot.enabled = true))


## Client-in-session: transport intents route to the host (authoritative
## transport). The host executes and its state broadcast drives every peer's
## LOCAL playback (M5) — video files arrive via NetFileTransfer.
## Returns true when the command was forwarded instead of handled locally.
func _net_forward_cmd(cmd: String) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_VCR_CMD, {"vcr": self, "cmd": cmd})
		return true
	return false


# ── Multiplayer playback sync (M5) ────────────────────────────────────────────
# Host is transport authority; every peer plays its own local copy of the video.
# Sync is drift-corrected, not lockstep: the host broadcasts
# (playing, paused, position) on transport changes plus a heartbeat, and a peer
# seeks whenever its position drifts past NET_DRIFT_TOLERANCE.

const NET_DRIFT_TOLERANCE := 0.75   # seconds off host before a corrective seek

## Host: push the current transport state to peers (no-op offline/client).
func _net_push_state() -> void:
	if NetworkManager.is_host() and not NetworkManager.is_event_applying():
		NetworkManager.report_vcr_state(self)


## Current transport state for the sync layer.
func net_get_state() -> Dictionary:
	return {
		"playing": is_playing,
		"paused": is_playing and _paused,
		"pos": _vlc_time_sec() if is_playing else 0.0,
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(playing: bool, paused: bool, pos: float) -> void:
	if not playing:
		if is_playing:
			stop()
		return
	# Ensure we have a local file — the tape's path is remapped/downloaded by
	# object_sync; refresh in case the transfer landed after insertion.
	if video_path.is_empty() and _snapped_tape and _snapped_tape.has_method("get_video_path"):
		video_path = _snapped_tape.get_video_path()
	if not is_playing:
		if video_path.is_empty() or connected_tv == null:
			_osd("WAITING FOR TAPE…", true)
			return
		play()
		if is_playing and pos > NET_DRIFT_TOLERANCE:
			_vlc_seek_sec(pos)
	if not is_playing:
		return
	if _vlc:
		_vlc.set_paused(paused)
	_paused = paused
	if not paused and absf(_vlc_time_sec() - pos) > NET_DRIFT_TOLERANCE:
		_vlc_seek_sec(pos)


# --- Playback controls ---

# Remote-control entry points (TVRemote): identical to pressing the unit's
# front-panel buttons, including FF/REW scan toggling and OSD messages.

func remote_play() -> void:
	_on_play_pressed()


func remote_pause() -> void:
	_on_pause_pressed()


func remote_stop() -> void:
	_on_stop_pressed()


## True while playback is paused (used by the TV remote's play/pause cell).
func is_paused() -> bool:
	return _paused


func remote_ff() -> void:
	_on_ff_pressed()


func remote_rewind() -> void:
	_on_rewind_pressed()


func remote_eject() -> void:
	_slot_eject()


## True when a tape is loaded (the remote greys its Eject cell otherwise).
func has_media() -> bool:
	return _snapped_tape != null


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if is_playing and (_scan_dir != 0 or _paused):
		# Leaving a scan or resuming from pause both mean "back to normal play".
		_set_scan(0)
		if _vlc:
			_vlc.set_paused(false)
		_paused = false
		_osd("PLAY", false)
		_net_push_state()
		return
	play()


func _on_pause_pressed() -> void:
	if _net_forward_cmd("pause"):
		return
	if is_playing:
		_scan_dir = 0
		if _vlc:
			_vlc.set_paused(true)
		_paused = true
		_apply_volume()   # undo any scan mute
		_osd("PAUSE", true)
		_net_push_state()


func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	stop()


## Rewind button: toggle reverse scan (press again, or Play/Pause, to exit).
func _on_rewind_pressed() -> void:
	if _net_forward_cmd("rew"):
		return
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
	if _net_forward_cmd("ff"):
		return
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
	_scan_dir = dir
	_scan_accum = 0.0
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	if _audio_player:
		_audio_player.volume_db = -80.0 if dir != 0 else _volume_db()
	_net_push_state()


## Set the audio-player level from the current linear volume (or silence).
func _volume_db() -> float:
	return linear_to_db(_volume_linear) if _volume_linear > 0.001 else -80.0


func _apply_volume() -> void:
	if _audio_player:
		_audio_player.volume_db = _volume_db()


func play() -> void:
	if connected_tv == null:
		push_error("VCRPlayer: Cannot play - no TV connected")
		return
	if video_path.is_empty():
		push_error("VCRPlayer: Cannot play - no tape inserted")
		return
	if _vlc == null:
		push_error("VCRPlayer: VlcPlayer unavailable (extension not loaded)")
		return
	if not _vlc.open(video_path, false):
		push_error("VCRPlayer: VlcPlayer.open failed for ", video_path)
		return
	_vlc.play()
	# Full internal gain — level is controlled by the Godot 3D player (TV knob).
	_vlc.set_volume(100)
	is_playing = true
	_paused = false
	_scan_dir = 0
	if _audio_player:
		_audio_player.play()
		_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
		_apply_volume()
	_bind_screen_to_tv()
	_osd("PLAY", false)
	_net_push_state()


func stop() -> void:
	if not is_playing:
		return
	_scan_dir = 0
	if _vlc:
		_vlc.stop()
	is_playing = false
	_paused = false
	if _audio_player:
		_audio_player.stop()
	_audio_playback = null
	_blank_screen()
	if connected_tv:
		connected_tv.hide_osd()
	_net_push_state()


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
	_volume_linear = clampf(volume, 0.0, 1.0)
	# Don't fight an active scan mute; it restores on scan exit.
	if _scan_dir == 0:
		_apply_volume()


## Show or hide the screen output. Called by the TV toggle button.
func set_screen_enabled(enabled: bool) -> void:
	if not connected_tv:
		return
	if enabled and is_playing:
		_bind_screen_to_tv()
	else:
		_blank_screen()


# --- Screen routing ---

## Route the VlcPlayer's frame texture onto the connected TV screen mesh.
func _bind_screen_to_tv() -> void:
	if connected_tv == null or _vlc == null:
		return
	var mesh := connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var tex: Texture2D = _vlc.get_texture()
	if tex == null:
		return
	if _screen_material == null or not _material_matches_effect():
		_screen_material = _make_screen_material()
	if _screen_material is ShaderMaterial:
		(_screen_material as ShaderMaterial).set_shader_parameter("video_tex", tex)
	else:
		(_screen_material as StandardMaterial3D).albedo_texture = tex
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
		_apply_vcr_params(mat)
		return mat
	# Unshaded so the picture reads as a self-lit screen (same look as the shader
	# path, without the VHS effect) instead of being lit + double-bright emission.
	var std := StandardMaterial3D.new()
	std.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return std


## Toggle the VHS effect at runtime; rebinds the screen if currently playing.
func set_vcr_effect_enabled(enabled: bool) -> void:
	if vcr_effect_enabled == enabled:
		return
	vcr_effect_enabled = enabled
	if is_playing:
		_bind_screen_to_tv()


## Push every stored VHS uniform onto the given screen shader material.
func _apply_vcr_params(mat: ShaderMaterial) -> void:
	for key: String in _vcr_params:
		mat.set_shader_parameter(key, _vcr_params[key])


## Set one VHS uniform, remembering it and applying live if the effect material
## is currently installed. Called by VCROptionsPanel.
func set_vcr_param(pname: String, value: Variant) -> void:
	if not _vcr_params.has(pname):
		return
	_vcr_params[pname] = value
	if _screen_material is ShaderMaterial:
		(_screen_material as ShaderMaterial).set_shader_parameter(pname, value)


## Current VHS uniform values, for the options panel to populate its controls.
func get_vcr_params() -> Dictionary:
	return _vcr_params.duplicate()


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
	_paused = false
	if _audio_player:
		_audio_player.stop()
	_audio_playback = null


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
