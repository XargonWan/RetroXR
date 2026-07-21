## RetroSystem — pickable retro console that loads a libretro core and renders to a connected TV.
class_name RetroSystem
extends XRToolsPickable


## Maps systemid → GDScript path for the hardware model subclass. Used for
## systems whose model is NOT an authored scene (see _MODEL_SCENES).
const _MODEL_SCRIPTS: Dictionary = {
	# Disabled for now — the N64 / PlayStation (and NES) console models are
	# imported-derived and replicate real hardware trade dress, an IP risk for
	# store distribution (e.g. SideQuest). These systems fall back to the
	# procedural default_model. To re-enable: restore the entry AND drop
	# "imported-assets/*" from the export preset's exclude_filter.
	#"nintendo_64": "res://Scripts/Objects/system_models/n64_model.gd",
	#"playstation": "res://Scripts/Objects/system_models/playstation_model.gd",
	# Re-enabled dev-only (per user direction): an author's imported PSone. Its GLB is
	# export-excluded (imported-assets/*), and the model self-guards to re-show the
	# placeholder box on any build that lacks the GLB. Licence still pending.
	"playstation": "res://Scripts/Objects/system_models/playstation_one_model.gd",
	"sega_saturn": "res://Scripts/Objects/system_models/sega_saturn_model.gd",
	"dreamcast": "res://Scripts/Objects/system_models/dreamcast_model.gd",
	"nintendo_64": "res://Scripts/Objects/system_models/n64_model.gd",
	"mega_drive": "res://Scripts/Objects/system_models/genesis_model.gd",
	"playstation2": "res://Scripts/Objects/system_models/ps2_model.gd",
}

## Maps systemid → authored model .tscn. The handheld shells (body, screen,
## bezel, cosmetics, on-device controls) live in editable scenes; the scene's
## root node still carries the RetroSystemModel* script that wires behaviour.
## Scenes win over _MODEL_SCRIPTS when both exist. To add or restyle a handheld,
## edit its .tscn — no procedural geometry code involved.
const _MODEL_SCENES: Dictionary = {
	"game_boy": "res://Scenes/Objects/system_models/game_boy.tscn",
	"game_boy_advance": "res://Scenes/Objects/system_models/game_boy_advance.tscn",
	"atari_lynx": "res://Scenes/Objects/system_models/atari_lynx.tscn",
	"wonderswan": "res://Scenes/Objects/system_models/wonderswan.tscn",
	"neo_geo_pocket": "res://Scenes/Objects/system_models/neo_geo_pocket.tscn",
	"pokemon_mini": "res://Scenes/Objects/system_models/pokemon_mini.tscn",
	"supervision": "res://Scenes/Objects/system_models/supervision.tscn",
	"playstation_portable": "res://Scenes/Objects/system_models/psp.tscn",
	"nds": "res://Scenes/Objects/system_models/nds.tscn",
	"3ds": "res://Scenes/Objects/system_models/n3ds.tscn",
	"virtual_boy": "res://Scenes/Objects/system_models/virtual_boy.tscn",
}

## Optional per-variant model overrides, keyed "<systemid>:<variant>".
## Empty for now — the framework is in place so a new model variant is added by
## dropping a "<systemid>:<variant>" → script entry here (plus a SpawnCatalog item).
const _MODEL_VARIANTS: Dictionary = {}

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

## Selects an alternate hardware model for this system (see _MODEL_VARIANTS and
## SpawnCatalog). "" = the system's default model — today's behavior.
@export var model_variant: String = ""

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

## Video-out cables shown/usable. Handhelds default OFF (they have their own
## screen — the cables are clutter until wanted); consoles default ON (a TV is
## their only display). Toggled from the options panel's System tab.
var video_out_enabled: bool = true
# Saved value restored by persistence (set before _ready; -1 = no override).
var _video_out_from_save: int = -1
# Clamshell (DS/3DS) lid open angle restored by persistence (deg, 0 shut … 180
# flat; set before _ready; -1 = keep the model default).
var _lid_angle_from_save: float = -1.0

## Ignore gravity: the system freezes exactly where it's dropped and floats
## there. Toggled from the options panel's System tab; default off.
var ignore_gravity: bool = false

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
# Window material for TVs on multi-output hardware (dual-screen handhelds).
const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

# Video-out channels from the model (single unlabelled entry on classic
# hardware; TOP/BOTTOM on dual-screen handhelds). One cable per channel; all
# per-channel arrays below share this indexing. connected_tv stays the
# channel-0 TV for external readers (persistence, netplay OSD).
var _channels: Array = []
var _cable_instances: Array = []
var _cable_plugs: Array = []
var _cable_ropes: Array = []
var _attach_points: Array = []
var _max_rope_lengths: Array = []
var _channel_tvs: Array = []
# TVs to connect to after the cables finish spawning (save/load restore)
var _pending_tv_restores: Array = []
# screen_window ShaderMaterials mirrored onto connected TVs (multi-out only)
var _tv_window_mats: Array = []
# TVTouchSurface on the TV showing a touch channel (multi-out only)
var _tv_touch_surfaces: Array = []
var _snapped_cartridge: Node3D = null

