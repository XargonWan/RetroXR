## DVDPlayer — a pickable DVD deck that plays a real DVD image (VIDEO_TS/.iso/.img)
## onto a connected TV, with working disc menus + chapter navigation driven by the
## TV remote. Playback is handled by the libVLC-backed VlcPlayer GDExtension, which
## renders the disc's own menus into the picture; the remote forwards D-pad/OK and
## chapter presses into libVLC navigation.
##
## Reuses the same cable/plug/TV wiring as VCRPlayer / RetroSystem.
class_name DVDPlayer
extends XRToolsPickable

## Human-readable label shown above the unit.
@export var dvd_label: String = "DVD"

# Runtime state
var dvd_path: String = ""
var connected_tv: RetroTV = null
var is_playing: bool = false

var _vlc: Object = null                 # VlcPlayer (GDExtension)
var _screen_material: StandardMaterial3D = null
var _snapped_disc: Node3D = null

# Spatial audio: libVLC decodes PCM into VlcPlayer's ring buffer; we drain it into
# an AudioStreamGenerator on a 3D player positioned at the connected TV, so DVD
# sound is spatialised (and the TV volume knob scales it) like the console audio.
var _audio_player: AudioStreamPlayer3D = null
var _audio_playback: AudioStreamGeneratorPlayback = null
var _volume_linear: float = 1.0
var _paused: bool = false

# Multiplayer (Phase 5): the host is the transport + menu authority; every peer
# plays its own local copy of the disc (verify-only by MD5, never transferred —
# same legal stance as ROMs). Sync is drift-corrected on title/chapter/time, not
# lockstep; the disc's menu-VM highlight state is not replicated (both peers boot
# the same root menu, and content transitions resync via title/chapter). See the
# NetObjectSync header.
const NET_DRIFT_TOLERANCE := 1.0   # seconds of content drift before a seek

# Cable (shared with RetroSystem / VCRPlayer)
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
# TV to reconnect to once the cable finishes spawning (save/load + net restore).
var _pending_tv_restore: RetroTV = null

@onready var _disc_slot: XRToolsSnapZone = $DiscSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _play_button: VRButton = $PlayButton
@onready var _pause_button: VRButton = $PauseButton
@onready var _stop_button: VRButton = $StopButton
@onready var _menu_button: VRButton = $MenuButton
@onready var _prev_button: VRButton = $PrevChapterButton
@onready var _next_button: VRButton = $NextChapterButton
@onready var _eject_button: VRButton = $EjectButton
@onready var _name_label: Label3D = $NameLabel
@onready var _options_panel: DVDOptionsPanel = $DVDOptionsPanel


func _ready() -> void:
	super._ready()
	add_to_group("dvd_player")
	_disc_slot.has_picked_up.connect(_on_disc_inserted)
	_disc_slot.has_dropped.connect(_on_disc_removed)
	_play_button.button_pressed.connect(_on_play_pressed)
	_pause_button.button_pressed.connect(_on_pause_pressed)
	_stop_button.button_pressed.connect(_on_stop_pressed)
	_menu_button.button_pressed.connect(_on_menu_pressed)
	_prev_button.button_pressed.connect(dvd_prev_chapter)
	_next_button.button_pressed.connect(dvd_next_chapter)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))    # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))    # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))     # red
	_menu_button.set_color(Color(0.2, 0.5, 0.95))    # blue
	_prev_button.set_color(Color(0.5, 0.5, 0.55))
	_next_button.set_color(Color(0.5, 0.5, 0.55))
	_eject_button.set_color(Color(0.8, 0.8, 0.85))

	if ClassDB.class_exists("VlcPlayer"):
		_vlc = ClassDB.instantiate("VlcPlayer")
		_vlc.finished.connect(_on_disc_finished)
	else:
		push_error("DVDPlayer: VlcPlayer extension not loaded — DVD playback unavailable")

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
		_name_label.text = dvd_label.to_upper()


func _process(_delta: float) -> void:
	if _vlc == null:
		return
	# Pump the latest decoded frame into the VLC texture every frame.
	_vlc.update_frame()
	if is_playing and connected_tv != null:
		_bind_screen_to_tv()
	_pump_audio()
	# Emanate the sound from the connected TV so it's spatialised there.
	if _audio_player and connected_tv != null and is_instance_valid(connected_tv):
		_audio_player.global_position = connected_tv.global_position


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


## Toggle the disc menu-control routing is done via the remote; the front Menu
## button just returns to the disc's root menu.
func _on_menu_pressed() -> void:
	dvd_root_menu()


# --- Disc slot callbacks ---

func _on_disc_inserted(disc: Node3D) -> void:
	_snapped_disc = disc
	add_collision_exception_with(disc)
	if disc.has_method("get_dvd_path"):
		dvd_path = disc.get_dvd_path()
	NetworkManager.report_event(NetObjectSync.EV_DVD_INSERT, {"dvd": self, "disc": disc})
	# In a session, playback is host-authoritative — it starts via the transport
	# commands / DVD state broadcast (mirrors the VCR, which never auto-plays on
	# insert). Offline, auto-boot straight to the disc menu.
	if not NetworkManager.is_active():
		play()


