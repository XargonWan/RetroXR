## RetroSystemModelPlaystationOriginal — the full-size grey PlayStation
## (SCPH-100x), the "playstation:original" variant. The PSone stays the default.
##
## Subclasses the PSone model: the lid rig (LidMount/LidPivot + VRHinge), the
## hand-swing → tray sync, the disc seat and the swing tween are all shared, and
## only the shell description and the front-panel placements differ.
##
## This shell (imported's "PSX imported (Mod)") is in much better shape than the PSone
## GLB — POWER, RESET and OPEN are three separate meshes with their own
## "Finger Button *" markers, the lid has a "DeckelPSX" hinge marker, and the
## power LED is its own mesh. So almost nothing here has to be inferred from
## bounding boxes the way the PSone's merged power/reset pad did.
class_name RetroSystemModelPlaystationOriginal
extends RetroSystemModelPlaystationOne

## The shell is authored with its FRONT along +X and its 265 mm width along Z —
## a quarter turn from the frame every placement assumes. Yawing the GLB is what
## lets the whole PSone implementation apply unchanged.
const _SHELL_YAW := -PI * 0.5

## Green power LED, lit while powered.
const _LED_COLOR := Color(0.45, 1.0, 0.5)

var _led_mat: StandardMaterial3D = null


func _model_path() -> String:
	return "res://imported-assets/playstation_original.glb"


func _shell_yaw() -> float:
	return _SHELL_YAW


## The bundled A/V + power leads and the memory-card prop already sitting in the
## front slot; RetroVR spawns its own cables and cards.
func _hidden_meshes() -> PackedStringArray:
	return PackedStringArray(["AVStecker", "PowerStecker", "MemoryCard"])


func _shell_mesh() -> String:
	return "Main"


func _lid_mesh() -> String:
	return "Deckel22"


func _disc_seat_marker() -> String:
	return "System Socket (CD) PSX"


func _cable_marker() -> String:
	return "AV Cable PSX"


func _ready() -> void:
	super()
	_setup_power_light()
	_set_power_light(false)


# --- buttons: three separate meshes, each with its own finger marker ----------
#
# The PSone had to split one merged "power_reset" pad down its printed centre.
# Here each control is modelled AND marked, so every button is wired to its own
# geometry with no inference.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_wire_marked_button(power_btn, "Start", "Finger Button Power")
	_wire_marked_button(reset_btn, "Reset Taste", "Finger Button Rest")
	_wire_marked_button(eject_btn, "Opern Taste", "Finger Button Open")


func _wire_marked_button(btn: VRButton, mesh_name: String, marker: String) -> void:
	if btn == null or _glb == null:
		return
	var mesh := _glb.find_child(mesh_name, true, false) as MeshInstance3D
	if mesh != null:
		btn.set_button_mesh(mesh)
	var mk := _glb.find_child(marker, true, false) as Node3D
	btn.global_position = mk.global_position if mk != null else _mesh_center(mesh_name)
	btn.depress_depth = 0.0025
	btn.set_depress_axis_world(Vector3.DOWN)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


# --- power LED ---------------------------------------------------------------
## Duplicate the LED's OWN material and add emission to it, rather than swapping
## in a fresh green one: with a green albedo the lamp reads lit even at zero
## emission, so a powered-off console still showed a green LED.
func _setup_power_light() -> void:
	if _glb == null:
		return
	var led := _glb.find_child("Licht PSX 2000", true, false) as MeshInstance3D
	if led == null or led.mesh == null:
		return
	var src := led.get_active_material(0) as BaseMaterial3D
	_led_mat = src.duplicate() as StandardMaterial3D if src is StandardMaterial3D else StandardMaterial3D.new()
	_led_mat.emission_enabled = true
	_led_mat.emission = _LED_COLOR
	led.set_surface_override_material(0, _led_mat)


func _set_power_light(on: bool) -> void:
	if _led_mat != null:
		_led_mat.emission_energy_multiplier = 2.5 if on else 0.0


func on_power_on() -> void:
	super()
	_set_power_light(true)


func on_power_off() -> void:
	super()
	_set_power_light(false)


# --- front panel -------------------------------------------------------------
#
# The shell marks ONE controller socket (" Controller PSX Plux" — note the
# leading space in the GLB). Port 2 is its mirror about the shell's centre line,
# which is how the real hardware is laid out and matches what the PSone's two
# modelled columns measure out to.
func configure_controller_ports(port_zones: Array) -> void:
	var mk := _socket_marker()
	if mk == null:
		super(port_zones)
		return
	# Everything here is WORLD space, like the parent's version: _front_face_z()
	# and _mesh_center() both return world coordinates, so mixing in a to_local()
	# value would silently offset the whole front panel.
	var p := mk.global_position
	var z := _front_face_z() - _PORT_INSET
	var axis := _mesh_center(_shell_mesh()).x     # the shell's centre line
	var dx := p.x - axis
	var cols := [axis + dx, axis - dx]
	for i in range(port_zones.size()):
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		if i < cols.size():
			# Rolled 180° about Z for the same reason as the PSone: the plug's own
			# SnapGrabPoint adds a 180° X flip that this cancels.
			port_zones[i].global_transform = Transform3D(
				global_transform.basis * Basis(Vector3.BACK, PI),
				Vector3(cols[i], p.y, z))


## The shell's single controller-socket marker. Note the LEADING SPACE in the
## GLB's node name — it is not a typo here.
func _socket_marker() -> Node3D:
	if _glb == null:
		return null
	return _glb.find_child(" Controller PSX Plux", true, false) as Node3D


## Memory cards go in the row ABOVE the controller ports, inboard of them.
func configure_memory_card_slot(slot: Node3D) -> void:
	var mk := _socket_marker()
	if mk == null:
		super(slot)
		return
	# World space throughout — see configure_controller_ports. Sunk in by half the
	# card's length less the grip left proud, exactly as the PSone seats it.
	var p := mk.global_position
	slot.global_position = Vector3(p.x, p.y + _CARD_ROW_RISE,
		_front_face_z() - _PORT_INSET - (_CARD_LENGTH * 0.5 - _CARD_PROTRUDE))


## Card slots sit this far above the controller port row.
const _CARD_ROW_RISE := 0.013


func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.27, 0.062, 0.20)
	var pos := Vector3(0.0, 0.03, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