# --- Disc loader (tray/slot) state ---
const DISC_SPIN_MAX := 25.0    # rad/s (~240 RPM) — seated disc at full speed
const DISC_SPIN_UP := 18.0     # rad/s² ramp-up (power on / tray closed)
const DISC_SPIN_DOWN := 10.0   # rad/s² ramp-down (power off / tray opened)
const TRAY_LID_OPEN_DEG := -75.0   # lid hinge angle when the tray is open
const SLOT_INSET := 0.10       # slot-load: how far inside the console a disc rides

# How this system loads discs (MediaDimensions.LOADER_*), cached at model load.
var _disc_loader := MediaDimensions.LOADER_NONE
var _tray_open := false        # LOADER_TRAY: lid state (starts closed)
var _disc_spin := 0.0          # current disc angular speed (rad/s)
# LOADER_SLOT front-loading bay (insert ride / eject / grab hand-off / collision),
# owned by the shared MediaSlot; created in _load_system_model for slot consoles.
# Null for cartridge / tray / no-disc systems. See media_slot.gd.
var _slot: MediaSlot = null
# LOADER_TRAY lid bay (well seating / lid gating / disc spin / grab hand-off /
# collision), owned by the shared MediaTray; created in _load_system_model for tray
# consoles. Null for cartridge / slot / no-disc systems. See media_tray.gd.
var _tray: MediaTray = null
# Procedural disc well + hinged lid (default-model tray consoles only); the lid
# pivot is handed to _tray so MediaTray animates it.
var _tray_lid_pivot: Node3D = null

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


## Real-world cross-compatibility: media of these systemids also fits.
## (The GBA plays original Game Boy carts — and mgba runs them.)
const _MEDIA_COMPAT: Dictionary = {
	"game_boy_advance": ["game_boy"],
}

# RETRO_DEVICE_* types relevant to port routing (libretro.h).
const RETRO_DEVICE_NONE := 0
const RETRO_DEVICE_MOUSE := 2
const RETRO_DEVICE_KEYBOARD := 3


func _ready() -> void:
	super._ready()
	add_to_group("retro_system")
	_cartridge_slot.has_picked_up.connect(_on_cartridge_inserted)
	_cartridge_slot.has_dropped.connect(_on_cartridge_removed)
	# Only this system's own media fits its slot (a GB cart won't go into a
	# SNES, a PS1 disc only fits a PlayStation). Unlabelled legacy media keeps
	# working everywhere; save/netplay restores bypass the filter.
	_cartridge_slot.snap_filter = _accepts_media
	# Ignore-gravity: re-freeze wherever the player lets go.
	dropped.connect(_on_system_dropped)
	if ignore_gravity:   # restored from a save — float at the saved pose
		_freeze_in_place.call_deferred()
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
	# Spawn one cable per video-out channel
	_spawn_cables()
	_update_name_label()
	# Lay the name flat on the model's front face once meshes + text are built.
	_place_name_label.call_deferred()


## The power button always reflects run state: green START when off, red STOP
## while running. Owned here (not per-model) so bespoke models that override
## on_power_on/off for their own visuals — the Virtual Boy's eyepiece shader —
## can't lose the label toggle. Harmless no-op for handhelds (button hidden).
func _update_power_button_visual() -> void:
	if _power_button == null:
		return
	_power_button.set_color(Color(1.0, 0.0, 0.0) if is_powered_on else Color(0.0, 1.0, 0.0))
	var lbl := _power_button.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.text = "STOP" if is_powered_on else "START"


func _update_name_label() -> void:
	var display_name := system_label
	if display_name.is_empty() and not systemid.is_empty():
		var db := CoreInfoDatabase.new()
		db.load_from_project()
		display_name = db.get_systemname_for_id(systemid)
	if display_name.is_empty():
		display_name = systemid
	_system_name_label.text = display_name.to_upper()


