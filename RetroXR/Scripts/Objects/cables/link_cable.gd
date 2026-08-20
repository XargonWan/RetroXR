## A link cable between two handhelds.
##
## Physically this is an ordinary lead and inherits all of it: the verlet rope,
## the plug clamping, seating persistence, and the multiplayer replication of
## which end sits where. What differs is only what a seated pair MEANS. A
## composite lead resolves into an A/V routing decision; this one resolves into
## two emulator cores being told they share a wire.
##
## So _resolve is the one thing overridden. It is the single place where "both
## ends are in sockets" turns into a consequence, and swapping that consequence
## is the whole of the difference.
##
## Two things a composite lead cares about and this one does not:
##
## Direction. A phono cord runs from an output to an input and carries nothing
## between two outputs. A link cable is symmetric, and which machine ends up
## driving the clock is decided by the guests over the wire, not by the room.
##
## The A/V graph. links() stays empty on purpose, so AvGraph walks straight past
## this lead. A television has no business hearing about it.
##
## The two ends are not interchangeable, and the shells say so. End A is always
## the one handed to LinkConnect first, so its machine takes bus index 0 and owns
## the clock; on the real cable that end is the purple connector and the
## secondary is grey. The colours are the hardware's, and here they happen to be
## accurate rather than decorative.
class_name LinkCable
extends CompositeCable

## The pair currently joined, as [{libretro, port}, {libretro, port}], so a pull
## can be undone against the same machines and the same sockets that were joined,
## even if by then one of them has been switched off or carried out of the room.
var _linked: Array[Dictionary] = []


func _resolve() -> void:
	if not is_inside_tree():
		return

	var a := _link_port_at(End.A)
	var b := _link_port_at(End.B)

	if a != null and b != null:
		_connect_ports(a, b)
	else:
		_disconnect()

	# Still reported and still announced: seating replication and anything
	# listening for a cable to move do not care what the cable carries.
	_report_seating_changes()
	topology_changed.emit()


## Deliberately empty. A link cable carries no picture and no sound, and AvGraph
## duck-types on this method, so an empty list is how a lead says "not mine".
func links() -> Array[Dictionary]:
	return []


## Left alone, deliberately.
##
## CompositeCable tints each plug with its CORD's colour so the wires of a
## multi-cord lead can be told apart at both ends. A link lead has one cord, and
## its two ends differ by ROLE rather than by wire: the purple shell is the
## master end, the grey one the secondary, exactly as on the real cable. Painting
## both from a one-entry cord palette would erase the only thing there is to see.
func _tint_plug(_plug: RcaPlug, _col: Color) -> void:
	pass


func _link_port_at(e: int) -> LinkPort:
	var plugs := _end_plugs(e)
	if plugs.is_empty():
		return null
	var plug := plugs[0] as RcaPlug
	if plug == null:
		return null
	return plug.seated_port() as LinkPort


func _connect_ports(a: LinkPort, b: LinkPort) -> void:
	var la := a.get_libretro()
	var lb := b.get_libretro()
	if la == null or lb == null:
		# One of the machines is off. The cable stays where it is and the link
		# comes up when it is switched on, which is what happens if you cable
		# two Game Boys together and then press power.
		_disconnect()
		return

	if _linked.size() == 2 \
			and _linked[0]["libretro"] == la and _linked[0]["port"] == a.link_port \
			and _linked[1]["libretro"] == lb and _linked[1]["port"] == b.link_port:
		return          # already joined to the same sockets, nothing changed

	_disconnect()
	if la.LinkConnect(lb, a.link_port, b.link_port):
		_linked = [
			{"libretro": la, "port": a.link_port},
			{"libretro": lb, "port": b.link_port},
		]


func _disconnect() -> void:
	# Cleared first, and the ends read straight out of the dictionary.
	#
	# Binding a freed object to a typed variable faults before is_instance_valid
	# ever gets to answer, so the guard has to come first, and a fault partway
	# through would otherwise leave the cable still believing it was joined. A
	# machine really can go away between joining and pulling: carried out of the
	# room, or the whole room torn down.
	var ends := _linked
	_linked = []
	for end: Dictionary in ends:
		if is_instance_valid(end["libretro"]):
			end["libretro"].LinkDisconnect(end["port"])


func _exit_tree() -> void:
	# A cable carried out of the room, or a scene change, still counts as
	# pulling it. Leaving the cores joined would hold each other up over a lead
	# that no longer exists.
	_disconnect()
