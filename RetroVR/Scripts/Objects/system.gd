## RetroSystem — pickable retro console that loads a libretro core and renders to a connected TV.
class_name RetroSystem
extends XRToolsPickable


## The libretro core filename (without extension), e.g. "fceumm".
## If empty at power_on(), looked up from CoreDefaults using systemid.
@export var core_name: String = ""

## Root directory passed to the C++ core loader (NOT the cores/ subdir — C++ appends that).
## If empty at power_on(), defaults to CoreDownloadManager.default_core_root().
@export_dir var core_directory: String = ""

## Human-readable label shown in UI
@export var system_label: String = ""

## libretro systemid (e.g. "nes", "super_nes"). Used for dynamic core lookup.
@export var systemid: String = ""

## Spatial audio settings for the AudioStreamPlayer3D created at runtime.
@export_group("Spatial Audio")
@export var audio_unit_size: float = 3.0        ## Reference distance (m) for full volume
@export var audio_max_distance: float = 15.0    ## Distance (m) at which sound is fully silent
@export var audio_panning_strength: float = 1.0 ## Left/right stereo separation (1.0 = default)
@export_group("")


# Runtime state
var rom_path: String = ""
var connected_tv: RetroTV = null
var is_powered_on: bool = false

# Cached core options (populated when options_ready fires)
var _options_definitions: Dictionary = {}
var _options_values: Dictionary = {}

# Cached controller port info (populated alongside options_ready).
# Array of Dictionaries: [{port, controllers: [{name, id}], current_id}]
var _controller_info: Array = []

# Cable scene to instantiate
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# TV to connect to after the cable finishes spawning (used by save/load restore)
var _pending_tv_restore: RetroTV = null
var _snapped_cartridge: Node3D = null


@onready var _cartridge_slot: XRToolsSnapZone = $CartridgeSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _libretro: Libretro = $Libretro
@onready var _power_button: VRButton = $PowerButton
@onready var _reset_button: VRButton = $ResetButton
@onready var _power_button_label: Label3D = $PowerButton/ButtonLabel
@onready var _options_panel: CoreOptionsPanel = $CoreOptionsPanel
@onready var _system_name_label: Label3D = $SystemNameLabel


func _ready() -> void:
	super._ready()
	add_to_group("retro_system")
	_cartridge_slot.has_picked_up.connect(_on_cartridge_inserted)
	_cartridge_slot.has_dropped.connect(_on_cartridge_removed)
	_power_button.button_pressed.connect(toggle_power)
	_reset_button.button_pressed.connect(reset)
	# Initialize power button to "off" color
	_power_button.set_color(Color(0.0, 1.0, 0.0))  # Green when off
	_libretro.options_ready.connect(_on_options_ready)
	# Spawn cable
	_spawn_cable()
	_update_name_label()


func _update_name_label() -> void:
	var display_name := system_label
	if display_name.is_empty() and not systemid.is_empty():
		var db := CoreInfoDatabase.new()
		db.load_from_project()
		display_name = db.get_systemname_for_id(systemid)
	if display_name.is_empty():
		display_name = systemid
	_system_name_label.text = display_name.to_upper()


## Enable or disable libretro input polling for this system.
## Only the actively-controlled instance should have input enabled.
func set_input_enabled(enabled: bool) -> void:
	_libretro.SetInputEnabled(enabled)


## Set the audio volume for the running libretro instance (0.0 = silent, 1.0 = 100%).
func set_audio_volume(volume: float) -> void:
	if not is_powered_on:
		return
	var asp := _libretro.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	if asp:
		asp.volume_db = linear_to_db(volume) if volume > 0.001 else -80.0


## Show or hide the screen output (used by TV toggle button).
func set_screen_enabled(enabled: bool) -> void:
	if not is_powered_on:
		return
	if enabled and connected_tv:
		_libretro.SetScreenMesh(connected_tv.get_screen_mesh())
	else:
		_libretro.SetScreenMesh(null)