## Lay the system name flat on the front face of the model, sized to fit, facing
## one fixed direction (no billboard) — consoles use their +Z face (upright,
## toward the player), handhelds their +Y top face (readable from above). Runs
## deferred so the model meshes + the label's own text mesh have been built.
func _place_name_label() -> void:
	var body := _body_aabb()
	if body.size.x <= 0.0 or body.size.y <= 0.0 or body.size.z <= 0.0:
		return
	var lbl := _system_name_label
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.scale = Vector3.ONE
	lbl.rotation = Vector3.ZERO
	var la := lbl.get_aabb()
	if la.size.x <= 0.0 or la.size.y <= 0.0:
		return
	var cx := body.position.x + body.size.x * 0.5
	const EPS := 0.003
	# Placement config, overridable per-model via name_label_placement():
	#   upright  — true = upright on the vertical +Z front face (consoles, and
	#              clamshells whose front is the START-button face); false = flat
	#              on the +Y top face (simple flat handhelds like the Game Boy).
	#   v_center — vertical centre as a fraction of the face height.
	#   h_frac   — label height as a fraction of the face height.
	var cfg := {}
	if _model != null and _model.has_method("name_label_placement"):
		cfg = _model.name_label_placement()
	var upright: bool = cfg.get("upright", not (_model != null and _model.is_handheld()))
	if upright:
		# Vertical front (+Z) face, upright toward the player. Default sits low
		# as a nameplate strip so it clears the controller ports that occupy the
		# centre of a default console's front face; thin faces (a clamshell base)
		# override to centre + fill.
		var v_center: float = cfg.get("v_center", 0.18)
		var h_frac: float = cfg.get("h_frac", 0.26)
		var s: float = min(body.size.x * 0.85 / la.size.x, body.size.y * h_frac / la.size.y)
		lbl.scale = Vector3(s, s, s)
		var cy := body.position.y + body.size.y * v_center
		var front_z := body.position.z + body.size.z
		lbl.position = Vector3(cx, cy, front_z + EPS)
	else:
		# Top (+Y) face, lying flat; sit on the front (+Z) strip below the screen.
		lbl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		var s: float = min(body.size.x * 0.8 / la.size.x, body.size.z * 0.28 / la.size.y)
		lbl.scale = Vector3(s, s, s)
		var top_y := body.position.y + body.size.y
		var front_z := body.position.z + body.size.z
		lbl.position = Vector3(cx, top_y + EPS, front_z - la.size.y * s * 0.6)


## AABB of the console/handheld body meshes in this system's local space
## (default box or the bespoke model's meshes). Excludes buttons/ports/cables/
## label, which are siblings of the body root. A model may narrow the measured
## body via name_label_body() — e.g. a clamshell returns just its base so the
## name lands on the base's front, not over the raised lid.
func _body_aabb() -> AABB:
	var meshes: Array[MeshInstance3D] = []
	var src: Node = null
	if _model != null and _model.has_method("name_label_body"):
		src = _model.name_label_body()
	if src != null:
		_collect_meshes(src, meshes)
	else:
		if _system_body.visible:
			meshes.append(_system_body)
		if _model != null:
			_collect_meshes(_model, meshes)
	var inv := global_transform.affine_inverse()
	var out := AABB()
	var have := false
	for mi in meshes:
		if not mi.visible or mi.mesh == null:
			continue
		var a := (inv * mi.global_transform) * mi.get_aabb()
		if not have:
			out = a
			have = true
		else:
			out = out.merge(a)
	return out if have else AABB()


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)


