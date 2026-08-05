## RetroSystemModelAtari2600 — the six-switch Atari 2600 VCS ("heavy sixer").
##
## Wires POWER and GAME RESET. Both are SLIDE switches, not buttons: thin levers
## that travel up and down the console's 42.5-degree control panel. Driving them
## with the cabinet's generic VRButton sank them into the shell, which is the
## wrong motion and buries the ON/OFF legend printed beside each slot.
##
## The two behave differently on the real hardware and here:
##   POWER  latches. Two detents, and it stays where you put it — VRSlider with
##          steps = 2, via the base class's build_power_slider.
##   RESET  is momentary. Push it and it springs back the instant you let go —
##          VRSpringReturnSlider, firing on the push rather than on a dwell.
## The other four switches (TV Type, Left/Right Difficulty, Game Select) are
## modelled and individually pivoted in the shell but not yet wired.
##
## No eject: 2600 carts pull straight out of the top slot.
class_name RetroSystemModelAtari2600
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/consoles/atari_2600/atari_2600_console.glb"

## Travel direction toward ON, in this model's local space: up the control panel.
##
## The panel is not horizontal — its normal measures (0, -0.676, 0.737), a 42.5
## degree slope — so "up the panel" is part up and part backwards, not a flat -Z.
## The console's front faces +Z, hence the negative Z term.
const _AXIS_ON := Vector3(0.0, 0.676, -0.737)

## Total switch travel. Measured off the asset rather than guessed: the artist
## modelled Left Difficulty and Game Select thrown down and the other four up,
## and the gap between those two groups is the throw the shell was drawn with.
## 7.07 mm as authored, x0.7881 once the shell is normalised to real-world size.
const _SWITCH_THROW := 0.005572

var _glb: Node3D = null
var _reset_slider: VRSpringReturnSlider = null


func _ready() -> void:
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("Atari2600Model: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("Atari2600Model: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		# MUST be "Shell" — that is what has_baked_shell() looks for, and it is how
		# the cabinet knows this console carries its own printed legends and should
		# not get a SystemNameLabel laid across its front.
		_glb.name = "Shell"
		add_child(_glb)

	# The GLB is already exported centred on its footprint and resting on y = 0,
	# so this is normally a no-op; it stays as a guard for a re-export that is not.
	if baked == null:
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


func get_controller_port_count() -> int:
	return 2


func uses_memory_cards() -> bool:
	return false


# --- switches -------------------------------------------------------------------

func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	if eject_btn != null:
		eject_btn.visible = false
		eject_btn.set_deferred("monitoring", false)
	if _glb == null:
		return
	_setup_power(power_btn)
	_setup_reset(reset_btn)


## POWER: a latching two-detent slider mounted on the shell's own lever.
func _setup_power(power_btn: VRButton) -> void:
	var cap := _glb.find_child("Switch_Power", true, false) as MeshInstance3D
	if cap == null:
		push_warning("Atari2600Model: Switch_Power missing from the shell")
		return
	var slider := build_power_slider(power_btn, cap, _AXIS_ON, _SWITCH_THROW)
	if slider == null:
		return

	# Re-anchor the modelled pose at value 1 rather than 0.
	#
	# Every switch ships in the UP position, and up IS on — the shell prints "on"
	# above "off". build_power_slider anchors whatever pose it adopts at value 0,
	# which would read a visibly-on console as off and then drive the lever FURTHER
	# up when switched on. `value` is a plain export with no setter, so assigning it
	# moves nothing; re-adopting the cap then pins the same unmoved pose to value 1.
	slider.value = 1.0
	slider.set_knob_mesh(cap)

	# Start from what the cabinet actually thinks, so a system restored powered-on
	# does not show its switch off. Read defensively: a host without the property
	# returns null, and bool(null) is not a valid conversion here.
	var host := get_parent()
	var powered: Variant = host.get("is_powered_on") if host != null else null
	slider.set_value_no_signal(1.0 if powered is bool and powered else 0.0)


## GAME RESET: momentary. Travels the same slot the opposite way and springs back.
func _setup_reset(reset_btn: VRButton) -> void:
	var cap := _glb.find_child("Switch_GameReset", true, false) as MeshInstance3D
	if cap == null:
		push_warning("Atari2600Model: Switch_GameReset missing from the shell")
		return
	if reset_btn != null:
		reset_btn.visible = false
		reset_btn.set_deferred("monitoring", false)

	var slider := VRSpringReturnSlider.new()
	slider.name = "ResetSwitch"
	# Pushed is DOWN the panel, so the travel axis is the reverse of power's. The
	# lever is modelled at rest (up), which is value 0 — exactly where the spring
	# returns it to, so the default anchor is already right and needs no fixup.
	slider.axis_local = (-_AXIS_ON).normalized()
	slider.travel = _SWITCH_THROW
	# Detents would snap the spring-back instead of letting it travel (see
	# VRSpringReturnSlider). A dwell is wrong too: Game Reset acts on the push.
	slider.steps = 0
	slider.on_hold_sec = 0.0
	slider.off_hold_sec = 0.0
	slider.collision_layer = 1 | (1 << 20)

	var ab: AABB = cap.global_transform * cap.get_aabb()
	slider.engage_radius = clampf(maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) * 0.9, 0.02, 0.05)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = ab.size + Vector3(0.006, 0.006, 0.006)
	col.shape = box
	slider.add_child(col)
	add_child(slider)                    # _ready() runs here, before adopting
	slider.global_position = ab.get_center()
	slider.set_knob_mesh(cap)
	slider.toggle_requested.connect(_on_reset_thrown)
	_reset_slider = slider


