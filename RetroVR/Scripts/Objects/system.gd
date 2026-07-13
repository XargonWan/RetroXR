## RetroSystem — pickable retro console that loads a libretro core and renders to a connected TV.
class_name RetroSystem
extends XRToolsPickable


## Maps systemid → GDScript path for the hardware model subclass.
const _MODEL_SCRIPTS: Dictionary = {
	"nes": "res://Scripts/Objects/system_models/nes_model.gd",
	"playstation": "res://Scripts/Objects/system_models/playstation_model.gd",
	"game_boy": "res://Scripts/Objects/system_models/game_boy_model.gd",
	"game_boy_advance": "res://Scripts/Objects/system_models/game_boy_advance_model.gd",
	"atari_lynx": "res://Scripts/Objects/system_models/atari_lynx_model.gd",
	"wonderswan": "res://Scripts/Objects/system_models/wonderswan_model.gd",
	"neo_geo_pocket": "res://Scripts/Objects/system_models/neo_geo_pocket_model.gd",
	"pokemon_mini": "res://Scripts/Objects/system_models/pokemon_mini_model.gd",
	"supervision": "res://Scripts/Objects/system_models/supervision_model.gd",
	"playstation_portable": "res://Scripts/Objects/system_models/psp_model.gd",
	"nds": "res://Scripts/Objects/system_models/nds_model.gd",
	"3ds": "res://Scripts/Objects/system_models/n3ds_model.gd",
	"virtual_boy": "res://Scripts/Objects/system_models/virtual_boy_model.gd",
}

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

# Active system model — always set (falls back to RetroSystemModelDefault)
var _model: RetroSystemModel = null

# Held-input component (handhelds only — the device itself is the controller)
var _handheld_input: HandheldInput = null

# Cable scene to instantiate
const CABLE_SCENE := preload("res://Scenes/Objects/cable.tscn")
var _cable_instance: Node3D = null
var _cable_plug: CablePlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0

# TV to connect to after the cable finishes spawning (used by save/load restore)
var _pending_tv_restore: RetroTV = null
var _snapped_cartridge: Node3D = null

# --- Disc loader (tray/slot) state ---
const DISC_SPIN_MAX := 25.0    # rad/s (~240 RPM) — seated disc at full speed
const DISC_SPIN_UP := 18.0     # rad/s² ramp-up (power on / tray closed)
const DISC_SPIN_DOWN := 10.0   # rad/s² ramp-down (power off / tray opened)
const TRAY_LID_OPEN_DEG := -75.0   # lid hinge angle when the tray is open
const SLOT_INSET := 0.10       # slot-load: how far inside the console a disc rides
const SLOT_PROTRUDE := 0.035   # slot-load: how far the ejected disc pokes out

# How this system loads discs (MediaDimensions.LOADER_*), cached at model load.
var _disc_loader := MediaDimensions.LOADER_NONE
var _tray_open := false        # LOADER_TRAY: lid state (starts closed)
var _disc_spin := 0.0          # current disc angular speed (rad/s)
var _slot_ejecting := false    # LOADER_SLOT: slide-out animation in flight
# Procedural disc well + hinged lid (default-model tray consoles only).
var _tray_lid_pivot: Node3D = null
var _tray_tween: Tween = null

# --- Disk control (multi-disc games: FF7 "insert disc 2") ---
# Mirrors the core's libretro disk-control state (disk_control_ready signal).
# When the running core owns the interface, pulling the disc hot-ejects
# (game keeps running) and inserting the next disc swaps it in live.
var _has_disk_control := false
var _disc_index := 0
var _disc_ejected := false


@onready var _system_body: MeshInstance3D = $SystemBody
@onready var _cartridge_slot: XRToolsSnapZone = $CartridgeSlot
@onready var _memcard_slot: XRToolsSnapZone = $MemoryCardSlot
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _libretro: Libretro = $Libretro
@onready var _power_button: VRButton = $PowerButton
@onready var _reset_button: VRButton = $ResetButton
@onready var _eject_button: VRButton = $EjectButton
@onready var _options_panel: CoreOptionsPanel = $CoreOptionsPanel
@onready var _system_name_label: Label3D = $SystemNameLabel
@onready var _port_zones: Array = [
	$ControllerPort1,
	$ControllerPort2,
	$ControllerPort3,
	$ControllerPort4,
]

## Cached RetroController currently plugged into each cabinet port (same index
## as the libretro port the core sees). Populated by the snap/release handlers
## so rumble signals can be routed back to the physical holder without a
## node tree scan on every core callback.
var _port_controllers: Array = [null, null, null, null]


func _ready() -> void:
	super._ready()
	add_to_group("retro_system")
	_cartridge_slot.has_picked_up.connect(_on_cartridge_inserted)
	_cartridge_slot.has_dropped.connect(_on_cartridge_removed)
	_memcard_slot.has_picked_up.connect(_on_memcard_inserted)
	_memcard_slot.has_dropped.connect(_on_memcard_removed)
	_power_button.button_pressed.connect(toggle_power)
	_reset_button.button_pressed.connect(reset)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_libretro.options_ready.connect(_on_options_ready)
	_libretro.rumble_state_changed.connect(_on_rumble_state_changed)
	_libretro.disk_control_ready.connect(_on_disk_control_ready)
	# Wire controller port snap signals
	for i in range(4):
		var idx := i
		_port_zones[i].has_picked_up.connect(func(obj: Node3D) -> void: _on_port_snapped(idx, obj))
		_port_zones[i].has_dropped.connect(func(obj: Node3D) -> void: _on_port_released(idx, obj))
	# Load system-specific model (falls back to default placeholder model)
	_load_system_model()
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