func _load_system_model() -> void:
	const DEFAULT := "res://Scripts/Objects/system_models/default_model.gd"
	# Prefer a variant-specific model, then the system's default model, then the
	# generic placeholder. With model_variant=="" this collapses to the old
	# _MODEL_SCRIPTS.get(systemid, DEFAULT) and is_bespoke == (systemid in _MODEL_SCRIPTS).
	var vkey := "%s:%s" % [systemid, model_variant]
	var is_bespoke := false
	# Authored .tscn model (handhelds): instantiate the editable scene. Its root
	# carries the RetroSystemModel* script, so every configure_* call below is
	# unchanged. A per-variant script override (rare) still wins over the scene.
	if _MODEL_SCENES.has(systemid) and not _MODEL_VARIANTS.has(vkey):
		var packed := load(_MODEL_SCENES[systemid]) as PackedScene
		if not packed:
			push_warning("RetroSystem: failed to load model scene: %s" % _MODEL_SCENES[systemid])
			return
		_model = packed.instantiate() as RetroSystemModel
		is_bespoke = true
	else:
		var script_path: String = DEFAULT
		if not model_variant.is_empty() and _MODEL_VARIANTS.has(vkey):
			script_path = _MODEL_VARIANTS[vkey]
		elif _MODEL_SCRIPTS.has(systemid):
			script_path = _MODEL_SCRIPTS[systemid]
		is_bespoke = script_path != DEFAULT
		var script := load(script_path) as GDScript
		if not script:
			push_warning("RetroSystem: failed to load model script: %s" % script_path)
			return
		_model = script.new() as RetroSystemModel
	add_child(_model)
	if is_bespoke:
		_system_body.hide()
	_model.configure_buttons(_power_button, _reset_button, _eject_button)
	_model.configure_controller_ports(_port_zones)
	# Video-out channels: one attach point + cable per channel. Channel 0 is
	# the scene's CableAttachPoint; extra channels get their own Node3D.
	_channels = _model.get_video_channels()
	if _channels.is_empty():
		_channels = [{"label": "", "rect": Rect2(0, 0, 1, 1), "touch": false, "eye_shift": 0.0}]
	_attach_points = [_cable_attach_point]
	for i in range(1, _channels.size()):
		var pt := Node3D.new()
		pt.name = "CableAttachPoint%d" % (i + 1)
		add_child(pt)
		_attach_points.append(pt)
	for i in _channels.size():
		_cable_instances.append(null)
		_cable_plugs.append(null)
		_cable_ropes.append(null)
		_max_rope_lengths.append(0.0)
		_channel_tvs.append(null)
		_pending_tv_restores.append(null)
		_tv_window_mats.append(null)
		_tv_touch_surfaces.append(null)
		_model.configure_cable_attach_for(_attach_points[i], i)
	# Consoles ALWAYS have video out (a TV is their only display — no toggle);
	# handhelds default OFF and remember the saved choice.
	if _model.is_handheld():
		video_out_enabled = _video_out_from_save == 1
	else:
		video_out_enabled = true
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
		# The cartridge recess would look wrong on disc hardware — the disc
		# tray/slit is the visual instead.
		var cart_recess := _system_body.get_node_or_null("CartSlotMouth") as MeshInstance3D
		if cart_recess:
			cart_recess.visible = false
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
		if _disc_loader == MediaDimensions.LOADER_TRAY and not is_bespoke:
			_build_disc_tray()
		# Lid tray: hand the well seating / lid gating / spin / grab / collision to the
		# shared MediaTray (bespoke models animate their own lid via play_open/close;
		# a procedural lid pivot, if any, is animated by MediaTray). The zone's raw
		# insert/remove signals are replaced by MediaTray's, which fire the same
		# _on_cartridge_inserted/_removed for the emulation-side work.
		if _disc_loader == MediaDimensions.LOADER_TRAY:
			_cartridge_slot.has_picked_up.disconnect(_on_cartridge_inserted)
			_cartridge_slot.has_dropped.disconnect(_on_cartridge_removed)
			_tray = MediaTray.new()
			_tray.host = self
			_tray.slot = _cartridge_slot
			_tray.lid_pivot = _tray_lid_pivot          # null for bespoke models
			_tray.lid_open_deg = TRAY_LID_OPEN_DEG
			add_child(_tray)
			_tray.loaded.connect(_on_cartridge_inserted)
			_tray.unloaded.connect(_on_cartridge_removed)
		# Slot loaders take the disc through a slit in the FRONT face: move the
		# snap zone to the slit mouth and add the slit visual there.
		if _disc_loader == MediaDimensions.LOADER_SLOT and not is_bespoke:
			_cartridge_slot.position = Vector3(0, 0.03, 0.125)
			_build_disc_slit()
		# Front-loading disc bay: hand the physical ride/eject/grab/collision to the
		# shared MediaSlot (bespoke models place their own slit but still slot-load).
		# The zone's raw insert/remove signals are replaced by MediaSlot's, which
		# fire the same _on_cartridge_inserted/_removed for the emulation-side work.
		if _disc_loader == MediaDimensions.LOADER_SLOT:
			_cartridge_slot.has_picked_up.disconnect(_on_cartridge_inserted)
			_cartridge_slot.has_dropped.disconnect(_on_cartridge_removed)
			_slot = MediaSlot.new()
			_slot.host = self
			_slot.slot = _cartridge_slot
			_slot.insert_depth = SLOT_INSET
			add_child(_slot)
			_slot.inserted.connect(_on_cartridge_inserted)
			_slot.removed.connect(_on_cartridge_removed)
	# Handhelds: built-in screen, on-device controls, and the held-input
	# component that turns the device itself into the port-0 controller.
	# Dual-screen clamshells keep the cabinet START/STOP button (repositioned
	# by their configure_buttons) — the back-edge power knob doesn't fit them.
	if _model.is_handheld():
		var keep_power_btn := _model.has_start_stop_button()
		_power_button.visible = keep_power_btn
		_power_button.set_deferred("monitoring", keep_power_btn)
		_power_button.set_process(keep_power_btn)
		_update_power_button_visual()
		_reset_button.visible = false
		_reset_button.set_deferred("monitoring", false)
		_reset_button.set_process(false)
		if _model.has_method("configure_handheld_body"):
			_model.configure_handheld_body(self)
		_model.configure_handheld_controls(self)
		# Restore a saved clamshell lid angle (DS/3DS); else keep the model default.
		if _lid_angle_from_save >= 0.0:
			_model.set_lid_angle_deg(_lid_angle_from_save)
		# Two-handed hold, like a game controller: HandheldInput already merges
		# buttons/sticks from both hands (retro_controller pipeline) — the
		# pickable just has to allow the second grab.
		second_hand_grab = SecondHandGrab.SECOND
		_handheld_input = HandheldInput.new()
		_handheld_input.name = "HandheldInput"
		add_child(_handheld_input)
		_handheld_input.setup(self)
		# Route port-0 rumble to the holding hands via the existing path.
		_port_controllers[0] = _handheld_input


## Interior open angle of a clamshell handheld's lid (0 shut … 180 flat), or
## -1 for systems without a lid. Used by ScenePersistence.
func get_lid_angle_deg() -> float:
	return _model.get_lid_angle_deg() if _model != null else -1.0


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
## Multi-output hardware (dual-screen handhelds) ALWAYS renders to its own
## builtin proxy — connected TVs are fed per-channel by _update_tv_mirrors.
func _screen_target() -> MeshInstance3D:
	if _channels.size() > 1:
		return _model.get_builtin_screen() if _model else null
	if connected_tv != null:
		return connected_tv.get_screen_mesh()
	return _model.get_builtin_screen() if _model else null


