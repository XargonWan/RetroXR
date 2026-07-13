## RetroSystemModel — base class for system-specific console visual models.
##
## Subclasses load the appropriate GLB for their hardware and override the
## virtual methods below.  All overrides are optional stubs today; they will
## grow as physical animations, power lights, and port visuals are added.
class_name RetroSystemModel
extends Node3D


## Called when the system is powered on (e.g. light up power LED, play boot animation).
func on_power_on() -> void:
	pass


## Called when the system is powered off (e.g. extinguish power LED).
func on_power_off() -> void:
	pass


## Play the cartridge/disc tray open animation (if supported).
func play_open() -> void:
	pass


## Play the cartridge/disc tray close animation (if supported).
func play_close() -> void:
	pass


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


## Handhelds: create and wire the on-device controls (volume slider, power
## switch) against the owning RetroSystem. Called after the model loads.
func configure_handheld_controls(host: Node3D) -> void:
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
## The existing signal connections to toggle_power/reset are preserved — only the
## position and mesh reference are updated.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton) -> void:
	pass


## Reposition controller port snap zones to the model's physical port locations.
## port_zones is the system's Array of XRToolsSnapZone nodes (index 0 = port 1).
## Only move the zones the model has markers for; others keep their default positions.
func configure_controller_ports(port_zones: Array) -> void:
	pass


## Reposition the cable attach point to the model's physical video-out port.
func configure_cable_attach(attach_point: Node3D) -> void:
	pass


## Adjust the root collision shape to fit this model. Custom non-handheld models
## whose geometry doesn't match the default console box (e.g. the tall Virtual
## Boy standing on its bipod) override this so the body rests on the ground
## instead of floating. Default: leave the scene's collision box unchanged.
## (Handhelds resize collision separately via configure_handheld_body.)
func configure_collision(host: Node3D) -> void:
	pass


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
