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

## Fast-forward / rewind scan rate: seconds of video traversed per real second.
@export var scan_speed: float = 8.0

# Runtime state
var dvd_path: String = ""
var connected_tv: RetroTV = null
var is_playing: bool = false

# FF/REW scan (only meaningful during title playback, not in a disc menu):
# 0 = normal, +1 = forward, -1 = reverse. Mirrors the VCR's scan.
var _scan_dir: int = 0
var _scan_accum: float = 0.0
const SCAN_SEEK_INTERVAL := 0.08

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

# Cached track counts for the remote's audio/subtitle greying (-1 = not yet
# known; libVLC populates the lists a beat after play()). Refreshed on a low-rate
# throttle in _process and after each cycle.
var _n_audio: int = -1
var _n_sub: int = -1
var _track_refresh_accum: float = 0.0

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
@onready var _rewind_button: VRButton = $RewindButton
@onready var _ff_button: VRButton = $FastForwardButton
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
	_rewind_button.button_pressed.connect(_on_rewind_pressed)
	_ff_button.button_pressed.connect(_on_ff_pressed)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_play_button.set_color(Color(0.0, 0.9, 0.0))    # green
	_pause_button.set_color(Color(0.9, 0.8, 0.0))    # amber
	_stop_button.set_color(Color(0.9, 0.1, 0.1))     # red
	_menu_button.set_color(Color(0.2, 0.5, 0.95))    # blue
	_prev_button.set_color(Color(0.5, 0.5, 0.55))
	_next_button.set_color(Color(0.5, 0.5, 0.55))
	_rewind_button.set_color(Color(0.1, 0.4, 0.9))   # blue
	_ff_button.set_color(Color(0.1, 0.4, 0.9))       # blue
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


func _process(delta: float) -> void:
	if _vlc == null:
		return
	# Pump the latest decoded frame into the VLC texture every frame.
	_vlc.update_frame()
	if is_playing and connected_tv != null:
		_bind_screen_to_tv()
	_pump_audio()
	_update_scan(delta)
	# Low-rate refresh of the cached audio/subtitle track counts (the remote reads
	# these to grey its Audio/Subtitle cells).
	if is_playing:
		_track_refresh_accum += delta
		if _track_refresh_accum >= 0.5:
			_track_refresh_accum = 0.0
			_refresh_track_counts()
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
func remote_ff() -> void: _on_ff_pressed()
func remote_rewind() -> void: _on_rewind_pressed()


## True while playback is paused (used by the TV remote's play/pause cell).
func is_paused() -> bool:
	return _paused


func _on_play_pressed() -> void:
	if _net_forward_cmd("play"):
		return
	if not is_playing:
		play()
	else:
		# Leaving a scan or resuming from pause both mean "back to normal play".
		_set_scan(0)
		_vlc.set_paused(false)
		_paused = false
		_osd("PLAY")
		_net_push_state()


func _on_pause_pressed() -> void:
	if _net_forward_cmd("pause"):
		return
	if is_playing and _vlc:
		_set_scan(0)
		_vlc.set_paused(true)
		_paused = true
		_osd("PAUSE")
		_net_push_state()


## Fast-forward button: toggle forward scan (press again, or Play/Pause, to exit).
## No-op while showing a disc menu (there's nothing to scan through there).
func _on_ff_pressed() -> void:
	if _net_forward_cmd("ff"):
		return
	if not is_playing or is_in_menu():
		return
	if _scan_dir == 1:
		_set_scan(0)
		_osd("PLAY")
	else:
		_set_scan(1)
		_osd("FF >>")


## Rewind button: toggle reverse scan (press again, or Play/Pause, to exit).
func _on_rewind_pressed() -> void:
	if _net_forward_cmd("rew"):
		return
	if not is_playing or is_in_menu():
		return
	if _scan_dir == -1:
		_set_scan(0)
		_osd("PLAY")
	else:
		_set_scan(-1)
		_osd("<< REW")


## Enter (dir = ±1) or leave (dir = 0) a scan. The player keeps playing (frames
## present) but is muted while scanning; leaving restores the prior volume.
func _set_scan(dir: int) -> void:
	_scan_dir = dir
	_scan_accum = 0.0
	if _vlc:
		_vlc.set_paused(false)
	_paused = false
	if _audio_player:
		_audio_player.volume_db = -80.0 if dir != 0 else _dvd_volume_db()


func _dvd_volume_db() -> float:
	return linear_to_db(_volume_linear) if _volume_linear > 0.001 else -80.0


## While scanning, jump the (still-playing) position forward/back in throttled
## steps so frames visibly race by; hold at either end of the title.
func _update_scan(delta: float) -> void:
	if _scan_dir == 0 or not is_playing or _vlc == null:
		return
	if is_in_menu():
		_set_scan(0)
		return
	_scan_accum += delta
	if _scan_accum < SCAN_SEEK_INTERVAL:
		return
	var length := float(_vlc.get_length())
	var pos := float(_vlc.get_time()) + _scan_accum * scan_speed * 1000.0 * float(_scan_dir)
	_scan_accum = 0.0
	if length <= 0.0:
		return
	if pos <= 0.0:
		_vlc.set_position(0.0)
		_end_scan_hold()
	elif pos >= length:
		_vlc.set_position(1.0)
		_end_scan_hold()
	else:
		_vlc.set_position(clampf(pos / length, 0.0, 1.0))


