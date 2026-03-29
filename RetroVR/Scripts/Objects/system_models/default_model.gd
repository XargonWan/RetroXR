## RetroSystemModelDefault — placeholder model used when no system-specific GLB exists.
## Manages the placeholder visuals already in system.tscn (colored button boxes,
## slot cylinder, port recesses, etc.) so system.gd never needs to know about them.
class_name RetroSystemModelDefault
extends RetroSystemModel

var _power_btn: VRButton = null
var _reset_btn: VRButton = null
var _power_label: Label3D = null
var _reset_label: Label3D = null


func get_controller_port_count() -> int:
	return 4


func configure_buttons(power_btn: VRButton, reset_btn: VRButton) -> void:
	_power_btn = power_btn
	_reset_btn = reset_btn
	_power_label = power_btn.get_node_or_null("ButtonLabel") as Label3D
	_reset_label = reset_btn.get_node_or_null("ButtonLabel") as Label3D
	_power_btn.set_color(Color(0.0, 1.0, 0.0))


func on_power_on() -> void:
	if _power_btn:
		_power_btn.set_color(Color(1.0, 0.0, 0.0))
	if _power_label:
		_power_label.text = "STOP"


func on_power_off() -> void:
	if _power_btn:
		_power_btn.set_color(Color(0.0, 1.0, 0.0))
	if _power_label:
		_power_label.text = "START"