func _load_system_model() -> void:
	const DEFAULT := "res://Scripts/Objects/system_models/default_model.gd"
	var script_path: String = _MODEL_SCRIPTS.get(systemid, DEFAULT)
	var script := load(script_path) as GDScript
	if not script:
		push_warning("RetroSystem: failed to load model script: %s" % script_path)
		return
	_model = script.new() as RetroSystemModel
	add_child(_model)
	if systemid in _MODEL_SCRIPTS:
		_system_body.hide()
	_model.configure_buttons(_power_button, _reset_button, _eject_button)
	_model.configure_controller_ports(_port_zones)
	_model.configure_cable_attach(_cable_attach_point)
	_model.configure_cartridge_slot(_cartridge_slot)
	_model.configure_collision(self)
	# Native controller ports: prefer the per-system SystemInfo descriptor (the
	# real console's built-in port count) over the model's default, clamped to
	# the cabinet's available snap zones. A multitap plugged into a port extends
	# players beyond this on its own. Handhelds are their own controller (the
	# HandheldInput below drives port 0), so they expose NO external port zones.
	var port_count := 0
	if not _model.is_handheld():
		port_count = _model.get_controller_port_count()
		var info := SystemInfo.for_system(systemid)
		if info and info.native_ports > 0:
			port_count = info.native_ports
		port_count = clampi(port_count, 1, _port_zones.size())
	for i in range(_port_zones.size()):
		var active := i < port_count
		_port_zones[i].visible = active
		_port_zones[i].enabled = active
	# Memory-card slot only on CD-era hardware (PSX); cartridge systems keep
	# their battery save on the cartridge itself.
	var cards := _model.uses_memory_cards()
	_memcard_slot.visible = cards
	_memcard_slot.enabled = cards
	if cards:
		_model.configure_memory_card_slot(_memcard_slot)
	# Disc loader: tray consoles (PS1/GameCube…) get an OPEN button gating a
	# closed-by-default tray; slot loaders (PS2) get an always-open slot with
	# an EJECT button. Cartridge systems hide the button entirely.
	_disc_loader = MediaDimensions.disc_loader(systemid)
	var has_loader := _disc_loader != MediaDimensions.LOADER_NONE
	_eject_button.visible = has_loader
	_eject_button.set_deferred("monitoring", has_loader)
	_eject_button.set_process(has_loader)   # also stops touch-proximity checks
	if has_loader:
		var eject_label := _eject_button.get_node_or_null("ButtonLabel") as Label3D
		if eject_label:
			eject_label.text = "OPEN" if _disc_loader == MediaDimensions.LOADER_TRAY else "EJECT"
		if _disc_loader == MediaDimensions.LOADER_TRAY:
			_cartridge_slot.enabled = false   # tray starts closed
		# The dark cartridge-slot puck would swallow a flat disc — hide it on
		# disc hardware; the disc itself (or the tray) is the visual.
		var slot_visual := _cartridge_slot.get_node_or_null("SlotVisual") as MeshInstance3D
		if slot_visual:
			slot_visual.visible = false
		# The snap ghost is cartridge-shaped — reshape it into this system's
		# disc so the blue "goes here" shadow reads correctly.
		var ghost := _cartridge_slot.get_node_or_null("SnapHighlight/HighlightMesh") as MeshInstance3D
		if ghost:
			var ghost_mesh := CylinderMesh.new()
			ghost_mesh.top_radius = MediaDimensions.disc_diameter(systemid) / 2.0
			ghost_mesh.bottom_radius = ghost_mesh.top_radius
			ghost_mesh.height = 0.004
			ghost.mesh = ghost_mesh
		# Tray consoles on the placeholder box get a physical disc well + hinged
		# lid (bespoke GLB models own their tray geometry instead).
		if _disc_loader == MediaDimensions.LOADER_TRAY and systemid not in _MODEL_SCRIPTS:
			_build_disc_tray()
		# Slot loaders take the disc through a slit in the FRONT face: move the
		# snap zone to the slit mouth and add the slit visual there.
		if _disc_loader == MediaDimensions.LOADER_SLOT and systemid not in _MODEL_SCRIPTS:
			_cartridge_slot.position = Vector3(0, 0.03, 0.125)
			_build_disc_slit()
	# Handhelds: built-in screen, on-device controls, and the held-input
	# component that turns the device itself into the port-0 controller.
	if _model.is_handheld():
		_power_button.visible = false
		_power_button.set_deferred("monitoring", false)
		_reset_button.visible = false
		_reset_button.set_deferred("monitoring", false)
		if _model.has_method("configure_handheld_body"):
			_model.configure_handheld_body(self)
		_model.configure_handheld_controls(self)
		_handheld_input = HandheldInput.new()
		_handheld_input.name = "HandheldInput"
		add_child(_handheld_input)
		_handheld_input.setup(self)
		# Route port-0 rumble to the holding hands via the existing path.
		_port_controllers[0] = _handheld_input


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


## The mesh the core should render to right now: a connected TV wins,
## otherwise a handheld's built-in LCD, otherwise null (no display).
func _screen_target() -> MeshInstance3D:
	if connected_tv != null:
		return connected_tv.get_screen_mesh()
	return _model.get_builtin_screen() if _model else null


## Show or hide the screen output (used by TV toggle button).
func set_screen_enabled(enabled: bool) -> void:
	if not is_powered_on:
		return
	_libretro.SetScreenMesh(_screen_target() if enabled else null)


## Called by the TV's cable plug when it connects to a TV
func on_tv_connected(tv: RetroTV) -> void:
	connected_tv = tv
	if is_powered_on:
		_libretro.SetScreenMesh(tv.get_screen_mesh())


## Called by the TV's cable plug when it disconnects. Handhelds take the
## picture back onto their built-in LCD; consoles go dark.
func on_tv_disconnected() -> void:
	connected_tv = null
	if is_powered_on:
		_libretro.SetScreenMesh(_screen_target())


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


