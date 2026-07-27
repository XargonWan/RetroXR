## RetroSystemModel — base class for system-specific console visual models.
##
## Subclasses load the appropriate GLB for their hardware and override the
## virtual methods below.  All overrides are optional stubs today; they will
## grow as physical animations, power lights, and port visuals are added.
class_name RetroSystemModel
extends Node3D


## Called when the system is powered on (e.g. light up power LED, play boot animation).
func on_power_on() -> void:
	if _power_slider != null:
		_power_slider.set_value_no_signal(1.0)


## Called when the system is powered off (e.g. extinguish power LED).
func on_power_off() -> void:
	if _power_slider != null:
		_power_slider.set_value_no_signal(0.0)


# --- power SLIDE switches ----------------------------------------------------
#
# Several consoles power on with a slide, not a push: the Genesis rocker travels
# left to ON, the N64's slides up. Driving those from the cabinet's generic
# VRButton made them sink into the case like a button, which is the wrong motion
# and hides the ON/OFF legend the shell prints either side of the cap.
#
# build_power_slider() replaces the button with a VRSlider mounted ON the shell's
# real cap, so the thing you grab is the thing that moves, and the two detents
# map to off/on. Subclasses that override on_power_on/on_power_off must call
# super() so an externally-driven power change (a save restore, a multiplayer
# event, the cartridge being pulled) still moves the switch.
var _power_slider: VRSlider = null


## Mount a two-detent power slider on `cap` and hide the generic push button.
## `axis` is the travel direction toward ON, in this model's local space;
## `throw` is the total travel in metres.
func build_power_slider(power_btn: VRButton, cap: MeshInstance3D,
		axis: Vector3, throw: float) -> VRSlider:
	if cap == null:
		return null
	if power_btn != null:
		power_btn.visible = false
		power_btn.set_deferred("monitoring", false)
	var slider := VRSlider.new()
	slider.name = "PowerSwitch"
	slider.axis_local = axis.normalized()
	slider.travel = throw
	slider.steps = 2
	slider.collision_layer = 1 | (1 << 20)
	var ab: AABB = cap.global_transform * cap.get_aabb()
	slider.engage_radius = clampf(maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) * 0.9, 0.02, 0.05)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = ab.size + Vector3(0.006, 0.006, 0.006)
	col.shape = box
	slider.add_child(col)
	add_child(slider)                     # _ready() runs here, before adopting
	slider.global_position = ab.get_center()
	slider.set_knob_mesh(cap)
	slider.value_changed.connect(_on_power_slider_changed)
	_power_slider = slider
	return slider


func _on_power_slider_changed(v: float) -> void:
	var host := get_parent()
	if host == null or not host.has_method("toggle_power"):
		return
	if (v > 0.5) != bool(host.get("is_powered_on")):
		host.toggle_power()


## Play the cartridge/disc tray open animation (if supported).
func play_open() -> void:
	pass


## Play the cartridge/disc tray close animation (if supported).
func play_close() -> void:
	pass


## True when this model's lid is a spring-loaded VRSpringLatchedHinge: the OPEN
## button only ever OPENS it (pressing it again while open does nothing — as on
## the real hardware, where the button is a latch release), and the lid is shut
## by hand, which reports back through RetroSystem.request_tray_state().
func has_spring_latched_lid() -> bool:
	return false


## Returns the number of controller ports active on this hardware.
## The base system scene has 4 snap zones; ports beyond this count are hidden.
func get_controller_port_count() -> int:
	return 2


## True when this hardware saves to removable memory cards (CD-era consoles).
## Enables the MemoryCardSlot snap zone; cartridge systems keep saves on the
## cartridge itself and return false.
func uses_memory_cards() -> bool:
	return false


## True for handheld hardware (Game Boy family): the device has a built-in
## screen, is played while held, and its VR-controller input drives port 0.
func is_handheld() -> bool:
	return false


## The device's built-in display mesh (handhelds), or null. When no TV is
## connected the core renders here; plugging the video-out cable into a TV
## moves the picture there and unplugging brings it back.
func get_builtin_screen() -> MeshInstance3D:
	return null


