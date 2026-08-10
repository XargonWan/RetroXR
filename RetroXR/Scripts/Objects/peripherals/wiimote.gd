## Wiimote — a wireless Wii Remote that pairs with a RetroSystem instead of
## plugging into one, and drives Dolphin's emulated remote on the slot it claims.
##
## Three channels go to the core every frame, and each is a different mechanism:
##   • IR       — every lit sensor bar LED in the room is projected into the
##     camera in the nose of this remote, and the resulting pixel coordinates
##     handed to the core on pointer indices 0-3. That is the whole of the aim: no
##     cursor, no screen, no raycast. Dolphin feeds them to its emulated camera
##     verbatim under `dolphin_ir_passthrough`, which is why that option is forced.
##   • JOYPAD   — buttons, plus the Nunchuk's stick when one is seated.
##   • SENSOR   — real accelerometer derived from the barrel's motion, in g, which
##     is what makes tilt and shake games work. Gyro is deliberately NOT sent; see
##     the note on _send_accel.
##
## The IR channel replaced a raycast at the television, which could not be made
## right. That path sends a CURSOR — a point on the glass — and the core turns it
## back into a camera view by rotating a notional remote parked two metres from
## the bar, by a scale no geometry produces. Where the game then drew its hand
## depended on a constant fitted per game, and it compressed vertically and
## drifted. Projecting the real lights costs the same arithmetic and carries roll
## and distance too, neither of which a point on a plane can express.
##
## Pairing mirrors the hardware: press SYNC on the console, then SYNC on the
## remote (under the battery cover). The four blue LEDs show the slot. Pressing
## the remote's SYNC while already paired drops it, so unpairing needs no walk.
class_name Wiimote
extends XRToolsPickable


const NUNCHUK_PLUG_SYSTEMID := "wii_nunchuk"

# Dolphin libretro device ids (DolphinLibretro/Input.cpp). WIIMOTE is #defined to
# RETRO_DEVICE_JOYPAD, so a bare remote and a plain pad share the value 1 — see
# RetroSystem._cabinet_device_id for why that matters.
const RETRO_DEVICE_WIIMOTE := 1
const RETRO_DEVICE_WIIMOTE_NC := 769

## Analog range libretro expects on a stick axis.
const ANALOG_SCALE := 32767.0
## Full-scale value on a libretro pointer axis. The IR path uses the positive half
## only: the core's IRPassthrough controls read 0..1, so 0 is one edge of the
## sensor and 32767 the other.
const POINTER_SCALE := 32767.0

# ── Emulated IR camera ────────────────────────────────────────────────────────
#
# Dolphin's numbers, from CameraLogic in Core/HW/WiimoteEmu/Camera.h, and they are
# a description of the real hardware rather than a choice. They have to match: the
# frontend now IS the camera, and a game reading the dots was calibrated against a
# real one. Widen the field and every cursor in the machine travels too far.

## IR objects the camera can report. Four exist; a sensor bar only ever lights two
## of them, and Dolphin's own note says filling all four can cause stuttering.
const IR_OBJECTS := 4
const CAMERA_RES_X := 1024.0
const CAMERA_RES_Y := 768.0
const CAMERA_FOV_X_DEG := 42.0
const CAMERA_AR := 4.0 / 3.0

## Input thresholds per XRController float input name (shared with RayGun).
const INPUT_THRESHOLDS: Dictionary = {
	"trigger":       0.3,
	"grip":          0.3,
	"ax_button":     0.5,
	"by_button":     0.5,
	"primary_click": 0.5,
}

## Height of the drop hint above the remote, in metres.
const HINT_HEIGHT := 0.10

## Scroll Lock capture glyph, matching RetroController's.
const ICON_CAPTURE := 0xEC17
const ICON_SIZE := 0.030
const ICON_HEIGHT := 0.075

## Desktop keyboard map: Godot action -> the remote's own control name. The same
## RETRO_JOYPAD_* actions every other device reads, so one set of keys drives
## whatever is in hand. Only live while Scroll Lock capture is on — otherwise
## these keys still belong to the player.
const DESKTOP_BUTTON_MAP: Dictionary = {
	"RETRO_JOYPAD_B":      "b",
	"RETRO_JOYPAD_A":      "a",
	"RETRO_JOYPAD_X":      "one",
	"RETRO_JOYPAD_Y":      "two",
	"RETRO_JOYPAD_START":  "plus",
	"RETRO_JOYPAD_SELECT": "minus",
	"RETRO_JOYPAD_R3":     "home",
	"RETRO_JOYPAD_R2":     "shake",
}

## Desktop d-pad, read straight off the same actions.
const DESKTOP_DPAD: Dictionary = {
	"RETRO_JOYPAD_UP":    ControllerBindings.JOYPAD_UP,
	"RETRO_JOYPAD_DOWN":  ControllerBindings.JOYPAD_DOWN,
	"RETRO_JOYPAD_LEFT":  ControllerBindings.JOYPAD_LEFT,
	"RETRO_JOYPAD_RIGHT": ControllerBindings.JOYPAD_RIGHT,
}

## How far the battery cover must swing before SYNC is reachable, in degrees.
const COVER_OPEN_DEG := 45.0

## The trigger's swing. Negative about +X so the blade sweeps back toward the
## palm, same sign and reasoning as the ray gun's. (The face caps set their own
## travel in the scene — they are VRButtons and move themselves.)
const TRIGGER_PULL_DEG := -16.0
const ANIM_WEIGHT := 0.4

## Player-LED colours. "Off" is the unlit lens, not black — an unlit LED still
## catches room light.
const LED_OFF := Color(0.06, 0.07, 0.12)
const LED_ON := Color(0.25, 0.6, 1.0)
## Seconds per blink phase while unpaired or pairing.
const LED_BLINK_PERIOD := 0.5