func _process(_delta: float) -> void:
	# Tilt-sensor feed (handhelds): the device's physical orientation IS the
	# accelerometer for tilt carts (WarioWare Twisted, Kirby Tilt 'n' Tumble).
	# libretro frame: X = screen-right, Y = screen-top, Z = out of the screen;
	# at rest flat (screen up) = (0,0,1) g. Our shell: screen normal = +Y,
	# screen-top = -Z, screen-right = +X. During netplay the tilt rides the
	# deterministic frame schedule (aux block, supplied by the port-0 owner)
	# instead of feeding the core directly.
	if _model != null and _model.is_handheld() and is_powered_on:
		var a := global_transform.basis.orthonormalized().transposed() * Vector3.UP
		if NetworkManager.netplay_running():
			if NetworkManager.netplay_system() == self:
				NetworkManager.netplay_set_aux_sensor(self,
					int(a.x * 1000.0), int(-a.z * 1000.0), int(a.y * 1000.0))
		else:
			_libretro.SetSensorAccel(0, a.x, -a.z, a.y)
	_update_disc_spin(_delta)


## Spin the seated disc: ramp up while powered with the tray shut, ramp down
## when the tray opens or the power goes off. Purely visual — each peer derives
## the same state from power + tray, so no sync is needed.
func _update_disc_spin(delta: float) -> void:
	var disc := _snapped_cartridge as RetroDisc
	if disc == null or not is_instance_valid(disc):
		_disc_spin = 0.0
		return
	var shut := _disc_loader != MediaDimensions.LOADER_TRAY or not _tray_open
	var target := DISC_SPIN_MAX if (is_powered_on and shut) else 0.0
	var rate := DISC_SPIN_UP if target > _disc_spin else DISC_SPIN_DOWN
	_disc_spin = move_toward(_disc_spin, target, rate * delta)
	# Only rotate while seated (frozen); a disc being grabbed out keeps its pose.
	if _disc_spin > 0.0 and disc.freeze:
		disc.rotate_object_local(Vector3.UP, _disc_spin * delta)


## Touch-screen feed (dual-screen handhelds): uv is a point in the COMPOSITE
## core framebuffer (both screens), 0..1 — the model converts a poke on its
## bottom screen through its UV window. RETRO_DEVICE_POINTER is how melonDS/
## citra take touch input. During netplay the touch rides the deterministic
## frame schedule (aux block, supplied by the port-0 owner).
func feed_touch(uv: Vector2, pressed: bool) -> void:
	if _libretro == null or not is_powered_on:
		return
	var px := int(clampf(uv.x, 0.0, 1.0) * 65534.0) - 32767
	var py := int(clampf(uv.y, 0.0, 1.0) * 65534.0) - 32767
	if NetworkManager.netplay_running():
		if NetworkManager.netplay_system() == self:
			NetworkManager.netplay_set_aux_pointer(self, px, py, pressed)
		return
	_libretro.SetPointerState(0, px, py, pressed)


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
	if _screen_target() == null:
		push_error("RetroSystem: Cannot power on - no display (connect a TV)")
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
	_apply_forced_core_options(resolved_dir, resolved_core)
	_libretro.SetSramPath(_compose_sram_path(resolved_core))
	_libretro.StartContent(_screen_target(), resolved_dir, resolved_core, rom_path)
	var asp := _libretro.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	if asp:
		asp.unit_size        = audio_unit_size
		asp.max_distance     = audio_max_distance
		asp.panning_strength = audio_panning_strength
	is_powered_on = true
	_model.on_power_on()
	# Learn whether this core exposes the disk-control interface (multi-disc
	# swap); the command drains after retro_load_game, so the answer is real.
	_libretro.RequestDiskInfo()


## Power off: stop the running core
func power_off() -> void:
	if not is_powered_on:
		return
	print("[RetroSystem] Powering off")
	# Zero any active rumble on all plugged-in controllers so vibration
	# doesn't leak past core unload if the core was rumbling at shutdown.
	for ctrl in _port_controllers:
		if ctrl and is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
			ctrl.set_rumble(0.0, 0.0)
	_libretro.StopContent()
	is_powered_on = false
	_has_disk_control = false
	_disc_index = 0
	_disc_ejected = false
	_options_panel.hide_panel()
	_model.on_power_off()


## Toggle power (used by the power button)
func toggle_power() -> void:
	if NetworkManager.is_active() and not NetworkManager.is_event_applying():
		# A running lockstep game: power stops it on every peer.
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			NetworkManager.netplay_stop("powered off")
			return
		# Host powering on a determinism-verified core → start lockstep netplay:
		# every peer runs the core locally instead of the host-only placeholder.
		if NetworkManager.is_host() and not is_powered_on and _netplay_eligible():
			if NetworkManager.netplay_start_host(self, _resolve_core(), net_rom_md5()):
				return   # cold start drives net_start_core on every peer
		if NetworkManager.is_client():
			# Non-netplay core: emulation runs on the host only — send the intent.
			NetworkManager.report_event(NetObjectSync.EV_SYS_POWER, {"sys": self})
			return
	if is_powered_on:
		power_off()
	else:
		power_on()
	# Host in a session: tell clients the new state (placeholder screens).
	if NetworkManager.is_active() and NetworkManager.is_host() \
			and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_SYS_POWER_STATE,
			{"sys": self, "on": is_powered_on})


## True if this system can run lockstep netplay right now: a determinism-verified
## core is resolvable and a ROM is inserted.
func _netplay_eligible() -> bool:
	if rom_path.is_empty():
		return false
	return NetworkManager.netplay_capable(_resolve_core())