## True when the running core outputs a side-by-side stereo frame (Virtual Boy);
## a connected TV uses this to split the picture per-eye. Read by RetroTV.
func is_stereo_output() -> bool:
	return _model != null and _model.is_stereo_side_by_side()


## Show or hide the screen output (used by TV toggle button).
## Multi-output: per-TV blanking is handled by _update_tv_mirrors (it keys off
## each TV's own power), so a single TV's toggle must not blank the core here.
func set_screen_enabled(enabled: bool) -> void:
	if not is_powered_on or _channels.size() > 1:
		return
	_libretro.SetScreenMesh(_screen_target() if enabled else null)


## Called by the TV when one of this system's plugs connects. `plug` tells us
## which video-out channel landed (null = classic single-cable path).
func on_tv_connected(tv: RetroTV, plug: CablePlug = null) -> void:
	var ch := plug.channel if plug != null else 0
	if ch < 0 or ch >= _channels.size():
		ch = 0
	_channel_tvs[ch] = tv
	if ch == 0:
		connected_tv = tv
	if _channels.size() > 1:
		# Picture arrives via _update_tv_mirrors; a touch channel additionally
		# turns the TV's glass into the touch screen.
		if bool(_channels[ch].get("touch", false)):
			_remove_touch_surface(ch)
			var surf := TVTouchSurface.new()
			surf.setup(self, _channels[ch]["rect"], tv.get_screen_mesh())
			tv.get_screen_mesh().add_child(surf)
			_tv_touch_surfaces[ch] = surf
		return
	if is_powered_on:
		_libretro.SetScreenMesh(tv.get_screen_mesh())


## Called by the TV when a plug disconnects. Handhelds take the picture back
## onto their built-in LCD; consoles go dark.
func on_tv_disconnected(plug: CablePlug = null) -> void:
	var ch := plug.channel if plug != null else 0
	if ch < 0 or ch >= _channels.size():
		ch = 0
	var tv: RetroTV = _channel_tvs[ch]
	_channel_tvs[ch] = null
	if ch == 0:
		connected_tv = null
	if _channels.size() > 1:
		_remove_touch_surface(ch)
		_uninstall_tv_mirror(ch, tv)
		return
	if is_powered_on:
		_libretro.SetScreenMesh(_screen_target())


## The TV connected to a given video-out channel, or null (persistence).
func get_channel_tv(ch: int) -> RetroTV:
	if ch < 0 or ch >= _channel_tvs.size():
		return null
	return _channel_tvs[ch]


## How many video-out cables this system has (persistence).
func get_channel_count() -> int:
	return _channels.size()


func _remove_touch_surface(ch: int) -> void:
	var surf: TVTouchSurface = _tv_touch_surfaces[ch]
	if surf != null and is_instance_valid(surf):
		surf.queue_free()
	_tv_touch_surfaces[ch] = null


## Mirror the core's composite picture onto each connected TV through a
## per-channel screen_window material (multi-output hardware only). The C++
## VideoHandler owns only the hidden proxy; TVs are fed here, keyed off the
## proxy's emission texture (identity checks — steady state costs nothing).
func _update_tv_mirrors() -> void:
	if _channels.size() <= 1:
		return
	var tex: Texture2D = null
	if is_powered_on and _model != null:
		var scr := _model.get_builtin_screen()
		if scr != null:
			var m := scr.get_surface_override_material(0)
			if m is StandardMaterial3D:
				tex = (m as StandardMaterial3D).emission_texture
	for i in _channels.size():
		var tv: RetroTV = _channel_tvs[i]
		if tv == null or not is_instance_valid(tv):
			continue
		if tex == null or not tv.is_powered_on():
			_uninstall_tv_mirror(i, tv)
			continue
		var mat: ShaderMaterial = _tv_window_mats[i]
		if mat == null:
			mat = ShaderMaterial.new()
			mat.shader = SCREEN_WINDOW_SHADER
			var r: Rect2 = _channels[i]["rect"]
			mat.set_shader_parameter("source_rect",
				Vector4(r.position.x, r.position.y, r.size.x, r.size.y))
			mat.set_shader_parameter("eye_shift", float(_channels[i].get("eye_shift", 0.0)))
			_tv_window_mats[i] = mat
		if mat.get_shader_parameter("source_tex") != tex:
			mat.set_shader_parameter("source_tex", tex)
		var mesh := tv.get_screen_mesh()
		if mesh.get_surface_override_material(0) != mat:
			mesh.set_surface_override_material(0, mat)


## Take our window material off a TV so its own blue/dark states resume.
func _uninstall_tv_mirror(ch: int, tv: RetroTV) -> void:
	var mat: ShaderMaterial = _tv_window_mats[ch]
	if mat == null or tv == null or not is_instance_valid(tv):
		return
	var mesh := tv.get_screen_mesh()
	if mesh.get_surface_override_material(0) == mat:
		mesh.set_surface_override_material(0, null)


## A freed system must not leave its window materials / touch surfaces on TVs.
func _exit_tree() -> void:
	for i in _channels.size():
		var tv: RetroTV = _channel_tvs[i]
		if tv != null and is_instance_valid(tv):
			_uninstall_tv_mirror(i, tv)
		_remove_touch_surface(i)
	super._exit_tree()