## Called by the TV's cable plug when it connects to a TV
func on_tv_connected(tv: RetroTV) -> void:
	connected_tv = tv
	if is_powered_on:
		_libretro.SetScreenMesh(tv.get_screen_mesh())


## Called by the TV's cable plug when it disconnects
func on_tv_disconnected() -> void:
	if is_powered_on:
		_libretro.SetScreenMesh(null)
	connected_tv = null


# --- Cable management ---

func _spawn_cable() -> void:
	_cable_instance = CABLE_SCENE.instantiate()
	# Add cable to scene root so it's not affected by system's RigidBody transform weirdness
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	# Track cable in the "spawned" group so clear_scene() includes it.
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("CablePlug") as CablePlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope

	# Tell the plug who owns it
	_cable_plug.set_system(self)

	# Exclude the plug from colliding with this system so it doesn't jitter on spawn
	_cable_plug.add_collision_exception_with(self)

	# Position plug at the same Y as the rope's start anchor (the attach point)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.1)

	# Wire rope anchors: start = system's attach point, end = plug
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	# Restore a pending TV connection requested before the cable was ready
	if _pending_tv_restore != null:
		print("[RetroSystem] _add_cable_to_scene: restoring pending TV connection")
		_snap_cable_to_tv(_pending_tv_restore)
		_pending_tv_restore = null


func _physics_process(_delta: float) -> void:
	if _cable_plug == null or _cable_attach_point == null or _max_rope_length <= 0.0:
		return
	# Snapped to TV or actively held by the user — don't fight whoever owns the plug
	if connected_tv != null or _cable_plug.is_picked_up():
		return

	var attach_pos := _cable_attach_point.global_position
	var diff := _cable_plug.global_position - attach_pos
	var dist := diff.length()

	if dist > _max_rope_length:
		var dir := diff / dist
		# Clamp plug to rope length and kill outward velocity
		_cable_plug.global_position = attach_pos + dir * _max_rope_length
		var outward_vel := dir.dot(_cable_plug.linear_velocity)
		if outward_vel > 0.0:
			_cable_plug.linear_velocity -= dir * outward_vel


## Power on: start this system's libretro core
func power_on() -> void:
	if is_powered_on:
		return
	if connected_tv == null:
		push_error("RetroSystem: Cannot power on - no TV connected")
		return
	if rom_path.is_empty():
		push_error("RetroSystem: Cannot power on - no cartridge inserted")
		return

	# Resolve core_name from CoreDefaults if not baked into the scene
	var resolved_core := core_name
	if resolved_core.is_empty() and not systemid.is_empty():
		var defaults := CoreDefaults.new()
		defaults.setup(CoreDefaults.default_path())
		resolved_core = defaults.get_default_core(systemid)
	if resolved_core.is_empty():
		push_error("RetroSystem: Cannot power on - no core set and no default for systemid '%s'" % systemid)
		return

	# Resolve core_directory — C++ appends /cores/ internally, so pass the root dir
	var resolved_dir := core_directory
	if resolved_dir.is_empty():
		resolved_dir = CoreDownloadManager.default_core_root()

	print("[RetroSystem] Powering on: core=%s dir=%s rom=%s" % [resolved_core, resolved_dir, rom_path])
	_libretro.StartContent(connected_tv.get_screen_mesh(), resolved_dir, resolved_core, rom_path)
	var asp := _libretro.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	if asp:
		asp.unit_size        = audio_unit_size
		asp.max_distance     = audio_max_distance
		asp.panning_strength = audio_panning_strength
	is_powered_on = true
	_power_button.set_color(Color(1.0, 0.0, 0.0))  # Bright red when on
	_power_button_label.text = "STOP"


## Power off: stop the running core
func power_off() -> void:
	if not is_powered_on:
		return
	print("[RetroSystem] Powering off")
	_libretro.StopContent()
	is_powered_on = false
	_power_button.set_color(Color(0.0, 1.0, 0.0))  # Green when off
	_power_button_label.text = "START"
	_options_panel.hide_panel()