func _resolve_core() -> String:
	var c := core_name
	if c.is_empty() and not systemid.is_empty():
		var defaults := CoreDefaults.new()
		defaults.setup(CoreDefaults.default_path())
		c = defaults.get_default_core(systemid)
	return c


func _resolve_dir() -> String:
	var dir := core_directory
	if dir.is_empty():
		dir = CoreDownloadManager.default_core_root()
	return dir


## MD5 of the inserted ROM (for netplay peer verification). Empty if none.
## Cached (mtime-keyed) so only the first hash of a given file touches disk.
func net_rom_md5() -> String:
	if rom_path.is_empty():
		return ""
	return NetFileTransfer.hash_of(rom_path)


## Netplay cold start (client): make sure we own a byte-identical copy of the
## host's ROM. Checks the current rom_path first, then searches the local rom
## library by hash. ROMs are VERIFY-ONLY — never transferred (copyright; see
## file_transfer.gd). Returns false when no matching copy exists locally.
func net_resolve_rom(md5: String) -> bool:
	if md5.is_empty():
		return false
	# Refresh from the seated cartridge — object_sync may have remapped it.
	if _snapped_cartridge and _snapped_cartridge.has_method("get_rom_path"):
		var cart_path: String = _snapped_cartridge.get_rom_path()
		if not cart_path.is_empty():
			rom_path = cart_path
	if not rom_path.is_empty() and FileAccess.file_exists(rom_path) \
			and NetFileTransfer.hash_of(rom_path) == md5:
		return true
	var found := NetFileTransfer.resolve_by_md5(md5, "rom", 0, rom_path,
		[RomLibrary.default_roms_root()])
	if found.is_empty():
		push_warning("[RetroSystem] netplay: no local ROM matches md5 %s… — not transferable" % md5.left(8))
		return false
	rom_path = found
	if _snapped_cartridge and "rom_path" in _snapped_cartridge:
		_snapped_cartridge.set("rom_path", found)
	print("[RetroSystem] netplay: rom matched by hash → %s" % found)
	return true


# ── Netplay core seam (driven by NetplaySession on every peer) ────────────────

## Start the local core under the netplay gate. The gate (SetNetplayMode) is set
## BEFORE StartContent so the core holds at `start_frame` until inputs post.
## Returns the Libretro node (the session connects its signals). null on failure.
func net_start_core(port_mask: int, start_frame: int, options: Dictionary) -> Libretro:
	if _screen_target() == null:
		push_error("RetroSystem: netplay start — no display (connect a TV)")
		return null
	if rom_path.is_empty():
		push_error("RetroSystem: netplay start — no cartridge inserted")
		return null
	var resolved_core := _resolve_core()
	if resolved_core.is_empty():
		push_error("RetroSystem: netplay start — no core for systemid '%s'" % systemid)
		return null
	if is_powered_on:
		_libretro.StopContent()
		is_powered_on = false
	for k: Variant in options:
		_libretro.SetCoreOption(str(k), str(options[k]))
	# SRAM: netplay override (session-injected identical bytes) or the normal
	# local composition when the session didn't set one (offline-like start).
	if _net_sram_override:
		_libretro.SetSramPath(_net_sram_path)
		if not _net_sram_data.is_empty():
			_libretro.SetSramData(_net_sram_data)
		_net_sram_override = false
		_net_sram_data = PackedByteArray()
	else:
		_libretro.SetSramPath(_compose_sram_path(resolved_core))
	_apply_forced_core_options(_resolve_dir(), resolved_core)
	_libretro.SetNetplayMode(true, port_mask, start_frame)
	_libretro.StartContent(_screen_target(), _resolve_dir(), resolved_core, rom_path)
	var asp := _libretro.get_node_or_null("AudioStreamPlayer3D") as AudioStreamPlayer3D
	if asp:
		asp.unit_size        = audio_unit_size
		asp.max_distance     = audio_max_distance
		asp.panning_strength = audio_panning_strength
	is_powered_on = true
	net_remote_powered = false
	if connected_tv:
		connected_tv.hide_osd()   # real local output now, not the placeholder
	_model.on_power_on()
	return _libretro


## Stop the local netplay core and clear the gate.
func net_stop_core() -> void:
	for ctrl in _port_controllers:
		if ctrl and is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
			ctrl.set_rumble(0.0, 0.0)
	_libretro.SetNetplayMode(false, 1, 0)
	if is_powered_on:
		_libretro.StopContent()
		is_powered_on = false
		_options_panel.hide_panel()
		_model.on_power_off()


## True on clients while the host runs this system's emulation.
var net_remote_powered := false

## Client-side mirror of the host's power state (pre-netplay placeholder).
func net_set_remote_power(on: bool) -> void:
	net_remote_powered = on
	if connected_tv:
		if on:
			connected_tv.show_osd("LIVE ON HOST")
		else:
			connected_tv.hide_osd()


## Hard reset: restart the running core without going through power on/off.
## Does not change button state, labels, or fire power model hooks.
func reset() -> void:
	if not is_powered_on:
		return
	_model.play_reset()
	var resolved_core := core_name
	if resolved_core.is_empty() and not systemid.is_empty():
		var defaults := CoreDefaults.new()
		defaults.setup(CoreDefaults.default_path())
		resolved_core = defaults.get_default_core(systemid)
	var resolved_dir := core_directory
	if resolved_dir.is_empty():
		resolved_dir = CoreDownloadManager.default_core_root()
	print("[RetroSystem] Resetting: core=%s dir=%s rom=%s" % [resolved_core, resolved_dir, rom_path])
	_apply_forced_core_options(resolved_dir, resolved_core)
	_libretro.StopContent()
	_libretro.StartContent(_screen_target(), resolved_dir, resolved_core, rom_path)