## Gravity used to convert measured acceleration into g. The core multiplies by
## the same constant on the way back in (DolphinLibretro/Input.cpp).
const G := 9.80665
## Low-pass weight on the derived acceleration. VR linear_velocity is noisy
## enough that raw differentiation reads as a permanent shake.
const ACCEL_SMOOTHING := 0.25

## libretro device type reported to the system. Flips to _NC while a Nunchuk is
## seated in the expansion port.
var device_type: int = RETRO_DEVICE_WIIMOTE

## Whether to show the aim dot on the screen.
var show_laser_dot: bool = true

## Desktop: park the remote in the lower-right of the view instead of floating it
## on the grab ray, and aim from the camera centre — the same FPS-weapon handling
## the ray gun uses (desktop_pickup._is_fps_snap reads this).
##
## Without it the remote hangs in the middle of the screen on the ray, directly in
## front of the very thing it is pointing at. The aim was already working; the
## hand cursor was simply behind the remote.
var desktop_fps_snap: bool = true

# Active bindings (loaded from ControllerBindings on pair)
var _wiimote_map: Dictionary = ControllerBindings.DEFAULT_WIIMOTE_MAP.duplicate()

# Pairing state
var _connected_system: RetroSystem = null
var _port_index: int = -1
var _pending_port_restore: Dictionary = {}

# Nunchuk seated in the expansion port, or null
var _nunchuk: Nunchuk = null

# Cached screen geometry (set on pair, cleared on unpair)
var _screen_mesh: MeshInstance3D = null
var _screen_w: float = 0.0
var _screen_h: float = 0.0

# Toggle-hold state (VR)
var _allow_drop := false
var _saved_by: Node3D = null
var _holding_ctrl: XRController3D = null
var _desktop_held: bool = false

var _hint: HeldHint = null
var _capture: ScrollLockCapture = null
var _locomotion_manager: LocomotionManager = null
var _spawn_menu_ctrl: Node = null
var _left_vr_ctrl: XRController3D = null
var _right_vr_ctrl: XRController3D = null

# Reference-counted pointer blocking — prevents multi-instance conflicts.
var _blocking_left: bool = false
var _blocking_right: bool = false

# Accelerometer derivation
var _prev_velocity := Vector3.ZERO
var _accel_smoothed := Vector3.ZERO

# LED animation
var _led_materials: Array[StandardMaterial3D] = []
var _blink_clock := 0.0
## Last aim state printed, so the log speaks only on change. See _log_aim.
var _last_aim_log: String = ""
var _last_aim_value_ms: int = 0

## Half-field tangents of the emulated camera, filled in _ready. Dolphin passes
## the ratio of the FOV ANGLES as the projection's aspect, so the horizontal
## tangent is the vertical one scaled by 4:3 rather than tan(fov_x / 2) — a
## difference of most of a degree, and this is not the place to be almost right.
var _tan_half_fov := Vector2.ONE

## Print where the remote is aiming, twice a second.
##
## ON while the pointer's alignment is being chased. Exported so it can be ticked
## per-remote later, but defaulted true because a remote is SPAWNED — there is no
## authored node in the editor to tick, so a false default is a switch with
## nothing to flip it. Turn this off (or delete it with the two _log_aim helpers)
## once the aim is trusted.
@export var aim_debug: bool = true

## The face buttons, by the control name each one is. These are VRButtons: they
## can be POKED with the free hand as well as driven from the held hand, which is
## the only way the remote's full set is reachable — five usable inputs on one
## hand against seven buttons and a d-pad. VRButton also owns their depress
## animation, so nothing here moves a cap by hand.
const FACE_BUTTONS: Dictionary = {
	"a":     "AButton",
	"one":   "OneButton",
	"two":   "TwoButton",
	"plus":  "PlusButton",
	"minus": "MinusButton",
	"home":  "HomeButton",
}
var _face_buttons: Dictionary = {}   # control name -> VRButton
var _trigger_rest := Transform3D()
var _dpad_rest := Transform3D()

## How far the d-pad rocker tilts toward the direction being pushed, in degrees.
const DPAD_TILT_DEG := 6.0
## Stick deflection that counts as a d-pad press.
const DPAD_THRESHOLD := 0.35

@onready var _barrel_tip: Node3D = $BarrelTip
@onready var _laser_dot: MeshInstance3D = $LaserDot
@onready var _expansion_port: XRToolsSnapZone = $ExpansionPort
@onready var _sync_button: VRButton = $SyncButton
## Under CoverPivot, not beside it: the hinge's grab box has to ride the cover it
## swings, or it stays over the shut position while the lid moves out from under it.
@onready var _battery_cover: VRHinge = $CoverPivot/BatteryCover
@onready var _trigger_pivot: Node3D = $TriggerPivot
@onready var _dpad: Node3D = $DPad
@onready var _leds: Node3D = $PlayerLEDs


## The remote is aimed and fired from the hand holding it, so the push-out
## gesture has nothing to bind to. Same call the ray gun makes.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	add_to_group(ControllerBindings.CONSUMER_GROUP)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	_capture = ScrollLockCapture.attach(self, _can_capture,
		ICON_CAPTURE, ICON_HEIGHT, ICON_SIZE)
	_hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
		["keyboard_scroll_lock_outline"], "Send keys here")
	_laser_dot.visible = false
	var tan_y := tan(deg_to_rad(CAMERA_FOV_X_DEG / CAMERA_AR) * 0.5)
	_tan_half_fov = Vector2(CAMERA_AR * tan_y, tan_y)
	_cache_controls()
	_setup_leds()
	# snap_require alone would also take a console pad's plug — every ControllerPlug
	# joins that group. The systemid sentinel is what makes this socket the
	# Nunchuk's and nothing else's, the mirror of RetroSystem._accepts_plug.
	_expansion_port.snap_filter = _accepts_nunchuk
	_expansion_port.has_picked_up.connect(_on_nunchuk_seated)
	_expansion_port.has_dropped.connect(_on_nunchuk_removed)
	_sync_button.button_pressed.connect(_on_sync_pressed)
	_sync_button.set_active(false)
	_battery_cover.rotation_changed.connect(_on_cover_moved)
	call_deferred("_find_vr_nodes")