func _on_disc_removed() -> void:
	if _snapped_disc:
		remove_collision_exception_with(_snapped_disc)
		_snapped_disc = null
	stop()
	dvd_path = ""
	NetworkManager.report_event(NetObjectSync.EV_DVD_REMOVE, {"dvd": self})


func _on_eject_pressed() -> void:
	# Drop the snapped disc out of the slot (also stops playback via has_dropped).
	if _snapped_disc and _disc_slot.has_method("drop_object"):
		_disc_slot.drop_object()


# --- Playback controls ---

func remote_play() -> void: _on_play_pressed()
func remote_pause() -> void: _on_pause_pressed()
func remote_stop() -> void: _on_stop_pressed()


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if not is_playing:
		play()
	else:
		_vlc.set_paused(false)
		_paused = false
		_osd("PLAY")
		_net_push_state()


func _on_pause_pressed() -> void:
	if _net_forward_cmd("pause"):
		return
	if is_playing and _vlc:
		_vlc.set_paused(true)
		_paused = true
		_osd("PAUSE")
		_net_push_state()


func _on_stop_pressed() -> void:
	if _net_forward_cmd("stop"):
		return
	stop()


func play() -> void:
	if _vlc == null:
		return
	if connected_tv == null:
		push_error("DVDPlayer: cannot play - no TV connected")
		return
	if dvd_path.is_empty():
		push_error("DVDPlayer: cannot play - no disc inserted")
		return
	if not _vlc.open(dvd_path, true):
		push_error("DVDPlayer: VlcPlayer.open failed for ", dvd_path)
		return
	_vlc.play()
	# Full internal gain — level is controlled by the Godot 3D player (TV knob).
	_vlc.set_volume(100)
	is_playing = true
	_paused = false
	if _audio_player:
		_audio_player.play()
		_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
		_audio_player.volume_db = linear_to_db(_volume_linear) if _volume_linear > 0.001 else -80.0
	_osd("DVD")
	_net_push_state()


func stop() -> void:
	if not is_playing:
		return
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


func _on_disc_finished() -> void:
	is_playing = false


# --- DVD menu / chapter control (called by the remote) ---

func dvd_menu_up() -> void:
	if _net_forward_cmd("menu_up"): return
	if _vlc: _vlc.menu_up()
	_net_push_state()


func dvd_menu_down() -> void:
	if _net_forward_cmd("menu_down"): return
	if _vlc: _vlc.menu_down()
	_net_push_state()


func dvd_menu_left() -> void:
	if _net_forward_cmd("menu_left"): return
	if _vlc: _vlc.menu_left()
	_net_push_state()


func dvd_menu_right() -> void:
	if _net_forward_cmd("menu_right"): return
	if _vlc: _vlc.menu_right()
	_net_push_state()


func dvd_ok() -> void:
	if _net_forward_cmd("ok"): return
	if _vlc: _vlc.menu_activate()
	_net_push_state()


func dvd_root_menu() -> void:
	if _net_forward_cmd("root"): return
	if _vlc:
		# Real "Menu" button: return to the disc's root menu from anywhere (a
		# popup navigate does nothing mid-title on most discs).
		_vlc.go_to_menu()
		_osd("MENU")
	_net_push_state()


func dvd_next_chapter() -> void:
	if _net_forward_cmd("next_ch"): return
	if _vlc:
		_vlc.next_chapter()
		_osd("NEXT")
	_net_push_state()


func dvd_prev_chapter() -> void:
	if _net_forward_cmd("prev_ch"): return
	if _vlc:
		_vlc.prev_chapter()
		_osd("PREV")
	_net_push_state()


## Whether the disc is currently showing a menu (drives the remote's button set).
func is_in_menu() -> bool:
	return _vlc != null and _vlc.is_in_menu()


# ── Multiplayer sync (Phase 5) ────────────────────────────────────────────────
# Host is transport + menu authority. A client's transport/menu intent is
# forwarded to the host, which executes it and broadcasts DVD state; every peer
# plays its own local disc copy and drift-corrects to the host's title/chapter/
# time. Disc images are verify-only (MD5), never sent (see file_transfer.gd).

## Client-in-session: route a transport/menu intent to the host instead of
## acting locally. Returns true when forwarded (caller must then return).
func _net_forward_cmd(cmd: String) -> bool:
	if NetworkManager.is_client() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_DVD_CMD, {"dvd": self, "cmd": cmd})
		return true
	return false


## Host: broadcast the current transport state for peer drift sync (no-op
## offline / on clients / while applying a remote event).
func _net_push_state() -> void:
	if NetworkManager.is_host() and not NetworkManager.is_event_applying():
		NetworkManager.report_dvd_state(self)