## Merge the model's REQUIRED core options into <dir>/core_options/<core>.opt
## before StartContent — the C++ OptionsHandler reads that file when the core
## boots. (SetCoreOption needs a running core, so pre-start forcing goes
## through the file; user-set values for other keys are preserved.)
func _apply_forced_core_options(dir: String, core: String) -> void:
	if _model == null:
		return
	var forced: Dictionary = _model.get_forced_core_options()
	if forced.is_empty():
		return
	var opt_dir := dir.path_join("core_options")
	var path := opt_dir.path_join(core + ".opt")
	var entries: Dictionary = {}
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			for line: String in f.get_as_text().split("\n"):
				var eq := line.find("=")
				if eq > 0:
					entries[line.substr(0, eq).strip_edges()] = \
						line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	var changed := false
	for k: Variant in forced:
		if entries.get(str(k), null) != str(forced[k]):
			entries[str(k)] = str(forced[k])
			changed = true
	if not changed:
		return
	DirAccess.make_dir_recursive_absolute(opt_dir)
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_warning("RetroSystem: cannot write forced core options to %s" % path)
		return
	for k: String in entries:
		out.store_string("%s = \"%s\"\n" % [k, entries[k]])
	print("[RetroSystem] forced core options applied: %s -> %s" % [str(forced), path])


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
	# Guard: a controller can be plugged in before the core is started (or in a
	# headless probe where the GDExtension isn't loaded). The device selection is
	# re-applied at core start, so skipping here is safe.
	if is_instance_valid(_libretro) and _libretro.has_method("SetControllerPortDevice"):
		_libretro.SetControllerPortDevice(port, device_id)


## Returns the Libretro node so plugged-in controller objects can call input methods on it.
func get_libretro_node() -> Libretro:
	return _libretro


# --- Controller port snap handlers ---

func _on_port_snapped(port_index: int, controller: Node3D) -> void:
	add_collision_exception_with(controller)
	var device_type: int = controller.get("device_type") if "device_type" in controller else 1
	print("[RetroSystem] port %d snapped: device_type=%d" % [port_index, device_type])
	set_controller_port_device(port_index, device_type)
	# The snapped node is a ControllerPlug (cable end). Unwrap to the actual
	# RetroController so rumble can be routed to its set_rumble() method.
	_port_controllers[port_index] = controller.get_controller() \
		if controller.has_method("get_controller") else controller
	if controller.has_method("on_plugged_in"):
		controller.on_plugged_in(self, port_index)
	NetworkManager.report_event(NetObjectSync.EV_PORT_PLUG,
		{"sys": self, "ctrl": _port_controllers[port_index], "port": port_index})


func _on_port_released(port_index: int, controller: Node3D) -> void:
	print("[RetroSystem] port %d released" % port_index)
	# Stop any active rumble on the controller being unplugged. The snapped
	# node is a ControllerPlug, so unwrap to the real RetroController first.
	var actual_ctrl: Node3D = controller.get_controller() \
		if is_instance_valid(controller) and controller.has_method("get_controller") \
		else controller
	if is_instance_valid(actual_ctrl) and actual_ctrl.has_method("set_rumble"):
		actual_ctrl.set_rumble(0.0, 0.0)
	if is_instance_valid(controller):
		remove_collision_exception_with(controller)
	_port_controllers[port_index] = null
	set_controller_port_device(port_index, 0)  # RETRO_DEVICE_NONE
	if is_instance_valid(controller) and controller.has_method("on_unplugged"):
		controller.on_unplugged()
	NetworkManager.report_event(NetObjectSync.EV_PORT_UNPLUG,
		{"sys": self, "port": port_index})


## Attach a controller (by its cable plug) to an EXPANDED libretro port that has
## no cabinet snap zone — used by a multitap plugged into a native port to fan
## out to consecutive ports. Mirrors _on_port_snapped without a snap zone.
## Rumble routing is registered only for ports within _port_controllers; input
## and device selection work for any port the core supports.
func attach_expanded_controller(port: int, plug: Node3D) -> void:
	if port < 0 or not is_instance_valid(plug):
		return
	var dev: int = plug.get("device_type") if "device_type" in plug else 1
	set_controller_port_device(port, dev)
	var ctrl: Node3D = plug.get_controller() if plug.has_method("get_controller") else plug
	if port < _port_controllers.size():
		_port_controllers[port] = ctrl
	if plug.has_method("on_plugged_in"):
		plug.on_plugged_in(self, port)
	NetworkManager.report_event(NetObjectSync.EV_PORT_PLUG,
		{"sys": self, "ctrl": ctrl, "port": port})


## Detach a controller from an expanded port (see attach_expanded_controller).
func detach_expanded_controller(port: int, plug: Node3D) -> void:
	if port < 0:
		return
	var actual: Node3D = plug.get_controller() \
		if is_instance_valid(plug) and plug.has_method("get_controller") else plug
	if is_instance_valid(actual) and actual.has_method("set_rumble"):
		actual.set_rumble(0.0, 0.0)
	if port < _port_controllers.size():
		_port_controllers[port] = null
	set_controller_port_device(port, 0)  # RETRO_DEVICE_NONE
	if is_instance_valid(plug) and plug.has_method("on_unplugged"):
		plug.on_unplugged()
	NetworkManager.report_event(NetObjectSync.EV_PORT_UNPLUG, {"sys": self, "port": port})


## Route a rumble request from the core to the RetroController currently
## plugged into the matching cabinet port.
func _on_rumble_state_changed(port: int, weak: float, strong: float) -> void:
	if port < 0 or port >= _port_controllers.size():
		return
	var ctrl = _port_controllers[port]
	if ctrl and is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
		ctrl.set_rumble(weak, strong)


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