func _find_vr_nodes() -> void:
	_locomotion_manager = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	_spawn_menu_ctrl = get_tree().root.find_child("SpawnMenuController", true, false)
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		var ctrl := node as XRController3D
		if ctrl == null:
			continue
		if ctrl.tracker == &"left_hand":
			_left_vr_ctrl = ctrl
		elif ctrl.tracker == &"right_hand":
			_right_vr_ctrl = ctrl
	_update_locomotion_block()
	# A restore that arrived before this node was in the tree.
	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.attach_expanded_controller(idx, self)


# ── Pairing ───────────────────────────────────────────────────────────────────

## SYNC on the remote. Paired → drop the slot (no console trip). Unpaired → find
## a console with an open pairing window and claim its lowest free slot.
func _on_sync_pressed() -> void:
	if _connected_system != null:
		print("[Wiimote] SYNC while paired — releasing slot %d" % _port_index)
		var link := _connected_system.get_wii_link()
		if link != null:
			link.unpair(self)
		return
	var host := _nearest_listening_link()
	if host == null:
		print("[Wiimote] SYNC with no console listening — press SYNC on the console first")
		return
	if host.pair(self) < 0:
		print("[Wiimote] pairing refused — that console is full")


## Nearest console currently listening. Nearest rather than first so two Wiis in
## one room can be paired to independently: walk to the one you mean.
func _nearest_listening_link() -> WiiLink:
	var best: WiiLink = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group(WiiLink.PAIRING_GROUP):
		var link := node as WiiLink
		if link == null or not is_instance_valid(link.host):
			continue
		var d := global_position.distance_to(link.host.global_position)
		if d < best_d:
			best_d = d
			best = link
	return best


## Called by RetroSystem when a slot is claimed — by pairing, by a rehome after a
## wired pad took this remote's slot, or by a save restore.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_load_bindings()
	_cache_screen_geometry()
	_laser_dot.visible = show_laser_dot
	# The core leaves IR on the right analog stick unless this is set, in which
	# case the raycast below reaches nothing. It is consumed mid-run.
	var libretro := system.get_libretro_node()
	if is_instance_valid(libretro):
		libretro.SetCoreOption("dolphin_ir_mode", "2")
	print("[Wiimote] paired to slot %d (device %d)" % [port_index, device_type])


func on_unplugged() -> void:
	print("[Wiimote] released slot %d" % _port_index)
	_connected_system = null
	_port_index = -1
	_screen_mesh = null
	_screen_w = 0.0
	_screen_h = 0.0
	_laser_dot.visible = false


## Marker method. RetroSystem._evict_remote_from looks for this to tell a wireless
## remote (which it may move) from a wired pad (which it may not).
func on_wireless_rehomed() -> void:
	pass


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if is_inside_tree():
		system.attach_expanded_controller(port_index, self)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


## The Nunchuk seated in the expansion port, or null. Read when saving.
func get_nunchuk() -> Nunchuk:
	return _nunchuk


## The object that rides the desktop's second FPS slot while this remote is held.
##
## A Nunchuk is a pickable in its own right on a metre of cord, so on the desktop
## — where the remote is pinned to the corner of the view rather than carried by a
## hand — it had nothing holding it and simply trailed along the floor behind the
## player. This hands it the other hand. desktop_pickup polls it every frame, so
## seating or pulling the cord mid-hold is all it takes.
func desktop_companion() -> XRToolsPickable:
	return _nunchuk


## Re-seat a Nunchuk after a load. Deferred because the nunchuk spawns its cord
## on its own deferred call — its plug does not exist on the frame the scene is
## rebuilt, and there is nothing to snap until it does.
func restore_nunchuk(nc: Nunchuk) -> void:
	if not is_instance_valid(nc):
		return
	_reseat_nunchuk.call_deferred(nc, RESEAT_RETRIES)


## Retries are bounded, not "until it works": a nunchuk that was freed mid-load
## would otherwise reschedule this every idle frame for the life of the session.
const RESEAT_RETRIES := 8

func _reseat_nunchuk(nc: Nunchuk, tries_left: int) -> void:
	if not is_instance_valid(nc):
		return
	var plug := nc.get_plug()
	if plug != null:
		_expansion_port.pick_up_object(plug)
		return
	if tries_left <= 0:
		push_warning("[Wiimote] nunchuk cord never appeared; left unseated")
		return
	_reseat_nunchuk.call_deferred(nc, tries_left - 1)


func reload_bindings() -> void:
	_load_bindings()


func _load_bindings() -> void:
	var systemid := ""
	if is_instance_valid(_connected_system):
		systemid = _connected_system.systemid
	_wiimote_map = ControllerBindings.get_for_system(systemid)["wiimote"]


