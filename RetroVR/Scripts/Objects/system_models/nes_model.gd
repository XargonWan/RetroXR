## RetroSystemModelNES — NES console model.
class_name RetroSystemModelNES
extends RetroSystemModel

const _MODEL_PATH := "res://Models/nes_system_2.tscn"
const BUTTON_DEPRESS_DEPTH := 0.003

## Lid open rotation on X axis in radians. Tune after Blender hinge origin is set,
## or set to 0 and read from a "Lid Open Angle" empty node if one is added.
const LID_OPEN_ANGLE_X := -1.5
const LID_ANIM_DURATION := 0.3

## Offset in cradle-local space to place the cartridge snap zone (tune as needed).
const CARTRIDGE_SLOT_OFFSET := Vector3(0.0, 0.0, 0.05)

var _power_light_mesh: MeshInstance3D = null
var _power_light_lamp: Node3D = null
var _power_button: VRButton = null
var _cartridge_insert_dir: Vector3 = Vector3.FORWARD
var _nes_lid: Node3D = null
var _nes_cradle: Node3D = null
var _cradle_rest_angle: float = 0.0
var _cartridge_slot: Node3D = null
var _lid_open: bool = false
var _lid_local_pos: Vector3 = Vector3.ZERO
var _lid_zone_radius: float = 0.08
var _controllers_in_lid_zone: Array = []


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene:
		var glb := scene.instantiate()
		add_child(glb)
		_power_light_mesh = glb.find_child("PowerLight", true, false) as MeshInstance3D
		_power_light_lamp = glb.find_child("Power Light lampe", true, false)
		_nes_lid = glb.find_child("NesLid", true, false)
		_nes_cradle = glb.find_child("NesCradle", true, false)
		# Capture the cradle's resting angle before any animation runs
		if _nes_cradle:
			_cradle_rest_angle = _nes_cradle.rotation.x
		# Start with light off
		if _power_light_mesh:
			_power_light_mesh.hide()
		if _power_light_lamp:
			_power_light_lamp.hide()
		# Set up lid interaction zone after GLB is in the tree
		_setup_lid_zone(glb)
	else:
		push_warning("RetroSystemModelNES: could not load model at %s" % _MODEL_PATH)


func _setup_lid_zone(glb: Node3D) -> void:
	var finger := glb.find_child("Finger Button (Slider) Open Deckel", true, false)
	if not finger:
		push_warning("RetroSystemModelNES: Finger Button (Slider) Open Deckel not found")
		return
	_lid_local_pos = to_local(finger.global_position)


func _process(_delta: float) -> void:
	if _lid_local_pos == Vector3.ZERO:
		return
	var controllers := get_tree().get_nodes_in_group("xr_controllers")
	if controllers.is_empty():
		controllers = get_tree().root.find_children("*", "XRController3D", true, false)
	for ctrl in controllers:
		if not ctrl is XRController3D:
			continue
		var inside: bool = to_local(ctrl.global_position).distance_to(_lid_local_pos) <= _lid_zone_radius
		var was_inside: bool = ctrl in _controllers_in_lid_zone
		if inside and not was_inside:
			_controllers_in_lid_zone.append(ctrl)
			(ctrl as XRController3D).button_pressed.connect(_on_lid_button.bind(ctrl))
		elif not inside and was_inside:
			_controllers_in_lid_zone.erase(ctrl)
			if (ctrl as XRController3D).button_pressed.is_connected(_on_lid_button):
				(ctrl as XRController3D).button_pressed.disconnect(_on_lid_button)


func _on_lid_button(action: String, _ctrl: XRController3D) -> void:
	if action == "ax_button":
		_toggle_lid()


func _toggle_lid() -> void:
	_lid_open = not _lid_open
	var target_rot := LID_OPEN_ANGLE_X if _lid_open else 0.0
	if _nes_lid:
		var tween := create_tween()
		tween.tween_property(_nes_lid, "rotation:x", target_rot, LID_ANIM_DURATION) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _cartridge_slot:
		_cartridge_slot.enabled = _lid_open