## Toggle power (used by the power button)
func toggle_power() -> void:
	if is_powered_on:
		power_off()
	else:
		power_on()


## Hard reset: stop and restart with the same content
func reset() -> void:
	if is_powered_on:
		power_off()
		power_on()


# --- Core options ---

## Fired by the Libretro node (via options_ready signal) once the emulation core
## has registered its option set. Caches the data and refreshes the panel if it
## is already open so live changes (e.g. second options_ready after reset) appear.
func _on_options_ready(_categories: Dictionary, definitions: Dictionary, current_values: Dictionary) -> void:
	print("[RetroSystem] options_ready — %d definitions received" % definitions.size())
	_options_definitions = definitions
	_options_values = current_values
	# Controller info is set during retro_load_game, so it's ready by the time
	# options_ready fires. Fetch it here so the panel can show both tabs.
	_controller_info = _libretro.GetControllerInfo()
	print("[RetroSystem] controller info fetched — %d ports" % _controller_info.size())
	if _options_panel.visible:
		_options_panel.refresh()


## Toggle the core options panel open or closed.
## Called by SpawnMenuController when the user points at this system and presses
## the left thumbstick (primary_click action).
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel.visible:
		print("[RetroSystem] closing options panel")
		_options_panel.hide_panel()
	else:
		print("[RetroSystem] opening options panel")
		_options_panel.show_for(self, camera)


## Apply a single core option change and forward it to the running libretro core.
## Also updates the local cache so the panel stays in sync if reopened.
func set_core_option(key: String, value: String) -> void:
	print("[RetroSystem] set_core_option '%s' = '%s'" % [key, value])
	_options_values[key] = value
	_libretro.SetCoreOption(key, value)


## Switch the input device type on a given controller port.
## device_id corresponds to RETRO_DEVICE_* constants (1 = joypad, 5 = analog, etc.).
func set_controller_port_device(port: int, device_id: int) -> void:
	print("[RetroSystem] set_controller_port_device port=%d device=%d" % [port, device_id])
	# Update the cached current_id so reopening the panel shows the right selection
	for entry in _controller_info:
		if entry["port"] == port:
			entry["current_id"] = device_id
			break
	_libretro.SetControllerPortDevice(port, device_id)


# --- Cartridge slot callbacks ---

## Returns the currently snapped cartridge, or null (used by save/load).
func get_snapped_cartridge() -> Node3D:
	return _snapped_cartridge


## Restore a cable→TV connection after loading from a save file.
## Safe to call before the cable has finished spawning — the snap will be
## deferred until _add_cable_to_scene() runs if the plug isn't ready yet.
func restore_cable_connection(tv: RetroTV) -> void:
	print("[RetroSystem] restore_cable_connection: plug=%s tv=%s" % [_cable_plug, tv])
	if _cable_plug != null:
		_snap_cable_to_tv(tv)
	else:
		print("[RetroSystem] cable plug not ready yet, deferring restore")
		_pending_tv_restore = tv


func _snap_cable_to_tv(tv: RetroTV) -> void:
	tv.accept_plug_restore(_cable_plug)


## Restore a cartridge→slot insertion after loading from a save file.
func restore_cartridge(cartridge: Node3D) -> void:
	_cartridge_slot.pick_up_object(cartridge)


func _on_cartridge_inserted(cartridge: Node3D) -> void:
	_snapped_cartridge = cartridge
	# Prevent the frozen kinematic cartridge from physically pushing the system body
	add_collision_exception_with(cartridge)
	if cartridge.has_method("get_rom_path"):
		rom_path = cartridge.get_rom_path()


func _on_cartridge_removed() -> void:
	if _snapped_cartridge:
		remove_collision_exception_with(_snapped_cartridge)
		_snapped_cartridge = null
	if is_powered_on:
		power_off()
	rom_path = ""