## Find the glass to aim at. Re-runnable, and re-run whenever it has nothing —
## see _update_aim.
##
## This used to fire once, when the remote claimed its slot, and give up quietly
## if the set was not cabled to the console at that instant. A remote pairs by
## handshake, so that instant has nothing to do with when the A/V lead went in;
## restore a saved room and the order is whatever the file happens to list. Miss
## it and the pointer never worked again for that pairing, while every button
## carried on working — they do not need the screen — which reads as "the
## pointer is broken" rather than "it never found the television".
func _cache_screen_geometry() -> void:
	if _connected_system == null or _connected_system.connected_tv == null:
		return
	var mesh := _connected_system.connected_tv.get_screen_mesh()
	if mesh == null:
		return
	var aabb := mesh.get_aabb()
	_screen_mesh = mesh
	_screen_w = aabb.size.x
	_screen_h = aabb.size.y


# ── Battery cover / SYNC access ───────────────────────────────────────────────

## SYNC only exists once the cover is off it. Hiding the cap is not enough —
## VRButton.set_active is what takes it off the pointable layer and stops it
## polling fingertips, so a closed cover really does cover it.
func _on_cover_moved(degrees: float) -> void:
	_sync_button.set_active(degrees >= COVER_OPEN_DEG)


# ── Nunchuk ───────────────────────────────────────────────────────────────────

func _accepts_nunchuk(obj: Node3D) -> bool:
	return "systemid" in obj and str(obj.get("systemid")) == NUNCHUK_PLUG_SYSTEMID


func _on_nunchuk_seated(plug: Node3D) -> void:
	var owner_node: Node3D = plug.get_controller() if plug.has_method("get_controller") else plug
	_nunchuk = owner_node as Nunchuk
	_set_device_type(RETRO_DEVICE_WIIMOTE_NC)


## XRToolsSnapZone.has_dropped carries no argument — it does not say what left,
## only that the zone is empty. Which is enough: the zone holds one thing, and
## _nunchuk is already that thing.
func _on_nunchuk_removed() -> void:
	_nunchuk = null
	_set_device_type(RETRO_DEVICE_WIIMOTE)


## Re-announce the slot when the extension changes. The core rebuilds the whole
## Wiimote mapping on this call — including which buttons mean what, which is why
## _pressed_now reads a different table per device type.
func _set_device_type(dev: int) -> void:
	if dev == device_type:
		return
	device_type = dev
	if _connected_system != null and _port_index >= 0:
		_connected_system.set_controller_port_device(_port_index, device_type)
		print("[Wiimote] extension changed — slot %d re-announced as %d"
			% [_port_index, device_type])


# ── Toggle-hold (mirrors RayGun) ──────────────────────────────────────────────

func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)
	_set_face_buttons_active(true)
	var pickup := by as XRToolsFunctionPickup
	var ctrl := pickup.get_controller() if pickup else null as XRController3D
	if ctrl == null:
		if by.is_in_group("desktop_hand"):
			_desktop_held = true
			_laser_dot.visible = _connected_system != null and show_laser_dot
			if _capture:
				_capture.refresh()
		return
	_saved_by = by
	_holding_ctrl = ctrl
	_set_model_visible(ctrl, false)
	_update_pointer_block(ctrl, true)
	_update_locomotion_block()


func _on_dropped_signal(_pickable: Node3D) -> void:
	if not _allow_drop and is_instance_valid(_saved_by):
		call_deferred("_rehold")
		return
	if _hint:
		_hint.on_dropped()
	_set_face_buttons_active(false)
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = false
	_saved_by = null
	_holding_ctrl = null
	_desktop_held = false
	_laser_dot.visible = false
	# Capture is always a subset of "held", so letting go has to drop it or the
	# player is left with their keyboard pointed at a remote on the floor.
	if _capture:
		_capture.release()
	_update_locomotion_block()


func _rehold() -> void:
	if _allow_drop:
		_allow_drop = false
		return
	if not is_instance_valid(_saved_by):
		_set_model_visible(_holding_ctrl, true)
		_update_pointer_block(_holding_ctrl, false)
		_saved_by = null
		_holding_ctrl = null
		_update_locomotion_block()
		return
	_saved_by.call("_pick_up_object", self)


func _set_model_visible(ctrl: XRController3D, shown: bool) -> void:
	if is_instance_valid(ctrl) and ctrl.has_method("set_model_visible"):
		ctrl.call("set_model_visible", shown)


func _is_combo_pressed(ctrl: XRController3D) -> bool:
	if not HeldHint.is_combo_pressed(ctrl):
		return false
	if _hint:
		_hint.note_used(&"drop_vr")
	return true


func _drop_all() -> void:
	_set_model_visible(_holding_ctrl, true)
	_update_pointer_block(_holding_ctrl, false)
	_allow_drop = true
	_holding_ctrl = null
	_laser_dot.visible = false
	_update_locomotion_block()
	drop()


func _exit_tree() -> void:
	if _blocking_left and is_instance_valid(_left_vr_ctrl):
		_update_pointer_block(_left_vr_ctrl, false)
	if _blocking_right and is_instance_valid(_right_vr_ctrl):
		_update_pointer_block(_right_vr_ctrl, false)
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT, false)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, false)
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, false)
	_allow_drop = true
	super._exit_tree()


func _update_locomotion_block() -> void:
	var left_held  := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"left_hand"
	var right_held := is_instance_valid(_holding_ctrl) and _holding_ctrl.tracker == &"right_hand"
	var desktop_claim := _desktop_held and _connected_system != null and _port_index >= 0
	if _locomotion_manager != null:
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_LEFT,  left_held)
		_locomotion_manager.set_block(&"retro_hold", LocomotionManager.CHANNEL_RIGHT, right_held)
		_locomotion_manager.set_block(_desktop_block_owner(),
			LocomotionManager.CHANNEL_DESKTOP_MOVE, desktop_claim)
	if is_instance_valid(_spawn_menu_ctrl) and "disabled" in _spawn_menu_ctrl:
		_spawn_menu_ctrl.set("disabled", left_held)


