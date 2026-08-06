## One plug on a composite lead — the grabbable end of a single cord.
##
## A cord is a WIRE, and this is one of its two ends. It carries no channel of its
## own: what a cord conducts is decided entirely by the two ports its ends sit in,
## which is why the colour here is cosmetic and any plug fits any socket. The
## routing is worked out in CompositeCable._resolve.
##
## Distinct from CablePlug, which is the single captive plug on a console's
## permanently attached lead and knows the host that owns it. This one is owned by
## a cable, not by a device.
class_name RcaPlug
extends XRToolsPickable


## Which cord of the lead this end belongs to. The plug at the same index on the
## other end is the far end of the same wire.
var cord: int = 0

## The lead this plug belongs to.
var cable: Node3D = null

## Where the cord meets this plug, in plug-local space, for the rope's fray anchor.
## The plug's origin is its SEATING reference and sits at the collar, 40 mm forward
## of where the cord actually enters; anchoring there runs the tail out through the
## barrel. Derived from the mesh, as CablePlug does, so reshaping the connector
## cannot silently desync it.
var cable_anchor: Vector3 = Vector3.ZERO


func _ready() -> void:
	super._ready()
	# Every RCA socket in the project takes this group, and none of them filter
	# any further -- see RcaPort.
	add_to_group("composite_plug")
	_derive_cable_anchor()
	picked_up.connect(func(_p: Variant) -> void: PlugAim.aim(self))


func _derive_cable_anchor() -> void:
	var tip := get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null:
		return
	var ab: AABB = tip.mesh.get_aabb()
	# Cable trails -Z, matching VerletRope.plug_exit_axis, so the boss is at min Z.
	cable_anchor = tip.transform * Vector3(
		ab.get_center().x, ab.get_center().y, ab.position.z)


## The socket this plug is currently seated in, or null when it is loose.
##
## Asked of the SOCKETS rather than remembered here, and rather than walked up the
## parent chain: whether a snap zone reparents what it holds is xr-tools' business
## and not something to depend on, while `picked_up_object` is the zone's own
## account of what it has. A plug that is dropped, stolen by another zone or freed
## therefore cannot leave a stale port behind.
func seated_port() -> RcaPort:
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.seated_plug() == self:
			return port
	return null