## Current transport state for the sync layer.
func net_get_state() -> Dictionary:
	if not is_playing or _vlc == null:
		return {"playing": false, "paused": false, "title": 0, "chapter": 0,
			"time": 0, "length": 0, "menu": false}
	return {
		"playing": true,
		"paused": _paused,
		"title": _vlc.get_title(),
		"chapter": _vlc.get_chapter(),
		"time": _vlc.get_time(),
		"length": _vlc.get_length(),
		"menu": _vlc.is_in_menu(),
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(playing: bool, paused: bool, title: int, chapter: int,
		time_ms: int, length_ms: int, menu: bool) -> void:
	if not playing:
		if is_playing:
			stop()
		return
	# The disc path is resolved by object_sync after insertion (verify-only);
	# refresh in case it landed after the insert event.
	if dvd_path.is_empty() and _snapped_disc and _snapped_disc.has_method("get_dvd_path"):
		dvd_path = _snapped_disc.get_dvd_path()
	if not is_playing:
		if dvd_path.is_empty() or connected_tv == null:
			_osd("WAITING FOR DISC…")
			return
		play()
	if not is_playing or _vlc == null:
		return
	# Follow the host's title so menu↔playback transitions (incl. the "Menu"
	# button returning to a menu title) track on every peer. Chapter/time drift
	# is only corrected during actual playback; the menu-highlight VM state is
	# not replicated (host is the menu authority).
	if _vlc.get_title() != title:
		_vlc.set_title(title)
	if not menu:
		if _vlc.get_chapter() != chapter:
			_vlc.set_chapter(chapter)
		if length_ms > 0 and absf(float(_vlc.get_time() - time_ms)) > NET_DRIFT_TOLERANCE * 1000.0:
			_vlc.set_position(clampf(float(time_ms) / float(length_ms), 0.0, 1.0))
	_vlc.set_paused(paused)
	_paused = paused


# ── Save/load + net restore ───────────────────────────────────────────────────

func get_snapped_disc() -> Node3D:
	return _snapped_disc


## Snap a disc into the slot programmatically (event/save restore).
func restore_disc(disc: Node3D) -> void:
	_disc_slot.pick_up_object(disc)


## Reconnect the cable to a TV programmatically (EV_TV_PLUG + save restore). If
## the cable hasn't finished spawning yet, defer until it has.
func restore_cable_connection(tv: RetroTV) -> void:
	if _cable_plug != null:
		tv.accept_plug_restore(_cable_plug)
	else:
		_pending_tv_restore = tv


# --- Options panel (audio track / subtitles) ---

## Toggle the floating DVD settings panel. Called by SpawnMenuController when the
## menu button is pressed while pointing at this player.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


func get_audio_tracks() -> Array:
	return _vlc.get_audio_tracks() if _vlc else []


func get_audio_track() -> int:
	return _vlc.get_audio_track() if _vlc else -1


func set_audio_track(id: int) -> void:
	if _vlc:
		_vlc.set_audio_track(id)


func get_subtitle_tracks() -> Array:
	return _vlc.get_subtitle_tracks() if _vlc else []


func get_subtitle() -> int:
	return _vlc.get_subtitle() if _vlc else -1


func set_subtitle(id: int) -> void:
	if _vlc:
		_vlc.set_subtitle(id)


func _osd(text: String) -> void:
	if connected_tv:
		connected_tv.show_osd_timed(text, 2.0)


# --- TV connection contract (identical to VCRPlayer / RetroSystem) ---

func on_tv_connected(tv: RetroTV) -> void:
	connected_tv = tv


func on_tv_disconnected() -> void:
	if connected_tv:
		connected_tv.hide_osd()
	connected_tv = null


func set_audio_volume(volume: float) -> void:
	_volume_linear = clampf(volume, 0.0, 1.0)
	if _audio_player:
		_audio_player.volume_db = linear_to_db(_volume_linear) if _volume_linear > 0.001 else -80.0


func set_screen_enabled(enabled: bool) -> void:
	if not connected_tv:
		return
	if enabled and is_playing:
		_bind_screen_to_tv()
	else:
		_blank_screen()


# --- Screen routing ---

## Route the VlcPlayer's frame texture onto the connected TV screen mesh. Installs
## an unshaded emissive-picture material the TV recognises (its CRT wrap reads the
## albedo_texture as source_tex); the ImageTexture updates in place each frame, so
## we only (re)install when the TV has taken the screen back (e.g. blue "no signal").
func _bind_screen_to_tv() -> void:
	if connected_tv == null or _vlc == null:
		return
	var mesh := connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var tex: Texture2D = _vlc.get_texture()
	if tex == null:
		return
	if _screen_material == null:
		_screen_material = StandardMaterial3D.new()
		_screen_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_screen_material.albedo_texture = tex

	var cur := mesh.get_surface_override_material(0)
	var showing_ours := cur == _screen_material
	if cur is ShaderMaterial:
		# The TV's CRT wrapper of our material carries our texture as source_tex.
		showing_ours = (cur as ShaderMaterial).get_shader_parameter("source_tex") == tex
	if not showing_ours:
		mesh.set_surface_override_material(0, _screen_material)


func _blank_screen() -> void:
	if connected_tv == null:
		return
	var mesh := connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0, 0, 0, 1)
	mesh.set_surface_override_material(0, black)


# --- Cable management (mirrors VCRPlayer) ---

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
		_pending_tv_restore.accept_plug_restore(_cable_plug)
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