func _update_pointer_block(ctrl: XRController3D, should_block: bool) -> void:
	if not is_instance_valid(ctrl):
		return
	var is_left := ctrl.tracker == &"left_hand"
	var currently_blocking: bool = _blocking_left if is_left else _blocking_right
	if should_block == currently_blocking:
		return
	if is_left:
		_blocking_left = should_block
	else:
		_blocking_right = should_block
	var pointer: Node3D = ctrl.get_node_or_null("FunctionPointer")
	if not pointer:
		return
	var delta_count := 1 if should_block else -1
	var count: int = maxi(0, pointer.get_meta("block_count", 0) + delta_count)
	pointer.set_meta("block_count", count)
	pointer.visible = count == 0
	var ray: RayCast3D = pointer.get_node_or_null("RayCast") as RayCast3D
	if ray:
		ray.enabled = count == 0


func _desktop_block_owner() -> StringName:
	return StringName("desktop_hold_%d" % get_instance_id())


# ── Desktop keyboard (Scroll Lock capture) ────────────────────────────────────

## May this remote take the keyboard right now? Same rule as RetroController's:
## held on the desktop and actually driving a port, so capture can never outlive
## the grip and strand the player with WASD blocked.
func _can_capture() -> bool:
	return _desktop_held and _connected_system != null and _port_index >= 0


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo() or _capture == null:
		return
	if _capture.handle_key(key):
		get_viewport().set_input_as_handled()


## The remote's controls as the keyboard sees them. Empty unless capture is on —
## otherwise the RETRO_JOYPAD_* keys still belong to the player, which is the
## whole point of the Scroll Lock gate.
func _desktop_pressed() -> Dictionary:
	var out: Dictionary = {}
	if _capture == null or not _capture.is_active():
		return out
	for action_name: String in DESKTOP_BUTTON_MAP:
		if Input.is_action_pressed(action_name):
			out[String(DESKTOP_BUTTON_MAP[action_name])] = true
	return out


## Desktop d-pad bits, read off the same actions.
func _desktop_dpad_mask() -> int:
	if _capture == null or not _capture.is_active():
		return 0
	var mask := 0
	for action_name: String in DESKTOP_DPAD:
		if Input.is_action_pressed(action_name):
			mask |= 1 << int(DESKTOP_DPAD[action_name])
	return mask


# ── Shell animation ───────────────────────────────────────────────────────────

func _cache_controls() -> void:
	for key: String in FACE_BUTTONS:
		var b := get_node_or_null(String(FACE_BUTTONS[key])) as VRButton
		if b != null:
			_face_buttons[key] = b
	if _trigger_pivot != null:
		_trigger_rest = _trigger_pivot.transform
	if _dpad != null:
		_dpad_rest = _dpad.transform
	# Live only while the remote is in a hand. VRButton puts itself on the
	# pointable layer, and a remote lying across the room whose caps answer the
	# laser is a remote you cannot pick up by pointing at it — the beam presses 1
	# instead. It also stops every unheld remote in the room polling fingertips.
	_set_face_buttons_active(false)


## Give each LED its own material so they can light independently. The scene
## shares one sub-resource across the four lenses, which would otherwise mean
## tinting one tints all of them.
func _setup_leds() -> void:
	for child in _leds.get_children():
		var mi := child as MeshInstance3D
		if mi == null:
			continue
		var mat := StandardMaterial3D.new()
		mat.albedo_color = LED_OFF
		mat.emission_enabled = true
		mat.emission = LED_ON
		mat.emission_energy_multiplier = 0.0
		mi.set_surface_override_material(0, mat)
		_led_materials.append(mat)


## Three states, and the middle one is the point:
##   * unpaired          — all four blinking together, as in discovery
##   * paired, set OFF   — dark. A remote is not talking to a console that is not
##                         running, and lighting a player number there claimed a
##                         connection the game could not possibly see.
##   * paired, set ON    — LED N solid for slot N
func _update_leds(delta: float) -> void:
	if _led_materials.is_empty():
		return
	_blink_clock += delta
	var blink_on := fmod(_blink_clock, LED_BLINK_PERIOD * 2.0) < LED_BLINK_PERIOD
	var live := _port_index >= 0 and is_instance_valid(_connected_system) \
		and _connected_system.is_powered_on
	for i in range(_led_materials.size()):
		var lit := false
		if _port_index < 0:
			lit = blink_on
		elif live:
			lit = i == _port_index
		var mat := _led_materials[i]
		mat.albedo_color = LED_ON if lit else LED_OFF
		mat.emission_energy_multiplier = 1.6 if lit else 0.0


## Move the shell to match what is being pressed.
##
## The face caps are NOT moved here — they are VRButtons and animate themselves.
## What they cannot see is the other route in, a bound hand input pressing a
## button nobody is touching, so that is handed to them as a latch and they draw
## it with the same travel a poke gets. One depress animation, two causes.
func _animate_controls(pressed: Dictionary) -> void:
	for key: String in _face_buttons:
		(_face_buttons[key] as VRButton).set_latched_pressed(pressed.get(key, false))

	if _trigger_pivot != null:
		var pull := 1.0 if pressed.get("b", false) else 0.0
		var tgt_x := Transform3D(
			_trigger_rest.basis * Basis(Vector3.RIGHT, deg_to_rad(TRIGGER_PULL_DEG * pull)),
			_trigger_rest.origin)
		_trigger_pivot.transform = _trigger_pivot.transform.interpolate_with(tgt_x, ANIM_WEIGHT)

	# The d-pad is one rocker, not four keys, so it TILTS toward the push rather
	# than sinking. Driven off the raw stick rather than the thresholded d-pad
	# bits, so it leans with the thumb instead of snapping between five poses.
	if _dpad != null:
		var s := _dpad_stick()
		# Both axes are NEGATED, and it is the same reason twice: a rocker dips on
		# the side you press. UP is the arm toward the front of the remote (-Z), so
		# pushing up has to carry -Z downward — a positive turn about +X lifts it
		# instead, which read as the pad answering the opposite direction. Likewise
		# RIGHT (+X) must dip, not rise.
		var tgt := Transform3D(
			_dpad_rest.basis
				* Basis(Vector3.RIGHT, deg_to_rad(-DPAD_TILT_DEG * s.y))
				* Basis(Vector3.BACK, deg_to_rad(-DPAD_TILT_DEG * s.x)),
			_dpad_rest.origin)
		_dpad.transform = _dpad.transform.interpolate_with(tgt, ANIM_WEIGHT)


