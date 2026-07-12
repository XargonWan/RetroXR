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

# Cable (shared with RetroSystem / VCRPlayer)
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

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

	_spawn_cable()
	_update_name_label()


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
	play()


func _on_disc_removed() -> void:
	if _snapped_disc:
		remove_collision_exception_with(_snapped_disc)
		_snapped_disc = null
	stop()
	dvd_path = ""


func _on_eject_pressed() -> void:
	# Drop the snapped disc out of the slot (also stops playback via has_dropped).
	if _snapped_disc and _disc_slot.has_method("drop_object"):
		_disc_slot.drop_object()


# --- Playback controls ---

func remote_play() -> void: _on_play_pressed()
func remote_pause() -> void: _on_pause_pressed()
func remote_stop() -> void: _on_stop_pressed()


func _on_play_pressed() -> void:
	if not is_playing:
		play()
	else:
		_vlc.set_paused(false)
	_osd("PLAY")


func _on_pause_pressed() -> void:
	if is_playing and _vlc:
		_vlc.set_paused(true)
		_osd("PAUSE")


func _on_stop_pressed() -> void:
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
	is_playing = true
	_osd("DVD")


func stop() -> void:
	if not is_playing:
		return
	if _vlc:
		_vlc.stop()
	is_playing = false
	_blank_screen()
	if connected_tv:
		connected_tv.hide_osd()


func _on_disc_finished() -> void:
	is_playing = false


# --- DVD menu / chapter control (called by the remote) ---

func dvd_menu_up() -> void: if _vlc: _vlc.menu_up()
func dvd_menu_down() -> void: if _vlc: _vlc.menu_down()
func dvd_menu_left() -> void: if _vlc: _vlc.menu_left()
func dvd_menu_right() -> void: if _vlc: _vlc.menu_right()
func dvd_ok() -> void: if _vlc: _vlc.menu_activate()
func dvd_root_menu() -> void:
	if _vlc:
		_vlc.menu_popup()
		_osd("MENU")


func dvd_next_chapter() -> void:
	if _vlc:
		_vlc.next_chapter()
		_osd("NEXT")


func dvd_prev_chapter() -> void:
	if _vlc:
		_vlc.prev_chapter()
		_osd("PREV")


## Whether the disc is currently showing a menu (drives the remote's button set).
func is_in_menu() -> bool:
	return _vlc != null and _vlc.is_in_menu()


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
	if _vlc:
		_vlc.set_volume(int(clampf(volume, 0.0, 1.0) * 100.0))


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
