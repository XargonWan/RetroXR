## The serial socket on a handheld — the GBA's link port.
##
## An RcaPort with a different mouth and a different consequence. Everything the
## seating machinery needs is already inherited: RcaPort.GROUP membership so a
## plug can find the socket holding it, the has_picked_up / has_dropped hooks,
## and plug_group() gating so a link lead will not go into a phono jack.
##
## What differs is what a seated cable MEANS. An A/V lead resolves through
## AvGraph into a routing decision; this one resolves into two emulator cores
## being told they share a wire, which is LinkCable's job rather than this
## socket's. All this adds is a way to find the machine that owns the socket and
## the core running inside it.
##
## `channel` is inherited but meaningless here, so it is pinned rather than left
## for a scene to set wrong: a link cable carries neither picture nor sound.
class_name LinkPort
extends RcaPort

## Which of the machine's link ports this socket is. A Game Boy Advance has one;
## the export exists because a GameCube has four, and the API this ultimately
## drives is addressed by port from the start.
@export var link_port: int = 0


func plug_group() -> String:
	return "link_plug"


func _ready() -> void:
	super._ready()
	channel = RcaPort.Channel.VIDEO
	show_jack = false


## The machine this socket belongs to.
##
## RcaPort.get_device() walks for a node that answers on_av_topology_changed,
## which is the A/V graph's question and finds televisions and decks. A link
## cable wants the thing running a core instead, so it walks for that.
func get_machine() -> Node3D:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("get_libretro_node"):
			return n as Node3D
		n = n.get_parent()
	return null


## The Libretro node behind this socket, or null when the machine is off. Null is
## ordinary rather than exceptional: a cable can be seated into a console that
## has not been switched on yet, and it should simply come alive when it is.
func get_libretro() -> Libretro:
	var machine := get_machine()
	if machine == null:
		return null
	return machine.get_libretro_node()