## set_interactive, not set_active: the caps are moulded into the shell and stay
## on show whether or not they can be pressed. set_active would hide them and
## leave a blank white slab whenever the remote is put down.
func _set_face_buttons_active(active: bool) -> void:
	for key: String in _face_buttons:
		(_face_buttons[key] as VRButton).set_interactive(active)


## What the aim is doing, printed only when the answer CHANGES.
##
## The pointer has three distinct ways of showing nothing — no screen found, a ray
## pointing away from the glass, and a hit that lands outside it — and from the
## room all three look identical: no hand. This says which, once, per transition,
## so a single run tells you where to look instead of a guess.
func _log_aim(state: String) -> void:
	if state == _last_aim_log:
		return
	_last_aim_log = state
	print("[Wiimote] aim: %s" % state)


## Twice a second, where the sensor bar's lights landed on the emulated sensor.
##
## The state log above only speaks on transitions, which is right for "why is
## there no pointer" and useless for "the pointer is in the wrong place". This is
## the calibration read, in the units the hardware works in: pixels on a
## 1024 x 768 sensor, with the centre at 512,384 when the remote is aimed square
## at the middle of the bar. Their SEPARATION is the distance to the bar, and it
## should shrink as you back away — that is the reading no cursor could carry.
func _log_aim_points(points: Array[Vector3]) -> void:
	if not aim_debug:
		return
	var now := Time.get_ticks_msec()
	if now - _last_aim_value_ms < 500:
		return
	_last_aim_value_ms = now
	var parts: Array[String] = []
	for p: Vector3 in points:
		parts.append("(%.0f,%.0f)" % [p.x, p.y])
	var gap := 0.0
	if points.size() >= 2:
		gap = Vector2(points[0].x, points[0].y).distance_to(Vector2(points[1].x, points[1].y))
	print("[Wiimote] IR %s  separation=%.0f px" % [" ".join(parts), gap])


## The holding hand's thumbstick, or zero when nothing is holding the remote.
func _dpad_stick() -> Vector2:
	if _wiimote_map.get("stick", "dpad") != "dpad" or not is_instance_valid(_holding_ctrl):
		return Vector2.ZERO
	return _holding_ctrl.get_vector2("primary")


# ── Input forwarding ──────────────────────────────────────────────────────────

## Which named remote controls are down this frame, from BOTH routes: the hand
## holding the remote, and a free hand poking the shell. One read, shared by the
## core and the shell animation, so the two can never disagree.
##
## Every face button appears in the result whether or not anything is mapped to
## it, so a control with no binding still reports false rather than nothing —
## _button_mask and the animation both read it either way.
func _pressed_now() -> Dictionary:
	var out: Dictionary = {}
	for key: String in FACE_BUTTONS:
		out[key] = false
	var vr := is_instance_valid(_holding_ctrl)
	for source: String in _wiimote_map:
		if source == "stick":
			continue
		var control := str(_wiimote_map[source])
		if control.is_empty() or control == "none":
			continue
		out[control] = vr and _holding_ctrl.get_float(source) \
			> float(INPUT_THRESHOLDS.get(source, 0.5))
	# A poke is an OR, not an override: pressing 1 on the shell while the bound
	# hand input is also down must not cancel it. The keyboard joins on the same
	# terms, so a desktop player and a poking hand cannot cancel each other either.
	for key: String in _face_buttons:
		if (_face_buttons[key] as VRButton).is_held():
			out[key] = true
	for key: String in _desktop_pressed():
		out[key] = true
	return out


## Pack the named controls into a libretro joypad mask.
##
## The two tables are NOT one with extras: attaching a Nunchuk moves 1/2 off X/Y
## onto START/SELECT and puts C/Z where they were, because that is how the core
## lays out descWiimoteNunchuk. Reading the wrong one silently swaps four buttons.
func _button_mask(pressed: Dictionary) -> int:
	var nc := device_type == RETRO_DEVICE_WIIMOTE_NC
	var bits: Dictionary = {
		"b":     ControllerBindings.JOYPAD_B,
		"a":     ControllerBindings.JOYPAD_A,
		"one":   ControllerBindings.JOYPAD_START if nc else ControllerBindings.JOYPAD_X,
		"two":   ControllerBindings.JOYPAD_SELECT if nc else ControllerBindings.JOYPAD_Y,
		"minus": ControllerBindings.JOYPAD_L if nc else ControllerBindings.JOYPAD_SELECT,
		"plus":  ControllerBindings.JOYPAD_R if nc else ControllerBindings.JOYPAD_START,
		"home":  ControllerBindings.JOYPAD_R3,
		"shake": ControllerBindings.JOYPAD_R2,
	}
	var mask := 0
	for key: String in bits:
		if pressed.get(key, false):
			mask |= 1 << int(bits[key])
	# The d-pad rides the holding hand's thumbstick — same read the rocker leans
	# on, so what the game sees and what the shell shows cannot drift apart.
	var stick := _dpad_stick()
	if stick.y >  DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_UP
	if stick.y < -DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_DOWN
	if stick.x < -DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_LEFT
	if stick.x >  DPAD_THRESHOLD: mask |= 1 << ControllerBindings.JOYPAD_RIGHT
	mask |= _desktop_dpad_mask()
	# Nunchuk: C and Z land on X/Y (freed by 1/2 moving), its shake on L2.
	if nc and _nunchuk != null:
		var nstate := _nunchuk.get_state()
		if nstate.get("c", false):
			mask |= 1 << ControllerBindings.JOYPAD_X
		if nstate.get("z", false):
			mask |= 1 << ControllerBindings.JOYPAD_Y
		if nstate.get("shake", false):
			mask |= 1 << ControllerBindings.JOYPAD_L2
	return mask