## Restore a controller plug into a port after loading from a save file.
func restore_controller_plug(port_index: int, plug: ControllerPlug) -> void:
	if port_index < 0 or port_index >= _port_zones.size():
		return
	_port_zones[port_index].pick_up_object(plug)


func _on_cartridge_inserted(cartridge: Node3D) -> void:
	_snapped_cartridge = cartridge
	# Prevent the frozen kinematic cartridge from physically pushing the system body
	add_collision_exception_with(cartridge)
	if cartridge.has_method("get_rom_path"):
		rom_path = cartridge.get_rom_path()
	# Back-fill the cartridge's systemid (save-recovery list needs it to
	# resolve the core) — a cart inserted into an NES is an NES cart.
	if "systemid" in cartridge and str(cartridge.get("systemid")).is_empty():
		cartridge.set("systemid", systemid)
	_model.play_cartridge_insert(cartridge, _cartridge_slot)
	if cartridge is RetroDisc:
		if _disc_loader == MediaDimensions.LOADER_SLOT:
			_play_slot_insert(cartridge)
		elif _disc_loader == MediaDimensions.LOADER_TRAY and not _tray_open:
			# Restored/replicated insert with the lid shut — seal it inside.
			cartridge.set("enabled", false)
	# Hot swap: a powered disc console with its virtual tray open takes the new
	# disc without a reboot (multi-disc games — FF7 "insert disc 2").
	if is_powered_on and _has_disk_control and _disc_ejected \
			and not rom_path.is_empty() and not NetworkManager.is_event_applying():
		# _disc_index is the core's internal image-list SLOT (get_image_index),
		# not a disc number — without .m3u the list has one slot (0) and the
		# swap overwrites the file in it (replace_image_index).
		print("[RetroSystem] Hot swap: image slot %d -> %s" % [_disc_index, rom_path])
		_request_disk_op(1, rom_path)
	NetworkManager.report_event(NetObjectSync.EV_CART_INSERT,
		{"sys": self, "cart": cartridge})


func _on_cartridge_removed() -> void:
	if _snapped_cartridge:
		_model.play_cartridge_eject(_snapped_cartridge, _cartridge_slot)
		remove_collision_exception_with(_snapped_cartridge)
		_snapped_cartridge = null
	_disc_spin = 0.0
	_slot_ejecting = false
	if is_powered_on and _has_disk_control:
		# Hot eject: open the core's virtual tray — the game keeps running and
		# waits for the next disc. rom_path stays mounted (the disc image is
		# still what the core is running).
		print("[RetroSystem] Hot eject: game keeps running, waiting for next disc (%s)" % rom_path)
		if not NetworkManager.is_event_applying():
			_request_disk_op(0, "")
		NetworkManager.report_event(NetObjectSync.EV_CART_REMOVE, {"sys": self})
		return
	if is_powered_on:
		power_off()
	rom_path = ""
	NetworkManager.report_event(NetObjectSync.EV_CART_REMOVE, {"sys": self})


## Cached disk-control state from the emulation thread (async signal).
func _on_disk_control_ready(has_control: bool, count: int, current_index: int,
		ejected: bool) -> void:
	# Log state changes (not every echo) — the boot answer and each op's result.
	if has_control != _has_disk_control or current_index != _disc_index \
			or ejected != _disc_ejected:
		print("[RetroSystem] Disk control: has=%s images=%d index=%d ejected=%s" %
			[has_control, count, current_index, ejected])
	_has_disk_control = has_control
	_disc_index = current_index
	_disc_ejected = ejected


## Perform a disc op — op 0 = eject (open the core's tray), op 1 = replace the
## current image with `path` and close the tray. Offline: straight to the core.
## Netplay: frame-scheduled so every lockstep peer swaps on the same frame
## (host schedules; clients send intent via EV_DISK_OP).
func _request_disk_op(op: int, path: String) -> void:
	if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
		var md5 := "" if path.is_empty() else NetFileTransfer.hash_of(path)
		if NetworkManager.is_host():
			NetworkManager.netplay_schedule_disk(self, op, md5, _disc_index)
		else:
			print("[RetroSystem] Disc op %d intent -> host (md5 %s…)" % [op, md5.left(8)])
			NetworkManager.report_event(NetObjectSync.EV_DISK_OP,
				{"sys": self, "op": op, "md5": md5, "index": _disc_index})
		# The core-side state flips on the scheduled frame; the mirror updates
		# via disk_control_ready then.
		return
	if op == 0:
		_libretro.SetDiskEjectState(true)
		_disc_ejected = true
	else:
		_libretro.ReplaceDiskImage(_disc_index, path)
		_libretro.SetDiskEjectState(false)
		_disc_ejected = false


# --- Disc loader (tray lid / slot loading) ---

## OPEN (tray consoles): toggles the lid, gating insert/remove and the spin.
## EJECT (slot consoles): slides the seated disc out so it can be grabbed.
func _on_eject_pressed() -> void:
	match _disc_loader:
		MediaDimensions.LOADER_TRAY:
			_request_tray_state(not _tray_open)
		MediaDimensions.LOADER_SLOT:
			_slot_eject()


## Local intent (OPEN button or pushing the lid shut): apply + replicate.
func _request_tray_state(open: bool) -> void:
	_set_tray_open(open)
	NetworkManager.report_event(NetObjectSync.EV_TRAY,
		{"sys": self, "open": _tray_open})


