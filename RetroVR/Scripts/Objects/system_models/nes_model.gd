## RetroSystemModelNES — NES console model.
class_name RetroSystemModelNES
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/NES System.glb"

var _power_light_mesh: MeshInstance3D = null
var _power_light_lamp: Node3D = null
var _cartridge_insert_dir: Vector3 = Vector3.FORWARD


func _ready() -> void:
	var scene := load(_MODEL_PATH) as PackedScene
	if scene:
		var glb := scene.instantiate()
		add_child(glb)
		_power_light_mesh = glb.find_child("PowerLight", true, false) as MeshInstance3D
		_power_light_lamp = glb.find_child("Power Light lampe", true, false)
		# Start with light off
		if _power_light_mesh:
			_power_light_mesh.hide()
		if _power_light_lamp:
			_power_light_lamp.hide()
	else:
		push_warning("RetroSystemModelNES: could not load model at %s" % _MODEL_PATH)


func get_controller_port_count() -> int:
	return 2


func configure_buttons(power_btn: VRButton, reset_btn: VRButton) -> void:
	var glb := get_child(0)
	var power_finger := glb.find_child("Finger Button Power", true, false)
	var reset_finger := glb.find_child("Finger Button Reset", true, false)
	var power_mesh := glb.find_child("ButtonPower", true, false) as MeshInstance3D
	var reset_mesh := glb.find_child("ButtonReset", true, false) as MeshInstance3D
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
		slot.global_rotation = socket.global_rotation
		_cartridge_insert_dir = socket.global_transform.basis.z.normalized()
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual:
		slot_visual.hide()


func get_cartridge_insert_direction() -> Vector3:
	return _cartridge_insert_dir


func on_power_on() -> void:
	if _power_light_mesh:
		_power_light_mesh.show()
	if _power_light_lamp:
		_power_light_lamp.show()


func on_power_off() -> void:
	if _power_light_mesh:
		_power_light_mesh.hide()
	if _power_light_lamp:
		_power_light_lamp.hide()


func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	# NES: cartridge drops into the top-loading slot from above.
	# XRTools already froze it at the final position; pop it out then tween it in.
	var final_pos := cartridge.global_position
	var start_pos := final_pos + get_cartridge_insert_direction() * 0.06
	cartridge.freeze = false
	cartridge.global_position = start_pos
	var tween := cartridge.create_tween()
	tween.tween_property(cartridge, "global_position", final_pos, 0.25) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: cartridge.freeze = true)
