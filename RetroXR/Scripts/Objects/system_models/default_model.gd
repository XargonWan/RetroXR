## RetroSystemModelDefault — placeholder model used when no system-specific GLB exists.
## Manages the placeholder visuals already in system.tscn (colored button boxes,
## slot cylinder, port recesses, etc.) so system.gd never needs to know about them.
class_name RetroSystemModelDefault
extends RetroSystemModel

var _power_btn: VRButton = null
var _reset_btn: VRButton = null


## Nothing here draws a console — this model dresses the box system.tscn already
## carries. So the cabinet keeps that box, and this model draws the disc
## mechanism to match it.
func brings_own_body() -> bool:
	return false


## The disc pod, shelf and slit are measurements of the placeholder box, so they
## are this model's geometry and not the cabinet's. Every dimension lives in
## ProceduralDiscBay.
func build_disc_bay(host: Node3D, slot: Node3D, systemid: String, front: bool,
		on_lid_swung: Callable) -> ProceduralDiscBay:
	return ProceduralDiscBay.build_tray(host, slot, systemid, front, on_lid_swung)


func build_disc_slit(host: Node3D, systemid: String) -> void:
	ProceduralDiscBay.build_slit(host, systemid)


func get_controller_port_count() -> int:
	return 4


## Sockets rather than a captive lead, the same three the decks wear: this box
## stands in for console hardware, and console hardware has A/V out on the back.
func av_port_channels() -> Array:
	return [RcaPort.Channel.VIDEO, RcaPort.Channel.AUDIO_L, RcaPort.Channel.AUDIO_R]


## Lay them across the back panel of the 0.3 x 0.1 x 0.25 box, on 18 mm centres —
## the spacing the NES moulds and the decks now use.
##
## Local, not global: this model has no meshes to measure against (that is what
## makes it the primitive one), and the ports are already children of the system.
## Turned 180 degrees about X so each socket's local +Z points out of the back,
## which is where a plug arrives from.
func configure_av_ports(ports: Array) -> void:
	for i in ports.size():
		var port: Node3D = ports[i]
		# Centred on x = 0.1, where the captive lead's attach point used to sit.
		port.position = Vector3(0.082 + 0.018 * float(i), 0.0, -0.135)
		port.rotation = Vector3(PI, 0.0, 0.0)


# START/STOP label + color toggling is owned by system.gd
# (_update_power_button_visual) so every model gets it, including bespoke ones
# that override on_power_on/off for their own visuals.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, _eject_btn: VRButton) -> void:
	_power_btn = power_btn
	_reset_btn = reset_btn
	_power_btn.set_color(Color(0.0, 1.0, 0.0))
