## One RCA socket on a device: a snap zone that wears an RcaJack and knows what
## signal it carries and which way that signal flows.
##
## Every port accepts every plug — group "composite_plug", no colour filter —
## because that is what the real connector does. Putting the yellow cord into
## both L sockets carries the left channel down a yellow wire and works; putting
## it into the L socket at one end and the R at the other swaps the channels.
## Nothing here enforces a "correct" cable; the routing falls out of which ports a
## cord's two ends happen to sit in. See CompositeCable.
class_name RcaPort
extends XRToolsSnapZone


## What this socket carries. The order matches RcaJack's colour code and is used
## as an index into per-channel arrays, so do not reorder it.
enum Channel { VIDEO, AUDIO_L, AUDIO_R }

## Which way the signal flows through this socket. A deck's sockets are OUT, a
## television's are IN. A cord between two OUTs (or two INs) carries nothing,
## which is also true of the real thing.
enum Direction { OUT, IN }

@export var channel: Channel = Channel.VIDEO:
	set(value):
		channel = value
		_tint_jack()

@export var direction: Direction = Direction.IN

## Short label for the OSD and for debugging — "VIDEO", "L", "R".
const CHANNEL_NAMES := ["VIDEO", "L", "R"]

## Every socket in the room, so a plug can find the one holding it and a cable can
## re-resolve without knowing what devices exist.
const GROUP := "rca_port"


func _ready() -> void:
	super._ready()
	add_to_group(GROUP)
	snap_require = "composite_plug"
	_tint_jack()
	# The SOCKET announces seating, not the plug. A snap zone's has_picked_up /
	# has_dropped fire whenever the zone's own state changes, while the pickable's
	# `dropped` needs the releasing zone to be the one actually holding the grab —
	# so a plug taken straight out of one socket into another leaves the first
	# socket empty without the plug ever reporting a thing.
	has_picked_up.connect(_on_seated)
	has_dropped.connect(_on_unseated)


func _on_seated(what: Node3D) -> void:
	_last_plug = what as RcaPlug
	_announce(_last_plug)


func _on_unseated() -> void:
	var plug := _last_plug
	_last_plug = null
	_announce(plug)


## Tell the lead that what it carries may have changed.
func _announce(plug: RcaPlug) -> void:
	if plug != null and is_instance_valid(plug) and plug.cable != null \
			and is_instance_valid(plug.cable):
		plug.cable.on_plug_seating_changed()


# The plug this socket last held, so an unseat — which reports nothing — still
# knows which lead to tell.
var _last_plug: RcaPlug = null


func _tint_jack() -> void:
	var jack := get_node_or_null("RcaJack") as RcaJack
	if jack == null:
		return
	match channel:
		Channel.VIDEO: jack.jack_color = RcaJack.COMPOSITE_YELLOW
		Channel.AUDIO_L: jack.jack_color = RcaJack.AUDIO_WHITE
		Channel.AUDIO_R: jack.jack_color = RcaJack.AUDIO_RED


func channel_name() -> String:
	return CHANNEL_NAMES[channel]


## The plug currently seated here, or null.
func seated_plug() -> Node3D:
	return picked_up_object if is_instance_valid(picked_up_object) else null


## The device this socket belongs to — the deck or the television that owns it.
##
## Walked rather than exported, so a port can be dropped anywhere in a device's
## scene (on a shell, inside a back-panel node) without also having to be wired up.
func get_device() -> Node3D:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("on_av_topology_changed"):
			return n as Node3D
		n = n.get_parent()
	return null