## Apply a tray state: the snap zone only hover-accepts discs while open, and a
## seated disc can only be grabbed out while open (no reaching through the lid).
## The spin ramp follows via _update_disc_spin. Netplay applies remote toggles
## through net_set_tray_open below.
func _set_tray_open(open: bool) -> void:
	_tray_open = open
	_cartridge_slot.enabled = open
	_eject_button.set_latched_pressed(open)
	if open:
		_model.play_open()
	else:
		_model.play_close()
	# Swing the procedural lid on its hinge (default-model tray consoles).
	if _tray_lid_pivot:
		if _tray_tween:
			_tray_tween.kill()
		_tray_tween = create_tween()
		_tray_tween.tween_property(_tray_lid_pivot, "rotation_degrees:x",
			TRAY_LID_OPEN_DEG if open else 0.0, 0.4) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _snapped_cartridge is RetroDisc:
		_snapped_cartridge.set("enabled", open)


## Build the physical disc well + hinged lid on the placeholder box body:
## a raised pod bridging the box top (y=0.05) up to the seated-disc height
## (y=0.07), a dark recessed bed the disc rests in, and a lid hinged at the
## pod's back edge. The lid doubles as a touch button — physically pushing an
## open lid shuts it (same replicated path as the OPEN button).
func _build_disc_tray() -> void:
	var d := MediaDimensions.disc_diameter(systemid)
	var pod_r := d / 2.0 + 0.024
	var lid_r := d / 2.0 + 0.028
	var hinge_z := -(d / 2.0 + 0.03)

	var pod_mat := StandardMaterial3D.new()
	pod_mat.albedo_color = Color(0.45, 0.45, 0.48)
	var bed_mat := StandardMaterial3D.new()
	bed_mat.albedo_color = Color(0.10, 0.10, 0.12)
	var lid_mat := StandardMaterial3D.new()
	lid_mat.albedo_color = Color(0.55, 0.55, 0.58)

	# Raised pod (disc sits on its recessed top).
	var pod := MeshInstance3D.new()
	pod.name = "DiscTrayPod"
	var pod_mesh := CylinderMesh.new()
	pod_mesh.top_radius = pod_r
	pod_mesh.bottom_radius = pod_r
	pod_mesh.height = 0.0167
	pod.mesh = pod_mesh
	pod.set_surface_override_material(0, pod_mat)
	pod.position = Vector3(0, 0.05 + 0.0167 / 2.0, 0)   # top at 0.0667
	add_child(pod)

	# Dark bed the disc rests in (just under the seated disc's underside).
	var bed := MeshInstance3D.new()
	bed.name = "DiscTrayBed"
	var bed_mesh := CylinderMesh.new()
	bed_mesh.top_radius = d / 2.0 + 0.006
	bed_mesh.bottom_radius = d / 2.0 + 0.006
	bed_mesh.height = 0.002
	bed.mesh = bed_mesh
	bed.set_surface_override_material(0, bed_mat)
	bed.position = Vector3(0, 0.0677, 0)   # top at 0.0687, disc bottom 0.06875
	add_child(bed)

	# Hinged lid: pivot at the pod's back edge, lid disc swings up/back.
	_tray_lid_pivot = Node3D.new()
	_tray_lid_pivot.name = "DiscTrayLidPivot"
	_tray_lid_pivot.position = Vector3(0, 0.076, hinge_z)
	add_child(_tray_lid_pivot)

	var lid_btn := VRButton.new()
	lid_btn.name = "DiscTrayLid"
	lid_btn.position = Vector3(0, 0, -hinge_z)   # lid centre, forward of hinge
	lid_btn.trigger_radius = lid_r + 0.01
	lid_btn.depress_depth = 0.002
	var lid_col := CollisionShape3D.new()
	var lid_col_shape := CylinderShape3D.new()
	lid_col_shape.radius = lid_r
	lid_col_shape.height = 0.02
	lid_col.shape = lid_col_shape
	lid_btn.add_child(lid_col)
	var lid_mesh_inst := MeshInstance3D.new()
	lid_mesh_inst.name = "ButtonMesh"   # VRButton drives this mesh
	var lid_mesh := CylinderMesh.new()
	lid_mesh.top_radius = lid_r
	lid_mesh.bottom_radius = lid_r
	lid_mesh.height = 0.005
	lid_mesh_inst.mesh = lid_mesh
	lid_mesh_inst.set_surface_override_material(0, lid_mat)
	lid_btn.add_child(lid_mesh_inst)
	_tray_lid_pivot.add_child(lid_btn)
	lid_btn.button_pressed.connect(_on_lid_pressed)


## Physically pushing (or pointer-clicking) the lid while open shuts the tray.
func _on_lid_pressed() -> void:
	if _disc_loader == MediaDimensions.LOADER_TRAY and _tray_open:
		_request_tray_state(false)


## Netplay: another player toggled this console's tray.
func net_set_tray_open(open: bool) -> void:
	if _disc_loader == MediaDimensions.LOADER_TRAY and open != _tray_open:
		_set_tray_open(open)


## Dark slit on the front face where slot-loaded discs go in.
func _build_disc_slit() -> void:
	var d := MediaDimensions.disc_diameter(systemid)
	var slit := MeshInstance3D.new()
	slit.name = "DiscSlit"
	var slit_mesh := BoxMesh.new()
	slit_mesh.size = Vector3(d + 0.008, 0.007, 0.003)
	slit.mesh = slit_mesh
	var slit_mat := StandardMaterial3D.new()
	slit_mat.albedo_color = Color(0.08, 0.08, 0.1)
	slit.set_surface_override_material(0, slit_mat)
	slit.position = Vector3(0, 0.03, 0.1255)
	add_child(slit)