# --- Cable management ---

func _spawn_cables() -> void:
	for i in _channels.size():
		_cable_instances[i] = CABLE_SCENE.instantiate()
	# Add cables to scene root so they're not affected by system's RigidBody transform weirdness
	call_deferred("_add_cables_to_scene")


func _add_cables_to_scene() -> void:
	for i in _channels.size():
		var inst: Node3D = _cable_instances[i]
		get_tree().current_scene.add_child(inst)
		# Track cable in the "spawned" group so clear_scene() includes it.
		inst.add_to_group("spawned")
		var plug := inst.get_node("CablePlug") as CablePlug
		var rope := inst.get_node("VerletRope") as VerletRope
		_cable_plugs[i] = plug
		_cable_ropes[i] = rope

		# Tell the plug who owns it and which channel it carries
		plug.set_system(self)
		plug.channel = i
		plug.channel_label = str(_channels[i].get("label", ""))
		if not plug.channel_label.is_empty():
			_decorate_channel_plug(plug, i)

		# Exclude the plug from colliding with this system so it doesn't jitter on spawn
		plug.add_collision_exception_with(self)

		# Position plug near the rope's start anchor (the attach point), fanned
		# out a little per channel so multiple plugs don't spawn intersecting
		plug.global_position = _attach_points[i].global_position \
			+ Vector3(0.05 * i, 0, -0.1)

		# Wire rope anchors: start = system's attach point, end = plug
		rope.start_node = _attach_points[i]
		rope.end_node = plug
		rope._init_points()
		_max_rope_lengths[i] = rope.segment_count * rope.segment_length

		# Restore a pending TV connection requested before the cable was ready
		if _pending_tv_restores[i] != null:
			print("[RetroSystem] _add_cables_to_scene: restoring pending TV connection (ch %d)" % i)
			_snap_cable_to_tv(_pending_tv_restores[i], i)
			_pending_tv_restores[i] = null
	_apply_video_out()


## True when this system offers the Enable Video Out toggle (handhelds only —
## consoles have no builtin screen, so their cable is always on).
func supports_video_out_toggle() -> bool:
	return _model != null and _model.is_handheld()


## Toggle floating: on = freeze right where it is (or where it's next dropped);
## off = normal physics resumes (unless currently held or being restored).
func set_ignore_gravity(on: bool) -> void:
	if on == ignore_gravity:
		return
	ignore_gravity = on
	if on:
		_freeze_in_place()
	elif not is_picked_up():
		freeze = false
		sleeping = false
	NetworkManager.report_event(NetObjectSync.EV_SYS_GRAVITY, {"sys": self, "on": on})


func _on_system_dropped(_pickable: Node3D) -> void:
	if ignore_gravity:
		# Deferred: let the release finish (velocities applied) before parking.
		_freeze_in_place.call_deferred()


func _freeze_in_place() -> void:
	if ignore_gravity and not is_picked_up():
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		freeze = true


## Show/hide+park the video-out cables per the video_out_enabled toggle.
## Disabling first unplugs any connected TV (so no picture lingers), then
## hides the whole cable and freezes it out of the simulation.
func set_video_out_enabled(on: bool) -> void:
	if not supports_video_out_toggle():
		on = true   # consoles are always on, whatever a save/peer says
	if on == video_out_enabled:
		return
	video_out_enabled = on
	_apply_video_out()
	NetworkManager.report_event(NetObjectSync.EV_SYS_VIDEO_OUT, {"sys": self, "on": on})


func _apply_video_out() -> void:
	for i in _channels.size():
		var inst: Node3D = _cable_instances[i]
		var plug: CablePlug = _cable_plugs[i]
		if inst == null or plug == null or not is_instance_valid(plug):
			continue
		if not video_out_enabled and _channel_tvs[i] != null:
			var tv: RetroTV = _channel_tvs[i]
			var port := tv.get_node_or_null("CompositePort") as XRToolsSnapZone
			if port and port.picked_up_object == plug:
				# Disarm around the drop so the zone's stale grab list can't
				# instantly re-snap the plug (same pattern as the disc slot).
				port.enabled = false
				port.drop_object()
				port.set_deferred("enabled", true)
		plug.enabled = video_out_enabled
		if video_out_enabled:
			inst.visible = true
			inst.process_mode = Node.PROCESS_MODE_INHERIT
			# A plug already socketed into a TV (e.g. restored from a save, where
			# _apply_video_out runs right after the snap) is held frozen at the port by
			# the snap zone. Unfreezing/parking it here drops it off the socket, and it
			# then drifts under gravity + rope tension. Only park a free-dangling plug.
			if not plug.is_picked_up():
				plug.freeze = false
				plug.global_position = _attach_points[i].global_position \
					+ Vector3(0.05 * i, 0, -0.1)
				plug.linear_velocity = Vector3.ZERO
		else:
			plug.freeze = true
			inst.visible = false
			inst.process_mode = Node.PROCESS_MODE_DISABLED


