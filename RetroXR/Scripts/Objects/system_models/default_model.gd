## RetroSystemModelDefault — placeholder model used when no system-specific GLB exists.
## Manages the placeholder visuals already in system.tscn (colored button boxes,
## slot cylinder, port recesses, etc.) so system.gd never needs to know about them.
class_name RetroSystemModelDefault
extends RetroSystemModel

var _power_btn: VRButton = null
var _reset_btn: VRButton = null


func get_controller_port_count() -> int:
	return 4


# START/STOP label + color toggling is owned by system.gd
# (_update_power_button_visual) so every model gets it, including bespoke ones
# that override on_power_on/off for their own visuals.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_power_btn = power_btn
	_reset_btn = reset_btn
	_power_btn.set_color(Color(0.0, 1.0, 0.0))