## Slot loader: animate the disc riding the mechanism INTO the console, then
## lock it so it can't be grabbed through the case (EJECT is the way out).
## The snap seats the disc half-swallowed at the slit mouth, which pops badly —
## restart the ride from fully OUTSIDE the face (edge kissing the slit) so the
## whole disc visibly feeds through the opening.
func _play_slot_insert(disc: Node3D) -> void:
	var slot_pos := _cartridge_slot.global_position
	var into := -_cartridge_slot.global_transform.basis.z
	var start := slot_pos - into * (MediaDimensions.disc_diameter(systemid) / 2.0 + 0.01)
	# Stay FROZEN for the whole ride: an unfrozen body sags under gravity while
	# the tween drives it (the disc visibly dipped below the slit). Frozen
	# kinematic bodies accept position writes fine (same as eject + spin).
	if disc is RigidBody3D:
		(disc as RigidBody3D).freeze = true
	disc.global_position = start
	# The snap driver writes the zone pose once on the frame after pick-up —
	# cover it with a deferred re-set, and interpolate with an EXPLICIT
	# from->to (tween_property would capture the stomped position as its start).
	disc.set_deferred("global_position", start)
	var tween := disc.create_tween()
	tween.tween_method(_set_ride_pos.bind(disc), start,
		slot_pos + into * SLOT_INSET, 1.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		disc.set("enabled", false))


## tween_method target for the slot ride (explicit from->to interpolation).
func _set_ride_pos(p: Vector3, disc: Node3D) -> void:
	if is_instance_valid(disc):
		disc.global_position = p


## Slot loader: slide the seated disc out of the slot, then release it from the
## snap zone so it can be grabbed (the removal handler powers off as usual).
func _slot_eject() -> void:
	var disc := _snapped_cartridge
	if disc == null or not is_instance_valid(disc) or _slot_ejecting:
		return
	_slot_ejecting = true
	_disc_spin = 0.0
	# Ride the mechanism back out: from inside the console to poking out of
	# the front slit, where it can be grabbed.
	var out_pos: Vector3 = _cartridge_slot.global_position \
		+ _cartridge_slot.global_transform.basis.z * SLOT_PROTRUDE
	var tween := disc.create_tween()
	tween.tween_property(disc, "global_position", out_pos, 1.0) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		_slot_ejecting = false
		# The released disc still overlaps the zone's grab sphere and the zone
		# re-stashes anything dropped inside it — disarm it around the release,
		# then leave the disc frozen protruding from the slit (held by the
		# mechanism, not falling) until someone takes it.
		_cartridge_slot.enabled = false
		_cartridge_slot.drop_object()
		if is_instance_valid(disc) and disc is RigidBody3D:
			(disc as RigidBody3D).freeze = true
			(disc as RigidBody3D).global_position = out_pos
		disc.set("enabled", true)
		get_tree().create_timer(0.25).timeout.connect(func() -> void:
			if _disc_loader == MediaDimensions.LOADER_SLOT:
				_cartridge_slot.enabled = true))


# --- Memory card slot (CD-era consoles) ---

## The MemoryCard currently seated, or null.
var _snapped_memcard: Node3D = null

# Netplay SRAM override (set by NetplaySession before net_start_core):
# path "" on clients (no local persistence of someone else's game) and the
# host's real bytes injected on every peer so all cores boot identically.
var _net_sram_override := false
var _net_sram_path := ""
var _net_sram_data := PackedByteArray()


func get_snapped_memcard() -> Node3D:
	return _snapped_memcard


func _on_memcard_inserted(card: Node3D) -> void:
	_snapped_memcard = card
	add_collision_exception_with(card)
	if is_powered_on:
		# Hot-swap: the C++ side flushes the old card and loads this one —
		# except mid-netplay, where SRAM is part of the deterministic state.
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			push_warning("[RetroSystem] memory card ignored during netplay")
		else:
			_libretro.SetSramPath(_compose_sram_path(_resolve_core()))
	NetworkManager.report_event(NetObjectSync.EV_MEMCARD_INSERT,
		{"sys": self, "card": card})


func _on_memcard_removed() -> void:
	if _snapped_memcard:
		remove_collision_exception_with(_snapped_memcard)
		_snapped_memcard = null
	if is_powered_on:
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			push_warning("[RetroSystem] memory card removal ignored during netplay")
		else:
			_libretro.SetSramPath("")   # authentic: no card, no saving
	NetworkManager.report_event(NetObjectSync.EV_MEMCARD_REMOVE, {"sys": self})


## Restore a memory card into the slot after loading from a save file.
func restore_memory_card(card: Node3D) -> void:
	_memcard_slot.pick_up_object(card)


# --- Battery saves (SRAM) ---

## Where this run's .srm lives. Card systems: the seated card's folder, or ""
## (no card = authentic no-persistence). Cartridge systems: the cartridge's
## own save_id file — each physical cart holds its own save.
func _compose_sram_path(resolved_core: String) -> String:
	if resolved_core.is_empty() or rom_path.is_empty():
		return ""
	if _model.uses_memory_cards():
		if _snapped_memcard and "card_id" in _snapped_memcard:
			return SramPaths.card_save_path(resolved_core, rom_path,
				str(_snapped_memcard.get("card_id")))
		return ""
	if _snapped_cartridge and "save_id" in _snapped_cartridge:
		return SramPaths.cart_save_path(resolved_core, rom_path,
			str(_snapped_cartridge.get("save_id")))
	return ""


## Netplay: override the SRAM source for the next net_start_core (see
## NetplaySession). path "" disables local persistence; data (may be empty)
## is injected so every peer boots with identical SRAM.
func net_set_sram(path: String, data: PackedByteArray) -> void:
	_net_sram_override = true
	_net_sram_path = path
	_net_sram_data = data


## Host: the current .srm file bytes for the seated content (shipped to peers
## in the netplay cold-start payload). Empty when no file exists yet.
func net_sram_file_bytes() -> PackedByteArray:
	var path := _compose_sram_path(_resolve_core())
	if path.is_empty() or not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(f.get_length()) if f else PackedByteArray()