func _process(delta: float) -> void:
	_update_leds(delta)

	if _is_combo_pressed(_holding_ctrl):
		_drop_all()
		return

	# The shell moves whether or not it is paired — an unpaired remote still has
	# buttons you can press.
	var pressed := _pressed_now()
	_animate_controls(pressed)

	if _connected_system == null or _port_index < 0:
		return

	var libretro := _connected_system.get_libretro_node()
	if not is_instance_valid(libretro):
		return

	var nstick := Vector2.ZERO
	if device_type == RETRO_DEVICE_WIIMOTE_NC and _nunchuk != null:
		nstick = _nunchuk.get_state().get("stick", Vector2.ZERO) as Vector2

	# Right stick stays at zero on purpose: with a Nunchuk attached in pointer IR
	# mode the core binds the Tilt group to it, which would fight the real
	# accelerometer below.
	libretro.SetJoypadState(_port_index, _button_mask(pressed),
		int(nstick.x * ANALOG_SCALE), int(-nstick.y * ANALOG_SCALE), 0, 0)

	_update_aim(libretro)
	_send_accel(libretro, delta)


# ── Pointer (IR) ──────────────────────────────────────────────────────────────

## Where the remote's camera is and which way it is looking, as a transform with
## -Z forward.
##
## The barrel, whether or not anyone is holding it. A remote put down on the sofa
## still has a lens, and if it happens to be facing the set it really does still
## drive the cursor — that is a thing that happens in living rooms, and there is
## nothing to gain by pretending otherwise. Pointed anywhere else it sees no
## lights, which blanks the pointer on its own.
##
## The desktop is the exception: there the remote is snapped in front of the
## camera rather than held, so its own barrel says nothing about where the player
## is looking. The view aims instead — the same substitution the ray gun makes.
func _camera_pose() -> Transform3D:
	if _desktop_held:
		var cam := get_viewport().get_camera_3d()
		if is_instance_valid(cam):
			return cam.global_transform
	return _barrel_tip.global_transform


## Project a world point into the emulated IR camera. Returns (px, py, distance),
## with px/py in pixels on a 1024 x 768 sensor. A distance of zero means the
## camera cannot see it — behind the lens, or past the edge of the sensor.
##
## This is Dolphin's CameraLogic::GetCameraPoints, rewritten in Godot's frame. It
## has to be, exactly: the passthrough path takes sensor coordinates, and the game
## on the other side was calibrated against real hardware, so anything but the
## real optics puts the cursor in the wrong place by a fixed factor.
##
## Dolphin projects with Perspective(fov_y, fov_x/fov_y) — note the aspect is the
## ratio of the ANGLES, not of their tangents — and then maps clip space to pixels
## as (1 - ndc) * RES / 2 on both axes. Its pre-projection camera frame has +X
## LEFT and +Y DOWN, so composing that flip with the (1 - ndc) flip cancels both:
## in Godot's frame it comes out as (1 + ndc) * RES / 2 with ndc taken straight
## off +X right and +Y up. The upshot is the convention a real Wii camera has —
## an object to the RIGHT of the aim axis reads high in x, and one ABOVE it reads
## high in y, because the lens inverts the image and the hardware never undoes it.
func _project_to_camera(cam_inv: Transform3D, world_point: Vector3) -> Vector3:
	var v := cam_inv * world_point
	# Godot looks down -Z, so the forward distance is -z. Dolphin's own check is
	# the same one: a point behind the camera is no point at all.
	var w := -v.z
	if w <= 0.0:
		return Vector3.ZERO
	var px := (1.0 + (v.x / w) / _tan_half_fov.x) * 0.5 * CAMERA_RES_X
	var py := (1.0 + (v.y / w) / _tan_half_fov.y) * 0.5 * CAMERA_RES_Y
	if px < 0.0 or py < 0.0 or px >= CAMERA_RES_X or py >= CAMERA_RES_Y:
		return Vector3.ZERO
	return Vector3(px, py, w)


## Every lit LED in the room, in world space.
##
## Deliberately NOT scoped to the console this remote is paired with. A camera
## cannot tell whose lights it is looking at — it sees infrared, and the sensor
## bar is a dumb lamp with no identity to read. Two Wiis set up in one room really
## do confuse each other on real hardware, and this is where that comes from.
## Pairing decides which console HEARS the report, not what the camera can see.
##
## Only lit bars are here: an unplugged one, or one on a console nobody switched
## on, has no power and emits nothing. See SensorBar.is_lit.
func _visible_leds() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for node: Node in get_tree().get_nodes_in_group(SensorBar.BAR_GROUP):
		var bar := node as SensorBar
		if bar != null:
			out.append_array(bar.led_positions())
	return out