func _end_scan_hold() -> void:
	_set_scan(0)
	if _vlc:
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
	_scan_dir = 0
	_n_audio = -1        # unknown until libVLC parses the new disc
	_n_sub = -1
	if _audio_player:
		_audio_player.play()
		_audio_playback = _audio_player.get_stream_playback() as AudioStreamGeneratorPlayback
		_audio_player.volume_db = linear_to_db(_volume_linear) if _volume_linear > 0.001 else -80.0
	_osd("DVD")
	_net_push_state()


func stop() -> void:
	if not is_playing:
		return
	_scan_dir = 0
	if _vlc:
		_vlc.stop()
	is_playing = false
	_paused = false
	_n_audio = -1
	_n_sub = -1
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


# --- Audio-track / subtitle cycling (called by the remote) ---

func dvd_cycle_audio() -> void:
	if _net_forward_cmd("audio"): return
	_cycle_audio_local()
	_net_push_state()


func dvd_cycle_subtitle() -> void:
	if _net_forward_cmd("subtitle"): return
	_cycle_subtitle_local()
	_net_push_state()


## Advance to the next audio track (wraps), OSD the new track name.
func _cycle_audio_local() -> void:
	if _vlc == null:
		return
	var tracks: Array = _vlc.get_audio_tracks()
	if tracks.size() <= 1:
		_osd("AUDIO: —")
		return
	var id := _next_track_id(tracks, _vlc.get_audio_track())
	_vlc.set_audio_track(id)
	_osd("AUDIO: " + _track_name(tracks, id))
	_refresh_track_counts()


## Advance to the next subtitle track (wraps; libVLC's list includes a -1 "Disable"
## entry, so cycling naturally passes through subtitles-off).
func _cycle_subtitle_local() -> void:
	if _vlc == null:
		return
	var tracks: Array = _vlc.get_subtitle_tracks()
	if tracks.is_empty():
		_osd("SUB: —")
		return
	var id := _next_track_id(tracks, _vlc.get_subtitle())
	_vlc.set_subtitle(id)
	_osd("SUB: " + _track_name(tracks, id))
	_refresh_track_counts()


## Next id after `cur` in a [{id,name}] track list, wrapping around.
func _next_track_id(tracks: Array, cur: int) -> int:
	var ids: Array = []
	for t: Dictionary in tracks:
		ids.append(int(t["id"]))
	if ids.is_empty():
		return cur
	var idx := ids.find(cur)
	return int(ids[(idx + 1) % ids.size()])


## Human label for a track id (falls back to "Off" for -1, else the raw id).
func _track_name(tracks: Array, id: int) -> String:
	for t: Dictionary in tracks:
		if int(t["id"]) == id:
			var n := str(t["name"])
			if not n.is_empty():
				return n
			return "Off" if id == -1 else str(id)
	return "—"


## Refresh the cached audio/subtitle track counts used for remote greying.
func _refresh_track_counts() -> void:
	if _vlc == null or not is_playing:
		_n_audio = -1
		_n_sub = -1
		return
	_n_audio = (_vlc.get_audio_tracks() as Array).size()
	_n_sub = (_vlc.get_subtitle_tracks() as Array).size()


## Whether the disc offers more than one audio track (read by the TV remote to
## grey the Audio cell). Optimistic while the count is still unknown (-1).
func has_audio_options() -> bool:
	return _n_audio < 0 or _n_audio > 1


## Whether the disc offers a real subtitle beyond libVLC's "Disable" entry.
func has_subtitle_options() -> bool:
	return _n_sub < 0 or _n_sub > 1


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
			"time": 0, "length": 0, "menu": false, "audio": -1, "sub": -1}
	return {
		"playing": true,
		"paused": _paused,
		"title": _vlc.get_title(),
		"chapter": _vlc.get_chapter(),
		"time": _vlc.get_time(),
		"length": _vlc.get_length(),
		"menu": _vlc.is_in_menu(),
		"audio": _vlc.get_audio_track(),
		"sub": _vlc.get_subtitle(),
	}


## Client: mirror the host's transport state on the LOCAL player.
func net_apply_state(playing: bool, paused: bool, title: int, chapter: int,
		time_ms: int, length_ms: int, menu: bool, audio_id: int, sub_id: int) -> void:
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
	# Follow the host's audio/subtitle selection (shared TV screen).
	if audio_id >= 0 and _vlc.get_audio_track() != audio_id:
		_vlc.set_audio_track(audio_id)
	if _vlc.get_subtitle() != sub_id:
		_vlc.set_subtitle(sub_id)


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
	# Don't fight an active scan mute; it restores on scan exit.
	if _audio_player and _scan_dir == 0:
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
