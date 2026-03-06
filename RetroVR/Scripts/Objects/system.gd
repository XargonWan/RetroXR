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


# Runtime state
var rom_path: String = ""
var connected_tv: RetroTV = null
var is_powered_on: bool = false

# Cable scene to instantiate
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0


@onready var _cartridge_slot: XRToolsSnapZone = $CartridgeSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _libretro: Libretro = $Libretro
@onready var _power_button: VRButton = $PowerButton
@onready var _reset_button: VRButton = $ResetButton
@onready var _power_button_label: Label3D = $PowerButton/ButtonLabel


func _ready() -> void:
	super._ready()
	add_to_group("retro_system")
	_cartridge_slot.has_picked_up.connect(_on_cartridge_inserted)
	_cartridge_slot.has_dropped.connect(_on_cartridge_removed)
	_power_button.button_pressed.connect(toggle_power)
	_reset_button.button_pressed.connect(reset)
	# Initialize power button to "off" color
	_power_button.set_color(Color(0.0, 1.0, 0.0))  # Green when off
	# Spawn cable
	_spawn_cable()


## Enable or disable libretro input polling for this system.
## Only the actively-controlled instance should have input enabled.
func set_input_enabled(enabled: bool) -> void:
	_libretro.SetInputEnabled(enabled)


## Called by the TV's cable plug when it connects to a TV
func on_tv_connected(tv: RetroTV) -> void:
	connected_tv = tv


## Called by the TV's cable plug when it disconnects
func on_tv_disconnected() -> void:
	if is_powered_on:
		power_off()
	connected_tv = null


# --- Cable management ---

func _spawn_cable() -> void:
	_cable_instance = CABLE_SCENE.instantiate()
	# Add cable to scene root so it's not affected by system's RigidBody transform weirdness
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
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


# --- Cartridge slot callbacks ---

var _snapped_cartridge: Node3D = null

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