func _on_reset_thrown() -> void:
	var host := get_parent()
	if host != null and host.has_method("reset"):
		host.reset()


# --- cartridge -------------------------------------------------------------------

## Where a seated cartridge sits, in this model's local space.
##
## Taken from the cart the artist already seated in the slot (the Adventure one),
## read off its own placement rather than hand-written — the slot is raked 42
## degrees, which no eyeballed transform would reproduce.
##
## Anchored on the SLOT MOUTH — where the cart's axis crosses the outer face of
## the control panel, measured off the shell (panel surface sits 19.5 mm below
## the point the artist's cart reached).
##
## Deliberately NOT the artist's own placement. Their Adventure cart sits 75 mm
## into the slot with only 19.5 mm showing — 79% buried, with 49 mm of clearance
## still under it, so nothing was forcing that depth. A real 2600 cartridge goes
## in about its bottom quarter and stands proud; copying the render pose put the
## cart most of the way inside the console.
const _CART_MOUTH := Vector3(-0.00005, 0.08951, -0.01817)

## How far the cart travels past the slot mouth once seated.
## Placed by hand in Tools/cart_seat_probe.tscn: 42.2 mm in, 52.8 mm proud of a
## 95 mm cart. Derived guesses kept landing wrong — the artist's own pose buries
## it 79%, and reasoning from real hardware gave 25 mm, which sat too high.
const _CART_INSERT_DEPTH := 0.04220
const _CART_SEAT_X := Vector3(-1.00000, 0.00000, 0.00000)
const _CART_SEAT_Y := Vector3(0.00000, 0.73610, 0.67688)   # connector -> top
const _CART_SEAT_Z := Vector3(0.00000, 0.67688, -0.73610)  # label normal

## Height-to-width ratio of the assembled cartridge, measured in-engine
## (79.0 x 95.0 mm). Matches the GLB's own 1.202 to three decimals, which is the
## check that matters: the cart GLB must export with its rotation baked into the
## vertex data. Leave it on the node transforms and RetroCartridge sizes the cart
## from the bounding box of a ROTATED box, over-measures it, and the cart comes
## out short and thin.
const _CART_ASPECT := 1.2023

var _cartridge_slot: Node3D = null


## Height a seated cartridge ends up with once the runtime has scaled the model
## down to MediaDimensions. This shell is width-bound under that fit rule.
func _seated_cart_height() -> float:
	return MediaDimensions.cart_size("atari_2600").x * _CART_ASPECT


func cart_seat_transform() -> Transform3D:
	# The snap zone poses the cart by its centre: from the mouth, push in by the
	# insert depth and back out by half the cart's height.
	var origin: Vector3 = _CART_MOUTH \
		+ _CART_SEAT_Y * (_seated_cart_height() * 0.5 - _CART_INSERT_DEPTH)
	return Transform3D(Basis(_CART_SEAT_X, _CART_SEAT_Y, _CART_SEAT_Z), origin)


