## RetroSystemModelPCTower — a beige 90s mini-tower PC, the ScummVM "console".
##
## Primitive geometry authored in pc_tower.tscn, deliberately: this exists first to
## prove the SLIDING optical tray, and a box tower takes primitives well (a painted
## steel case is flat panels and square corners, the same reasoning the room's desk
## and wardrobe use). A detailed shell can replace the geometry later without
## touching any of the wiring here.
##
## The tray is the point. Every other disc system in RetroXR is a lidded well —
## MediaTray swings `lid_pivot` about its local X and the disc either stays on the
## spindle or rides a flip-open door. A PC CD-ROM does neither: the tray TRANSLATES
## out of the bay, carrying the disc with it.
##
## That needs no change to MediaTray, because RetroSystem hands lid animation to
## bespoke models via play_open/play_close and only asks the model for
## get_disc_lid_pivot() so the seated disc can be reparented to the moving part.
## So MediaTray keeps owning the gating, seating, spin and collision, and this
## script owns the motion — which happens to be a slide.
class_name RetroSystemModelPCTower
extends RetroSystemModel


## How far the tray travels out of the bay, along the tower's local +Z (the front).
##
## 145 mm, not 135: at 135 the disc's REAR edge still sat 15 mm inside the case
## front once the tray was out, so a disc laid on the tray clipped through the
## bezel. It now clears by 9.5 mm.
@export var tray_travel: float = 0.145
@export var tray_time: float = 0.9

@onready var _tray_pivot: Node3D = $TrayPivot
@onready var _led: MeshInstance3D = $Front/PowerLed
@onready var _drive_led: MeshInstance3D = $Front/DriveLed

var _tray_rest: Vector3 = Vector3.ZERO
var _tray_tween: Tween = null


func _ready() -> void:
	_tray_rest = _tray_pivot.position
	_set_led(_led, false, Color(0.25, 0.85, 0.35))
	_set_led(_drive_led, false, Color(1.0, 0.7, 0.2))


# --- ports ------------------------------------------------------------------

func configure_controller_ports(port_zones: Array) -> void:
	# Authored PortSeat markers win over any computed pose — the same
	# "authored beats computed" idiom as DiscSeat.
	for i in range(port_zones.size()):
		var zone := port_zones[i] as Node3D
		if zone == null:
			continue
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
	# system.tscn's grey port box and floating number are stand-ins for the default
	# procedural shell. This tower moulds its own colour-coded sockets, so leaving
	# them on would park a grey cube and a "1" over the purple one.
	hide_port_placeholders(port_zones)


# --- the sliding tray -------------------------------------------------------

## Where a seated disc should be parented so it rides out with the tray.
func get_disc_lid_pivot() -> Node3D:
	return _tray_pivot


func play_open() -> void:
	_slide_to(_tray_rest + Vector3(0.0, 0.0, tray_travel))


func play_close() -> void:
	_slide_to(_tray_rest)


func _slide_to(target: Vector3) -> void:
	if _tray_tween != null and _tray_tween.is_valid():
		_tray_tween.kill()
	# Real trays ease out and thump home rather than moving linearly.
	_tray_tween = create_tween()
	_tray_tween.tween_property(_tray_pivot, "position", target, tray_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# --- hardware description ---------------------------------------------------

## A PC takes keyboard and mouse rather than joypads, but RetroSystem's ports are
## how any input reaches the core, so two are kept.
##
## They stay ORDINARY controller ports: RetroKeyboard and RetroMouse already
## implement the port contract (on_plugged_in / on_unplugged) and spawn the same
## cable a gamepad does. Only the socket geometry and its PC99 colour coding —
## purple keyboard, green mouse, matching the plug meshes — say otherwise.
func get_controller_port_count() -> int:
	return 2


## Saves live on the hard disk, not a removable card.
func uses_memory_cards() -> bool:
	return false


func is_handheld() -> bool:
	return false


# POWER on the front bezel; the tray's own EJECT button beside the bay. No reset —
# a 90s tower's reset was a recessed pinhole, not something to press in VR.
#
# Both sit in the bezel and so travel INTO it, along the tower's -Z. VRButton
# defaults to -Y, which is right for a button on a top face and wrong for one
# facing you: it sinks the cap down through the bezel instead of into it. The
# axis is set in local space rather than from global_transform — every frame
# between these buttons and the model is identity, and a local write does not
# care whether the tower has been placed in the room yet.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	if power_btn != null:
		power_btn.position = $Front/PowerButtonAnchor.position
		power_btn.depress_depth = 0.003
		power_btn.depress_axis = Vector3(0, 0, -1)
		var pl := power_btn.get_node_or_null("ButtonLabel") as Label3D
		if pl != null:
			pl.hide()
	if eject_btn != null:
		eject_btn.position = $Front/EjectButtonAnchor.position
		eject_btn.depress_depth = 0.003
		eject_btn.depress_axis = Vector3(0, 0, -1)
		var el := eject_btn.get_node_or_null("ButtonLabel") as Label3D
		if el != null:
			el.hide()
	if reset_btn != null:
		reset_btn.set_active(false)


## The disc seats in the tray's well. Its pose is read back by RetroSystem and
## re-expressed relative to get_disc_lid_pivot(), so this must be positioned with
## the tray at its REST pose — which it is, since _ready has not moved it.
##
## DiscSeat's position is local to TrayPivot, NOT to the model root, and `slot`
## lives in the model root's frame. Assigning it raw put the well at the tower's
## base 6 mm under the floor — 36 cm from the tray — so a disc had nothing to snap
## to however far the tray slid out. Compose the pivot's own transform in.
func configure_cartridge_slot(slot: Node3D) -> void:
	var pivot: Node3D = $TrayPivot
	slot.position = pivot.transform * (pivot.get_node("DiscSeat") as Node3D).position
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## Ports onto the BACK panel, where a PC's keyboard and mouse actually plug in.
## Left at their defaults they sat at the tower's base and dipped 6 mm below the
## floor, since the default layout assumes a console lying flat.
## Safe to read the marker's position raw, unlike DiscSeat above: Front and Back
## are bare Node3Ds at the model root, so their children's local positions ARE
## model-root-relative. Give either of them a transform and this silently breaks.
func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.position = $Back/AvAnchor.position
	var v := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if v != null:
		v.visible = false


func configure_collision(host: Node3D) -> void:
	# The case only. The tray is excluded on purpose: it moves, and a collider
	# that slides out of the body would shove whatever is in front of the tower.
	var box := Vector3(0.19, 0.42, 0.44)
	var pos := Vector3(0.0, 0.21, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


func on_power_on() -> void:
	_set_led(_led, true, Color(0.25, 0.85, 0.35))
	_set_led(_drive_led, true, Color(1.0, 0.7, 0.2))


func on_power_off() -> void:
	_set_led(_led, false, Color(0.25, 0.85, 0.35))
	_set_led(_drive_led, false, Color(1.0, 0.7, 0.2))


func _set_led(led: MeshInstance3D, on: bool, tint: Color) -> void:
	if led == null:
		return
	var mat := led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null or not mat.resource_local_to_scene:
		mat = StandardMaterial3D.new()
		mat.resource_local_to_scene = true
		led.set_surface_override_material(0, mat)
	mat.albedo_color = tint if on else tint.darkened(0.78)
	mat.emission_enabled = on
	mat.emission = tint
	mat.emission_energy_multiplier = 2.2 if on else 0.0
