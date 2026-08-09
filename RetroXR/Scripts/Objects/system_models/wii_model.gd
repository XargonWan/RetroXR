## RetroSystemModelWii — the Wii, wearing the procedural box until it has a shell
## of its own. Two things live here: the core options below, which are not
## cosmetic (the Wii Remote does not work at all without them), and the one socket
## no other console in the room has — the sensor bar jack.
##
## Everything else Wii-shaped — pairing, slot arbitration, the GameCube-vs-Wii
## device ids, what happens when a bar is plugged in — lives in WiiLink, the
## component system.gd attaches to this console. This file is only the hardware
## description.
class_name RetroSystemModelWii
extends RetroSystemModelDefault


const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## Back panel, left of the three A/V sockets configure_av_ports lays out from
## x = 0.082. The box is 0.3 x 0.1 x 0.25, so -0.11 is near the far corner.
const SENSOR_BAR_JACK := Vector3(-0.11, 0.0, -0.135)

var _sensor_bar_port: XRToolsSnapZone = null


## Three of these, and every one is load-bearing for the Wii Remote.
##
## `dolphin_ir_passthrough = "enabled"` is what makes the remote's aim geometric.
## With it on, the frontend projects the sensor bar's two LEDs into the remote's
## own camera and hands Dolphin the pixel coordinates, so the emulated camera sees
## what a real one would — including roll and distance, which a cursor position
## cannot express. Off, the core falls back to rotating a notional remote parked
## two metres from the bar by a scale nobody can derive, and where the game draws
## its hand then depends on a constant fitted per game.
##
## `dolphin_ir_mode = "2"` is the fallback's binding: IR on the libretro POINTER
## device rather than the right analog stick. Pinned even though passthrough
## bypasses it, so that turning passthrough off in the options panel leaves a
## remote that still points instead of one that does nothing.
##
## `dolphin_save_load_settings = "disabled"` is already the core's default, and is
## pinned because of what switching it on does: the core then loads WiimoteNew.ini
## and returns EARLY from its port setup, skipping every built-in mapping —
## including both of the above. A stale profile in the Dolphin system folder would
## silently cost the player their aim, with nothing in the logs to say why.
func get_forced_core_options() -> Dictionary:
	return {
		"dolphin_ir_passthrough": "enabled",
		"dolphin_ir_mode": "2",
		"dolphin_save_load_settings": "disabled",
	}


func _ready() -> void:
	_build_sensor_bar_port()


## The sensor bar jack, or null before _ready. WiiLink wires the handlers; this
## only builds the socket, because a socket is hardware and this file is the
## hardware description.
func get_sensor_bar_port() -> XRToolsSnapZone:
	return _sensor_bar_port


## A round hole on the back panel, next to the A/V sockets, exactly as the real
## machine wears it.
##
## Built here rather than authored into system.tscn because no other console has
## one. The cabinet scene is shared by every machine in the room, and a jack that
## only a Wii can use would sit dead on all of them — the same reason the disc
## tray is grown by the model that needs it instead of shipped with the box.
##
## The zone accepts only SensorBar.PLUG_GROUP, which nothing else joins, so the
## filter needs no callback: a controller plug bounces off it and its own plug
## fits nothing else.
func _build_sensor_bar_port() -> void:
	_sensor_bar_port = SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
	_sensor_bar_port.name = "SensorBarPort"
	_sensor_bar_port.position = SENSOR_BAR_JACK
	# Turned to face out of the BACK, the same 180-about-X the A/V sockets take —
	# see configure_av_ports for why a roll and not a yaw.
	_sensor_bar_port.rotation = Vector3(PI, 0.0, 0.0)
	_sensor_bar_port.grab_distance = 0.03
	_sensor_bar_port.snap_require = String(SensorBar.PLUG_GROUP)
	add_child(_sensor_bar_port)

	var recess := MeshInstance3D.new()
	recess.name = "PortRecess"
	var hole := CylinderMesh.new()
	hole.top_radius = 0.006
	hole.bottom_radius = 0.006
	hole.height = 0.004
	recess.mesh = hole
	# Lying on its side so the bore faces out of the socket rather than up.
	recess.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.08, 0.08, 0.08)
	recess.set_surface_override_material(0, dark)
	_sensor_bar_port.add_child(recess)

	# Counter-rolled out of the socket's frame: the zone is turned 180 about X, so
	# a label parented straight to it reads upside down and sits under the jack
	# instead of over it. RotZ(PI) inside RotX(PI) leaves the text upright and
	# facing out of the back panel.
	var label := Label3D.new()
	label.name = "PortLabel"
	label.text = "SENSOR BAR"
	label.pixel_size = 0.0006
	label.font_size = 14
	label.position = Vector3(0.0, -0.014, 0.004)
	label.rotation = Vector3(0.0, 0.0, PI)
	_sensor_bar_port.add_child(label)