func configure_cartridge_slot(slot: Node3D) -> void:
	_cartridge_slot = slot
	# An authored CartSeat marker still wins, same idiom as the other consoles.
	var seat := find_child("CartSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform
	else:
		slot.transform = cart_seat_transform()
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual:
		slot_visual.hide()


## Down the slot, along the seated cart's own -Y (connector first).
func get_cartridge_insert_direction() -> Vector3:
	return (global_transform.basis * -_CART_SEAT_Y).normalized()


# --- controller ports -------------------------------------------------------------

## The two joystick ports on the rear panel.
##
## Placed by hand in Tools/cart_seat_probe.tscn (--mode=port). The D-sub sockets
## are moulded into the shell rather than being separate meshes, so nothing in
## the geometry names them — locating them by mesh name, by vertex clustering and
## by thresholding an orthographic render all failed.
##
## This is the PLUG's pose, not the snap zone's. XRTools aligns a plug's
## SnapGrabPoint to the zone, and that grab point carries its own 180-degree flip
## about X (controller_cable.tscn), so the zone is this composed with the flip.
## The sockets are NOT symmetric about the centreline — they sit at -109 mm and
## +79 mm, 30 mm apart in magnitude. Placed independently for that reason, and
## confirmed twice: thresholding an orthographic rear render put them at -0.1091
## and +0.0783, within 0.2 mm of both hand placements.
## Port 1 is the LEFT socket as the player faces the console's front (+Z), which
## is -X. The two are listed in port order, not in X order.
const _PORT_POS := [
	Vector3(-0.10907, 0.07007, -0.09521),   # port 1 — left
	Vector3(0.07854, 0.07007, -0.09521),    # port 2 — right
]
## Rearward tilt, matching the sloped upper rear face the sockets sit in.
const _PORT_PITCH_DEG := 17.499

## The grab point's own flip, which the zone has to undo.
const _GRAB_FLIP := PI


func configure_controller_ports(port_zones: Array) -> void:
	var basis := Basis.from_euler(Vector3(deg_to_rad(_PORT_PITCH_DEG), 0.0, 0.0)) \
		* Basis(Vector3.RIGHT, _GRAB_FLIP)
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		# An authored PortSeat marker still wins, same idiom as CartSeat.
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		elif i < _PORT_POS.size():
			zone.transform = Transform3D(basis, _PORT_POS[i])
	hide_port_placeholders(port_zones)


## Where each controller plug should sit once seated — the pose that was actually
## placed, before the grab-point flip. Used by the probe and by validation.
func port_plug_transform(index: int) -> Transform3D:
	var i: int = clampi(index, 0, _PORT_POS.size() - 1)
	return Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(_PORT_PITCH_DEG), 0.0, 0.0)),
		_PORT_POS[i])


# --- A/V lead ---------------------------------------------------------------------

## The yellow composite VIDEO jack on the rear panel, measured off the shell.
##
## The three RCA jacks sit in a row 25 mm up the back at 12.5 mm spacing —
## right audio at -X, left audio centred, video at +X. Only the video one is
## wired: RetroXR carries composite video and audio down the single A/V lead.
const _JACK_VIDEO := Vector3(0.01253, 0.02228, -0.10838)


func configure_cable_attach(attach_point: Node3D) -> void:
	attach_point.position = _JACK_VIDEO
	# Identity is already right here, unlike the NES's flank-mounted jacks. The
	# rear panel faces -Z and VerletRope leaves the attach point along its local
	# -Z, so the cord trails straight out the back and the plug's +Z connector
	# points into the jack.
	attach_point.rotation = Vector3.ZERO
	# PortVisual is deliberately left visible — it is the RCA plug seated in the
	# jack, not a placeholder.


# --- placement -------------------------------------------------------------------

## Rest the console on whatever it is placed on. Sized to the measured shell:
## 0.333 x 0.088 x 0.223 m, which sits on y = 0 — a real heavy sixer is about
## 0.337 x 0.095 x 0.222 m.
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.334, 0.089, 0.224)
	var pos := Vector3(0.0, 0.0441, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
