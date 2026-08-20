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

	var group := _machines_on_this_wire()
	if group.size() >= 2:
		_join(group)
	else:
		_disconnect()

	# Still reported and still announced: seating replication and anything
	# listening for a cable to move do not care what the cable carries.
	_report_seating_changes()
	topology_changed.emit()


## Every machine that ends up sharing this wire, as [{libretro, port}, ...].
##
## Not just this lead's two ends. A link cable carries an inline junction so a
## third and fourth player can chain in, and the junction has no core behind it:
## it conducts. So the set is found by walking cable to cable through junctions
## until nothing new turns up, which is what makes four handhelds on three leads
## one bus rather than three.
##
## The coordinator cannot do this walk itself, because a junction can never be an
## endpoint there. Working it out is the room's job precisely because the cables
## and their junctions are things in the room.
func _machines_on_this_wire() -> Array[Dictionary]:
	var machines: Array[Dictionary] = []
	var cables: Array[Node3D] = [self]
	var seen := {self: true}
	var i := 0

	while i < cables.size():
		var cable: LinkCable = cables[i] as LinkCable
		i += 1
		if cable == null:
			continue

		# Where this lead's own two ends are sitting.
		for e in [End.A, End.B]:
			var port := cable._link_port_at(e)
			if port == null:
				continue
			var machine := port.get_machine()
			if machine != null:
				var node := port.get_libretro()
				if node != null:
					machines.append({"libretro": node, "port": port.link_port})
				continue
			# Not a machine, so it is another lead's junction: follow it.
			_visit(port.get_cable(), cables, seen)

		# And whatever is plugged INTO this lead's junction.
		var junction := cable.junction_port()
		if junction != null:
			var plug := junction.seated_plug() as RcaPlug
			if plug != null:
				_visit(plug.cable, cables, seen)

	return machines


func _visit(cable: Node3D, cables: Array[Node3D], seen: Dictionary) -> void:
	if cable == null or not (cable is LinkCable) or seen.has(cable):
		return
	seen[cable] = true
	cables.append(cable)


## The junction socket moulded into this lead, or null on a lead that ships
## without one.
func junction_port() -> LinkPort:
	return get_node_or_null("Junction/LinkPort") as LinkPort


func _join(group: Array[Dictionary]) -> void:
	if _same_group(group):
		return          # already joined to exactly this set

	_disconnect()

	var head: Libretro = group[0]["libretro"]
	var others: Array = []
	var ports := PackedInt32Array()
	ports.append(group[0]["port"])
	for k in range(1, group.size()):
		others.append(group[k]["libretro"])
		ports.append(group[k]["port"])

	if head.LinkConnectGroup(others, ports):
		_linked = group.duplicate()


func _same_group(group: Array[Dictionary]) -> bool:
	if _linked.size() != group.size():
		return false
	for k in group.size():
		if _linked[k]["libretro"] != group[k]["libretro"] or _linked[k]["port"] != group[k]["port"]:
			return false
	return true


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


## Where along the cord the junction sits, as a fraction of the lead.
##
## Nearer the master end, as on the real cable. Exact placement is cosmetic; what
## matters is that it rides the cord rather than floating beside it, because a
## socket that does not move with the lead it is moulded into reads as broken.
const JUNCTION_AT := 0.25


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_ride_junction()


func _ride_junction() -> void:
	var junction := get_node_or_null("Junction") as Node3D
	if junction == null or _rope == null:
		return
	var n := _rope.point_count()
	if n < 3:
		return

	# One particle short of the end, so there is always a next one to take the
	# cord's direction from.
	var i: int = clampi(int(round(JUNCTION_AT * float(n - 1))), 0, n - 2)
	var here := _rope.point_position(i)
	var ahead := _rope.point_position(i + 1)
	var along := ahead - here
	if along.length_squared() < 1e-8:
		return

	junction.global_position = here
	# -Z runs along the cord, which leaves the socket facing out of the block's
	# side rather than back down the wire it is moulded into.
	junction.look_at(here + along.normalized(), Vector3.UP)


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
