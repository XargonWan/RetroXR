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

## Where the cord meets this plug, in plug-local space — for
## VerletRope.end_anchor_offset.
##
## The plug's ORIGIN is its SEATING reference, the point the snap zone lines up
## with the port, and on a real connector body that sits at the collar some 40 mm
## forward of where the cable actually enters. Ending the rope at the origin runs
## the tube straight out through the barrel.
##
## Derived from the mesh rather than hardcoded, so reshaping the connector cannot
## silently desync this. Mirrors ControllerPlug.cable_anchor.
var cable_anchor: Vector3 = Vector3.ZERO


func _ready() -> void:
	super._ready()
	# Add to the snap group so TV's CompositePort (snap_require = "composite_plug") accepts us
	add_to_group("composite_plug")
	_derive_cable_anchor()


func _derive_cable_anchor() -> void:
	var tip := get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null:
		return
	var ab: AABB = tip.mesh.get_aabb()
	# Cable trails -Z, matching VerletRope.plug_exit_axis, so the boss is at min Z.
	cable_anchor = tip.transform * Vector3(
		ab.get_center().x, ab.get_center().y, ab.position.z)


## Returns the host this cable belongs to
func get_system() -> Node3D:
	return _system


## Set the owning host (called by the host when creating the cable)
func set_system(system: Node3D) -> void:
	_system = system