## Report every IR object as unseen. Dolphin skips any object whose size is zero,
## so an all-blank frame is a camera looking at nothing — which is what the Wii's
## own software reads as "the remote is pointed away", and is how the cursor gets
## hidden rather than clamped at the edge. The cursor path could never do that:
## it binds no Hide control, so pointing at the ceiling left the hand stuck to the
## border.
func _blank_ir(libretro: Libretro) -> void:
	for i in range(IR_OBJECTS):
		libretro.SetPointerIndexState(_port_index, i, 0, 0, false)
	_laser_dot.visible = false


func _update_aim(libretro: Libretro) -> void:
	var pose := _camera_pose()
	var leds := _visible_leds()
	if leds.is_empty():
		# Both real reasons look the same from the room — no bar in a socket, or a
		# console nobody switched on — so say so plainly.
		_log_aim("no sensor bar lit anywhere — plug one into a Wii and power up")
		_blank_ir(libretro)
		return

	var cam_inv := pose.affine_inverse()
	var points: Array[Vector3] = []
	for led: Vector3 in leds:
		var p := _project_to_camera(cam_inv, led)
		if p.z > 0.0:
			points.append(p)

	# More lights than slots is possible — two bars is four dots, and the camera
	# has four. Keep the NEAREST, because that is how the real sensor picks: it
	# tracks blobs by size, and a closer light is a bigger one.
	points.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.z < b.z)
	points.resize(mini(points.size(), IR_OBJECTS))
	# Then into slot order: descending x, which is what Dolphin's own camera
	# produces (its LED array starts at world -X, the end that lands HIGH in
	# sensor x). Sorted rather than taken from the scene, because the bar is a
	# pickable and a player can turn it round.
	points.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x > b.x)

	for i in range(IR_OBJECTS):
		var p: Vector3 = points[i] if i < points.size() else Vector3.ZERO
		# Normalised over the sensor, because the core's IRPassthrough group scales
		# a 0..1 control back up by (RES - 1). It reads the POSITIVE half of the
		# pointer range only, so 0 is the left/top edge and 32767 the right/bottom.
		libretro.SetPointerIndexState(_port_index, i,
			int(p.x / (CAMERA_RES_X - 1.0) * POINTER_SCALE),
			int(p.y / (CAMERA_RES_Y - 1.0) * POINTER_SCALE),
			p.z > 0.0)

	_log_aim("%d of %d lit LEDs in view" % [points.size(), leds.size()])
	if not points.is_empty():
		_log_aim_points(points)
	_update_laser_dot(pose)


## The dot on the glass. Purely a courtesy now — the aim above never touches the
## screen — but it is the only feedback saying where the barrel is pointed, and on
## the desktop it is the only way to see the aim at all.
func _update_laser_dot(pose: Transform3D) -> void:
	if not show_laser_dot:
		_laser_dot.visible = false
		return
	# Look again if we have no glass, or the set we had went away (unplugged,
	# swapped, deleted). Cheap: two null checks on the frames it succeeds.
	if not is_instance_valid(_screen_mesh):
		_screen_mesh = null
		_cache_screen_geometry()
	if _screen_mesh == null or _screen_w == 0.0:
		_laser_dot.visible = false
		return

	var screen_transform := _screen_mesh.global_transform
	var screen_normal := screen_transform.basis.z.normalized()
	var plane := Plane(screen_normal, screen_transform.origin)
	var hit: Variant = plane.intersects_ray(pose.origin, -pose.basis.z)
	if hit == null:
		_laser_dot.visible = false
		return

	var local: Vector3 = screen_transform.affine_inverse() * (hit as Vector3)
	var u := (local.x / _screen_w) + 0.5
	var v := (-local.y / _screen_h) + 0.5
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_laser_dot.visible = false
		return
	_laser_dot.visible = true
	_laser_dot.global_position = (hit as Vector3) + screen_normal * 0.002


# ── Accelerometer ─────────────────────────────────────────────────────────────

## Derive what the remote's accelerometer would read and hand it to the core in g.
##
## Gyro is deliberately absent. The frontend rejects RETRO_SENSOR_GYROSCOPE_ENABLE
## today, and that is load-bearing rather than an oversight: Dolphin's IMU cursor
## composes its rotation on TOP of the Point group's, so a remote that reported
## gyro would have its aim counted twice. Dynamics.cpp bails out of that path
## entirely while the gyro is unbound, which is what keeps the pointer honest.
func _send_accel(libretro: Libretro, delta: float) -> void:
	if delta <= 0.0:
		return

	# Proper acceleration is what an accelerometer measures: motion MINUS gravity,
	# so a remote at rest reads +1g upward rather than nothing.
	var velocity := linear_velocity
	var a_world := (velocity - _prev_velocity) / delta + Vector3.UP * G
	_prev_velocity = velocity
	_accel_smoothed = _accel_smoothed.lerp(a_world, ACCEL_SMOOTHING)

	var g_vec := accel_in_wiimote_frame()
	libretro.SetSensorAccel(_port_index, g_vec.x, g_vec.y, g_vec.z)


## The smoothed world acceleration expressed on the emulated remote's own axes,
## in g. Split out from _send_accel because this is where the whole thing can go
## quietly wrong: it is two coordinate changes in a row and nothing downstream
## complains about a wrong one, the game just tilts the wrong way.
##
## Godot has -Z forward, +Y up, +X right. Dolphin's remote has +X LEFT, +Y BACK,
## +Z UP (IMUAccelerometer::GetState, which reads x as Left-Right, y as
## Backward-Forward, z as Up-Down). Level and pointing forward at rest that gives
## (0, 0, 1) — the same at-rest reading the GDExtension returns when nothing is
## driving the sensor at all.
func accel_in_wiimote_frame() -> Vector3:
	var local := _barrel_tip.global_transform.basis.inverse() * (_accel_smoothed / G)
	return Vector3(-local.x, local.z, local.y)