## Label a multi-output plug so the player can tell the cables apart: floating
## billboard tag ("TOP"/"BOTTOM") plus a tinted tip on the second channel.
func _decorate_channel_plug(plug: CablePlug, channel: int) -> void:
	var lbl := Label3D.new()
	lbl.name = "ChannelLabel"
	lbl.text = plug.channel_label
	lbl.pixel_size = 0.0005
	lbl.font_size = 14
	lbl.outline_size = 4
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = Vector3(0, 0.045, 0)
	plug.add_child(lbl)
	if channel > 0:
		var tip := plug.get_node_or_null("PlugTip") as MeshInstance3D
		if tip:
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.2, 0.6, 1.0)   # blue = BOTTOM
			tip.set_surface_override_material(0, mat)


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
	_update_tv_mirrors()
	_update_disc_spin(_delta)


## Spin the seated disc: ramp up while powered with the tray shut, ramp down
## when the tray opens or the power goes off. Purely visual — each peer derives
## the same state from power + tray, so no sync is needed.
func _update_disc_spin(delta: float) -> void:
	var disc := _snapped_cartridge as RetroDisc
	if disc == null or not is_instance_valid(disc):
		_disc_spin = 0.0
		return
	# "Shut and seated": a tray disc spins only with the lid closed (MediaTray.can_spin
	# already means shut-over-a-disc); a slot disc has no lid but must have finished its
	# insert ride so the spin doesn't fight MediaSlot's ride tween.
	var shut := true
	if _tray != null:
		shut = _tray.can_spin()
	elif _slot != null:
		shut = _slot.is_media_seated()
	var target := DISC_SPIN_MAX if (is_powered_on and shut) else 0.0
	var rate := DISC_SPIN_UP if target > _disc_spin else DISC_SPIN_DOWN
	_disc_spin = move_toward(_disc_spin, target, rate * delta)
	# A disc being grabbed out keeps its pose (it's no longer frozen in the bay).
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
	if not video_out_enabled:
		return   # cables hidden and frozen — nothing to clamp
	for i in _channels.size():
		var plug: CablePlug = _cable_plugs[i]
		var max_len: float = _max_rope_lengths[i]
		if plug == null or _attach_points[i] == null or max_len <= 0.0:
			continue
		# Snapped to TV or actively held by the user — don't fight whoever owns the plug
		if _channel_tvs[i] != null or plug.is_picked_up():
			continue

		var attach_pos: Vector3 = _attach_points[i].global_position
		var diff := plug.global_position - attach_pos
		var dist := diff.length()

		if dist > max_len:
			var dir := diff / dist
			# Clamp plug to rope length and kill outward velocity
			plug.global_position = attach_pos + dir * max_len
			var outward_vel := dir.dot(plug.linear_velocity)
			if outward_vel > 0.0:
				plug.linear_velocity -= dir * outward_vel


## Power on: start this system's libretro core
func power_on() -> void:
	if is_powered_on:
		return
	# A console with no TV connected still powers on and runs — the core renders
	# to its texture with no bound mesh; connecting a TV later attaches the picture
	# (SetScreenMesh), same as re-plugging a TV that was pulled mid-game. Handhelds
	# always have a built-in screen so _screen_target() is non-null for them.
	if _screen_target() == null:
		print("[RetroSystem] Powering on with no display connected (connect a TV to see output)")
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
	_update_power_button_visual()
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
	_update_power_button_visual()
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


## True when this system is a home computer (ScummVM, DOS, Amiga…) whose core
## reads the mouse on port 0 and takes keyboard input globally.
func _is_computer() -> bool:
	var info := SystemInfo.for_system(systemid)
	return info != null and info.computer


## The libretro port a plugged peripheral should drive. On computer systems the
## mouse always drives port 0 — where ScummVM/DOS/Amiga cores poll it — no matter
## which cabinet slot it's in; every other device drives its own physical port.
func _libretro_port_for(device_type: int, physical_port: int) -> int:
	if device_type == RETRO_DEVICE_MOUSE and _is_computer():
		return 0
	return physical_port


## Whether a plugged peripheral occupies a numbered libretro port device. A
## computer keyboard does not: its keys are global to port 0 regardless, so it
## leaves the port free for the mouse and avoids cores that mishandle a
## RETRO_DEVICE_KEYBOARD "controller" set on a numbered port.
func _claims_port_device(device_type: int) -> bool:
	return not (device_type == RETRO_DEVICE_KEYBOARD and _is_computer())


## Returns the Libretro node so plugged-in controller objects can call input methods on it.
func get_libretro_node() -> Libretro:
	return _libretro


# --- Controller port snap handlers ---

