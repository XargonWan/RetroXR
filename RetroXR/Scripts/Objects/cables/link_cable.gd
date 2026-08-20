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


## Every lead that currently shares a wire with this one, this one included, as
## of the last resolve. Kept so a lead being carried out of the room can tell the
## ones it leaves behind, at which point the walk that would have found them is
## already broken.
var _wire: Array[Node3D] = []

## Guards the wake below against ringing back and forth for ever: a lead woken by
## its neighbour would otherwise wake the neighbour straight back.
static var _waking := false


func _resolve() -> void:
	if not is_inside_tree():
		return

	var wire: Array[Node3D] = []
	var group := _machines_on_this_wire(wire)

	if group.size() >= 2 and _bus_head(wire) == self:
		_join(group)
	else:
		# Either there is nothing to join, or another lead on this wire is the
		# one that joins it. Release whatever this lead is still holding either
		# way, so exactly one of them owns the bus.
		_disconnect()

	# Still reported and still announced: seating replication and anything
	# listening for a cable to move do not care what the cable carries.
	_report_seating_changes()
	topology_changed.emit()

	_wake(wire)


## Which lead on a wire performs the join.
##
## Every lead sharing a wire walks to the same machines, so without a rule they
## would all join them and all record having done so, and then whichever was
## pulled first would tear the bus down for the others. It has to be one.
##
## The head of the chain, meaning the lead that is not itself hanging off another
## lead's junction. That is a physical property of how the leads are plugged
## together rather than a fact about this program, so every lead on the wire
## picks the same one, and it puts the clock where the hardware puts it: on the
## machine at the head lead's purple end, which is the machine the walk visits
## first and therefore the one that takes bus index 0.
##
## A topology with no clear head, which needs both junctions in use, falls back
## to whichever lead was made first. Arbitrary, but it has to be decided somehow,
## and it is at least the same answer from every lead.
func _bus_head(wire: Array[Node3D]) -> Node3D:
	var head: Node3D = null
	for c in wire:
		var cable := c as LinkCable
		if cable == null or cable._hangs_off_a_junction():
			continue
		if head == null or cable.get_instance_id() < head.get_instance_id():
			head = cable
	if head != null:
		return head
	for c in wire:
		if head == null or c.get_instance_id() < head.get_instance_id():
			head = c
	return head


## Whether either of this lead's ends sits in another lead's junction rather than
## in a machine. A junction socket has no core behind it, which is exactly what
## tells the two kinds of socket apart.
func _hangs_off_a_junction() -> bool:
	for e in [End.A, End.B]:
		var port := _link_port_at(e)
		if port != null and port.get_machine() == null and port.get_cable() != null:
			return true
	return false


## Tell every other lead on this wire to look again.
##
## A lead resolves when ITS OWN plug moves, and that is not the same question as
## which machines are on the wire. Chain a third handheld onto a lead's junction
## and the FIRST lead's bus grew from two machines to three without anything of
## its own having moved.
##
## The union of the wire before and after, because unplugging from a junction
## takes this lead OFF the wire it needs to tell.
func _wake(wire: Array[Node3D]) -> void:
	var reach: Array[Node3D] = []
	for group: Array[Node3D] in [_wire, wire]:
		for c in group:
			if c != self and is_instance_valid(c) and not reach.has(c):
				reach.append(c)
	_wire = wire

	if _waking:
		return
	_waking = true
	for c in reach:
		var cable := c as LinkCable
		if cable != null:
			cable._resolve()
	_waking = false


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
func _machines_on_this_wire(cables: Array[Node3D]) -> Array[Dictionary]:
	var machines: Array[Dictionary] = []
	cables.append(self)
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
	_log_ends("joined", _linked)


func _log_ends(verb: String, ends: Array[Dictionary]) -> void:
	# Worth the noise for the same reason RcaPort logs every seating: the symptom
	# this explains is silent and misleading.
	#
	# A machine only takes part in a link if its CORE attached to the bus, and
	# that happens at load, behind a core option that says "(Restart)" and means
	# it. Switch a handheld on, then turn Link Cable on, and the room is entirely
	# right that the lead is seated and the machines are cabled -- while the game
	# reads "all GBAs ready" as false and refuses multiplayer with a rejection
	# noise. From the outside that is indistinguishable from a broken cable, a
	# socket that belongs to nobody, or a game that does not support linking.
	#
	# Peer COUNT is the number that tells them apart, because it comes back from
	# the core rather than from the room. Two machines cabled and only one peer
	# each means the other one's core is not on the bus.
	var parts: PackedStringArray = []
	for end: Dictionary in ends:
		var lib: Libretro = end["libretro"]
		if not is_instance_valid(lib):
			continue
		var machine := lib.get_parent()
		parts.append("%s (%d peers)" % [
			machine.name if machine != null else "?", lib.LinkPeerCount(end["port"])])
	print("[LinkCable] %s %s: %s" % [name, verb,
		", ".join(parts) if parts.size() > 0 else "nothing"])


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
	if ends.is_empty():
		return
	_linked = []
	for end: Dictionary in ends:
		if is_instance_valid(end["libretro"]):
			end["libretro"].LinkDisconnect(end["port"])
	# After the disconnects, so the count reported is the one that resulted.
	_log_ends("parted", ends)


func _exit_tree() -> void:
	# A cable carried out of the room, or a scene change, still counts as
	# pulling it. Leaving the cores joined would hold each other up over a lead
	# that no longer exists.
	_disconnect()

	# And the leads it was chained to have to rebuild whatever is left. Deferred,
	# because this one is still half in the tree and a wire walk performed now
	# would walk straight back into it.
	for c in _wire:
		if c != self and is_instance_valid(c):
			c.call_deferred("_resolve")
	_wire = []