func get_controller_port_count() -> int:
	return 2


func configure_buttons(power_btn: VRButton, reset_btn: VRButton) -> void:
	_power_button = power_btn
	var glb := get_child(0)
	var power_finger := glb.find_child("Finger Button Power", true, false)
	var reset_finger := glb.find_child("Finger Button Reset", true, false)
	var power_mesh := glb.find_child("ButtonPower", true, false) as MeshInstance3D
	var reset_mesh := glb.find_child("ButtonReset", true, false) as MeshInstance3D
	power_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	reset_btn.depress_depth = BUTTON_DEPRESS_DEPTH
	power_btn.set_latched_pressed(false)
	reset_btn.set_latched_pressed(false)
	if power_mesh:
		power_btn.set_button_mesh(power_mesh)  # also hides the placeholder box
	if power_finger:
		power_btn.global_position = power_finger.global_position
		power_btn.set_depress_axis_from_node(power_finger)
	if reset_mesh:
		reset_btn.set_button_mesh(reset_mesh)
	if reset_finger:
		reset_btn.global_position = reset_finger.global_position
		reset_btn.set_depress_axis_from_node(reset_finger)
	# Hide placeholder button labels — NES uses its own physical button geometry
	for btn in [power_btn, reset_btn]:
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl:
			lbl.hide()


func configure_controller_ports(port_zones: Array) -> void:
	var glb := get_child(0)
	for i in range(port_zones.size()):
		var marker := glb.find_child("Cable Plug Port%d" % (i + 1), true, false)
		if marker:
			port_zones[i].global_position = marker.global_position
		# Hide placeholder port visuals regardless of whether the model has a marker
		var recess := port_zones[i].get_node_or_null("PortRecess") as MeshInstance3D
		if recess:
			recess.hide()
		var lbl := port_zones[i].get_node_or_null("PortLabel") as Label3D
		if lbl:
			lbl.hide()


func configure_cable_attach(attach_point: Node3D) -> void:
	var glb := get_child(0)
	var marker := glb.find_child("Cable Plug (YW)", true, false)
	if marker:
		attach_point.global_position = marker.global_position
	var port_visual := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if port_visual:
		port_visual.hide()


func configure_cartridge_slot(slot: Node3D) -> void:
	var glb := get_child(0)
	var socket := glb.find_child("System Socket", true, false)
	if socket:
		slot.global_position = socket.global_position
		_cartridge_insert_dir = socket.global_transform.basis.z.normalized()
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual:
		slot_visual.hide()
	_cartridge_slot = slot
	_cartridge_slot.enabled = false  # only opens with the lid


func get_cartridge_insert_direction() -> Vector3:
	return _cartridge_insert_dir


func on_power_on() -> void:
	if _power_button:
		_power_button.set_latched_pressed(true)
	if _power_light_mesh:
		_power_light_mesh.show()
	if _power_light_lamp:
		_power_light_lamp.show()


func on_power_off() -> void:
	if _power_button:
		_power_button.set_latched_pressed(false)
	if _power_light_mesh:
		_power_light_mesh.hide()
	if _power_light_lamp:
		_power_light_lamp.hide()


func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	# Phase 1: slide horizontally into slot from in front of the opening.
	# Phase 2: cradle presses down, locking the cartridge into the ZIF socket.
	# XRTools already froze the cartridge at the final socket position.
	var final_pos := cartridge.global_position
	var slide_start := final_pos + _cartridge_insert_dir * 0.06
	cartridge.freeze = false
	cartridge.global_position = slide_start
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_position", final_pos, 0.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _nes_cradle:
		tween.tween_property(_nes_cradle, "rotation:x", 0.0, 0.2) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: cartridge.freeze = true)


func play_cartridge_eject(_cartridge: Node3D, _slot: Node3D) -> void:
	# Cartridge is already in the user's hand (XRTools handled the grab).
	# Just spring the cradle back to its resting (angled) position.
	if not _nes_cradle:
		return
	var tween := create_tween()
	tween.tween_property(_nes_cradle, "rotation:x", _cradle_rest_angle, 0.15) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
