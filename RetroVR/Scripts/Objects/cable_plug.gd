## CablePlug — the grabbable end of a cable that snaps into a TV's CompositePort.
## Must be in the "composite_plug" group so the TV's snap zone accepts it.
## Holds a back-reference to the host that owns the cable. The host is any node
## implementing the TV contract (on_tv_connected/on_tv_disconnected/
## set_audio_volume/set_screen_enabled) — a RetroSystem or a VCRPlayer.
class_name CablePlug
extends XRToolsPickable


## The host this cable belongs to (set by the host when the cable is instantiated)
var _system: Node3D = null

## Which of the host's video-out channels this cable carries (multi-output
## hardware: 0 = TOP, 1 = BOTTOM on a dual-screen handheld). Single-cable
## hosts leave it 0.
var channel: int = 0

## Cable tag shown on the plug ("TOP"/"BOTTOM"); "" on single-cable hosts.
var channel_label: String = ""


func _ready() -> void:
	super._ready()
	# Add to the snap group so TV's CompositePort (snap_require = "composite_plug") accepts us
	add_to_group("composite_plug")


## Returns the host this cable belongs to
func get_system() -> Node3D:
	return _system


## Set the owning host (called by the host when creating the cable)
func set_system(system: Node3D) -> void:
	_system = system