## True if the core outputs a side-by-side stereo frame (left eye | right eye),
## i.e. the Virtual Boy. A connected TV then splits it per-eye like the eyepiece.
func is_stereo_side_by_side() -> bool:
	return false


## Video-out channels this hardware exposes. Single-output hardware (default)
## has one unlabelled channel showing the whole core frame, handled by the
## classic path (the C++ VideoHandler renders straight onto the connected TV).
## Multi-channel hardware (dual-screen handhelds) gets one cable PER channel;
## each connected TV then shows that channel's UV window of the composite
## framebuffer via the screen_window shader. Entry keys:
##   label     String  cable/port tag ("TOP"/"BOTTOM"); "" on single-channel
##   rect      Rect2   UV window into the composite framebuffer
##   touch     bool    taps on a TV showing this channel feed the touch screen
##   eye_shift float   right-eye UV-x shift for stereo SBS sources (0 = mono)
func get_video_channels() -> Array:
	return [{"label": "", "rect": Rect2(0, 0, 1, 1), "touch": false, "eye_shift": 0.0}]


## Handhelds normally hide the cabinet START/STOP button (they carry their own
## power switch). Dual-screen clamshells override this to keep the button —
## their hinge swallows the tiny back-edge knob, so a proper labelled button
## repositioned by configure_buttons() is the discoverable way to power them.
func has_start_stop_button() -> bool:
	return not is_handheld()


## Whether the cabinet's generic OPEN/EJECT button should appear on a system that
## has a disc loader. Override to false when the shell models its own release
## control and mounts a widget on it (the PSP's sprung OPEN latch), so the two
## don't both claim the same job — and the same mesh.
func has_eject_button() -> bool:
	return true


## Hide the generic grey port box and its number on every controller port.
##
## system.tscn ships those as stand-ins for the procedural default shell, which
## has no port geometry of its own. Any console whose GLB moulds real ports wants
## them gone — otherwise a grey cube and a floating "1" sit on top of the moulded
## socket. Call from configure_controller_ports.
static func hide_port_placeholders(port_zones: Array) -> void:
	for z: Node in port_zones:
		var recess := z.get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := z.get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()


## Handhelds: create and wire the on-device controls (volume slider, power
## switch) against the owning RetroSystem. Called after the model loads.
func configure_handheld_controls(host: Node3D) -> void:
	pass


## Interior open angle of a clamshell handheld's lid in degrees (0 = folded
## shut … 180 = flat open), or -1 for hardware without a lid. Read by
## ScenePersistence to save the lid pose; the -1 sentinel is the same
## "capability absent" convention as get_builtin_screen() → null.
func get_lid_angle_deg() -> float:
	return -1.0


## Restore a clamshell lid's interior open angle (0 shut … 180 flat). Hardware
## without a lid ignores it.
func set_lid_angle_deg(_open_deg: float) -> void:
	pass


## Reposition the memory-card snap zone to the model's physical card slot.
func configure_memory_card_slot(slot: Node3D) -> void:
	pass


## Core options this hardware REQUIRES (key -> value), merged into the core's
## .opt file before every content start. Used when a model only works with a
## specific core configuration (e.g. Virtual Boy forces vb_3dmode =
## side-by-side so the stereo eyepiece shader gets both eyes).
func get_forced_core_options() -> Dictionary:
	return {}


## Show or hide the controller plug port visuals for a given port index.
## Called by RetroSystem when a controller is plugged in or removed.
func set_controller_port_occupied(port_index: int, occupied: bool) -> void:
	pass


## World point where a shell's bundled A/V plug prop's lead leaves it: the far end
## of the plug mesh along the console's BACK (-Z), on the plug's own axis.
##
## The imported shells model the A/V lead already plugged in, so those plug props are
## SHOWN (they are the visible connector the spawned rope hangs off — without them
## the cable sprouts from thin air a few cm behind the console). The rope therefore
## has to start at the plug's TIP: anchored at the socket instead it would run
## straight back through the plug. `fallback` covers a shell with no plug prop.
func av_plug_cable_end(plug: Node3D, fallback: Vector3) -> Vector3:
	var mi := plug as MeshInstance3D
	if mi == null or mi.mesh == null or not mi.visible:
		return fallback
	var ab: AABB = mi.global_transform * mi.get_aabb()
	var c := ab.get_center()
	return Vector3(c.x, c.y, ab.position.z)