func _on_port_snapped(port_index: int, controller: Node3D) -> void:
	add_collision_exception_with(controller)
	var device_type: int = controller.get("device_type") if "device_type" in controller else 1
	# The libretro port a peripheral drives isn't always its cabinet slot: on
	# computer systems the mouse is forced to port 0 (where those cores poll it),
	# so a mouse + keyboard can share the cabinet. See _libretro_port_for().
	var lib_port := _libretro_port_for(device_type, port_index)
	print("[RetroSystem] port %d snapped: device_type=%d -> libretro port %d" %
		[port_index, device_type, lib_port])
	if _claims_port_device(device_type):
		set_controller_port_device(lib_port, device_type)
	# The snapped node is a ControllerPlug (cable end). Unwrap to the actual
	# RetroController so rumble can be routed to its set_rumble() method.
	_port_controllers[port_index] = controller.get_controller() \
		if controller.has_method("get_controller") else controller
	if controller.has_method("on_plugged_in"):
		controller.on_plugged_in(self, lib_port)
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
	# Clear the SAME libretro port the snap set (a computer mouse claimed port 0,
	# not its cabinet slot; a computer keyboard claimed none).
	var device_type: int = controller.get("device_type") \
		if is_instance_valid(controller) and "device_type" in controller else 1
	if is_instance_valid(controller):
		remove_collision_exception_with(controller)
	_port_controllers[port_index] = null
	if _claims_port_device(device_type):
		set_controller_port_device(_libretro_port_for(device_type, port_index), RETRO_DEVICE_NONE)
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

## True when a piece of media (cartridge/disc) belongs in this system's slot.
func _accepts_media(obj: Node3D) -> bool:
	if not "systemid" in obj:
		return true
	var mid := str(obj.get("systemid"))
	if mid.is_empty():
		return true
	return mid == systemid or mid in _MEDIA_COMPAT.get(systemid, [])


## Returns the currently snapped cartridge, or null (used by save/load).
func get_snapped_cartridge() -> Node3D:
	return _snapped_cartridge


## Restore a cable→TV connection after loading from a save file.
## Safe to call before the cables have finished spawning — the snap will be
## deferred until _add_cables_to_scene() runs if the plug isn't ready yet.
## `channel` picks the video-out cable (0 on classic single-cable systems).
func restore_cable_connection(tv: RetroTV, channel: int = 0) -> void:
	if channel < 0 or channel >= _channels.size():
		channel = 0
	print("[RetroSystem] restore_cable_connection: ch=%d plug=%s tv=%s" %
		[channel, _cable_plugs[channel] if channel < _cable_plugs.size() else null, tv])
	if channel < _cable_plugs.size() and _cable_plugs[channel] != null:
		_snap_cable_to_tv(tv, channel)
	else:
		print("[RetroSystem] cable plug not ready yet, deferring restore")
		_pending_tv_restores[channel] = tv


func _snap_cable_to_tv(tv: RetroTV, channel: int = 0) -> void:
	tv.accept_plug_restore(_cable_plugs[channel])


## Restore a cartridge→slot insertion after loading from a save file. Slot/tray
## loaders seat the disc immediately through MediaSlot/MediaTray (no ride, filter
## bypassed); plain cartridge systems snap it through the zone as before.
func restore_cartridge(cartridge: Node3D) -> void:
	if _slot != null:
		_slot.restore(cartridge)
	elif _tray != null:
		_tray.restore(cartridge)
	else:
		_cartridge_slot.pick_up_object(cartridge)


## Restore a controller plug into a port after loading from a save file.
func restore_controller_plug(port_index: int, plug: ControllerPlug) -> void:
	if port_index < 0 or port_index >= _port_zones.size():
		return
	_port_zones[port_index].pick_up_object(plug)


func _on_cartridge_inserted(cartridge: Node3D) -> void:
	_snapped_cartridge = cartridge
	# Prevent the frozen kinematic cartridge from physically pushing the system body.
	# Slot/tray loaders let their MediaSlot/MediaTray own the exception (held until
	# the disc is grabbed clear), so only plain cartridge decks add one here.
	if _slot == null and _tray == null:
		add_collision_exception_with(cartridge)
	if cartridge.has_method("get_rom_path"):
		rom_path = cartridge.get_rom_path()
	# Back-fill the cartridge's systemid (save-recovery list needs it to
	# resolve the core) — a cart inserted into an NES is an NES cart.
	if "systemid" in cartridge and str(cartridge.get("systemid")).is_empty():
		cartridge.set("systemid", systemid)
	_model.play_cartridge_insert(cartridge, _cartridge_slot)
	# (Slot/tray loaders already seated the disc and set its grabbability through
	# MediaSlot/MediaTray — the disc's enabled state follows the lid there.)
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
		# Slot/tray loaders let MediaSlot/MediaTray manage (and hold) the collision
		# exception until the disc is grabbed clear — don't drop it here.
		if _slot == null and _tray == null:
			remove_collision_exception_with(_snapped_cartridge)
		_snapped_cartridge = null
	_disc_spin = 0.0
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
			if _slot:
				_slot.eject()


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
	# MediaTray gates the well (accepts a disc only while open + empty), makes a
	# seated disc grabbable only while open, and swings the procedural lid pivot.
	if _tray:
		_tray.set_open(open)
	_eject_button.set_latched_pressed(open)
	# Bespoke GLB tray models animate their own lid here.
	if open:
		_model.play_open()
	else:
		_model.play_close()


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