## Show or hide the video/cable output port visual.
## Called by RetroSystem when a cable is connected or disconnected.
func set_cable_port_occupied(occupied: bool) -> void:
	pass


## Animate a cartridge into its slot.  Called after XRTools has snapped and
## frozen the cartridge at the slot position.  Subclasses unfreeze, tween from
## a system-specific start offset to the final position, then refreeze.
func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	pass


## Reposition the system's existing VRButton nodes to match the model's physical
## button locations and wire them to the GLB button meshes for depress animation.
## The existing signal connections to toggle_power/reset/eject are preserved — only
## the position and mesh reference are updated. eject_btn is the OPEN/eject button
## (disc consoles); models without a disc button ignore it.
func configure_buttons(_power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	pass


## Reposition controller port snap zones to the model's physical port locations.
## port_zones is the system's Array of XRToolsSnapZone nodes (index 0 = port 1).
## Only move the zones the model has markers for; others keep their default positions.
func configure_controller_ports(port_zones: Array) -> void:
	pass


## Reposition the cable attach point to the model's physical video-out port.
func configure_cable_attach(attach_point: Node3D) -> void:
	pass


## Reposition the attach point for video-out channel `channel` (multi-output
## hardware). Channel 0 defaults to the classic single-port hook above; extra
## channels get a small sideways offset unless the model places them itself.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	if channel == 0:
		configure_cable_attach(attach_point)
	else:
		configure_cable_attach(attach_point)
		attach_point.position += Vector3(-0.04 * channel, 0, 0)


## World-space offset from the video-out attach point where channel `channel`'s
## cable plug first spawns — i.e. which way the rope initially trails out of the
## console. Default trails it out the back (-Z); models whose port faces another
## way override this (the NES's captive AV lead exits the right/+X side).
func get_cable_spawn_offset(channel: int) -> Vector3:
	return Vector3(0.05 * channel, 0, -0.1)


## Adjust the root collision shape to fit this model. Custom non-handheld models
## whose geometry doesn't match the default console box (e.g. the tall Virtual
## Boy standing on its bipod) override this so the body rests on the ground
## instead of floating. Default: leave the scene's collision box unchanged.
## (Handhelds resize collision separately via configure_handheld_body.)
func configure_collision(host: Node3D) -> void:
	pass


## Optional pivot node the seated disc should physically ride along with,
## instead of staying fixed to the console body (see MediaTray.disc_lid_pivot)
## — a flip-open tray assembly (the PSP's UMD door) where the disc's resting
## slot is part of the door itself, unlike a spindle console (PS1, GameCube...)
## where the disc rests on the BASE and only the lid mesh swings. Null
## (default): disc stays in its normal fixed seat.
func get_disc_lid_pivot() -> Node3D:
	return null


## Reposition the cartridge snap zone to the model's physical slot location.
## Also returns the insertion offset — the vector the cartridge travels from its
## pre-animation position to the snapped position (in world space).
## Default: 6 cm straight up (+Y), i.e. cartridge drops straight down into slot.
func configure_cartridge_slot(slot: Node3D) -> void:
	pass


## The world-space direction a cartridge travels when being inserted.
## Returned as a unit vector; the animation moves FROM final_pos - dir*depth TO final_pos.
func get_cartridge_insert_direction() -> Vector3:
	return Vector3.UP


## Play the reset animation (e.g. depress the reset button, reboot LED flash).
## Called by RetroSystem.reset() independently of the power on/off hooks.
func play_reset() -> void:
	pass


## Animate a cartridge ejecting from its slot before it is dropped.
## NOTE: by the time has_dropped fires the cartridge is already released, so
## this is reserved for future use (e.g. intercepting the drop earlier).
func play_cartridge_eject(cartridge: Node3D, _slot: Node3D) -> void:
	pass
