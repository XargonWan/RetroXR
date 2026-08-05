## A 1.8 m composite A/V lead: three cords moulded into one ribbon, each ending in
## its own plug at both ends, all six free.
##
## ── What decides the signal ──────────────────────────────────────────────────
## A cord is a plain WIRE. It has a colour, and the colour means nothing: what a
## cord carries is whatever is on the socket its far end sits in. So
##
##   * video reaches the set only when a cord joins the deck's VIDEO socket to the
##     television's VIDEO socket — any cord, the yellow one by convention,
##   * the yellow cord run between the two L sockets carries the left channel and
##     works perfectly,
##   * and a cord from the deck's L to the set's R puts the left channel out of the
##     right-hand speaker, which is exactly what happens if you do it for real.
##
## None of that is special-cased. _resolve reads the two ports each cord lands in
## and reports the pairs; every device decides for itself what to do with them.
##
## ── The rope ────────────────────────────────────────────────────────────────
## One VerletRope with ribbon_count 3, frayed into three groups at BOTH ends, so
## the trunk is a single simulated chain that breaks out into three short tails
## per end. The trunk's terminal particles are left unanchored on purpose — the
## plugs carry the breakout, the way an unsupported junction behaves on the real
## lead. See the ribbon note at the top of verlet-rope/src/VerletRope.hpp.
class_name CompositeCable
extends Node3D


## Emitted whenever a plug is seated or pulled, after the devices have been told.
signal topology_changed

## Cord colours, in cord order. Yellow/white/red is the convention, and the plug
## bodies are tinted to match so a cord can be told apart at both ends.
const CORD_COLORS := [
	RcaJack.COMPOSITE_YELLOW,
	RcaJack.AUDIO_WHITE,
	RcaJack.AUDIO_RED,
]

const CORDS := 3

## Ends of the lead, used only to name things.
enum End { A, B }

@onready var _rope: VerletRope = $VerletRope

# Plugs, [end][cord]. Populated in _ready from the scene's fixed node names.
var _plugs: Array = []

# Devices told about this cable last time round, so one that has just lost its
# last cord still gets a final update telling it so.
var _last_devices: Array[Node3D] = []


func _ready() -> void:
	add_to_group("spawned")
	_plugs = [[], []]
	for e in [End.A, End.B]:
		for c in CORDS:
			var plug := get_node("Plug%s%d" % ["AB"[e], c]) as RcaPlug
			plug.cord = c
			plug.cable = self
			# A plug leaving or arriving anywhere changes what this lead carries.
			# grabbed(pickable, by) covers a socket taking it, dropped(pickable) a
			# socket or a hand letting it go.
			plug.grabbed.connect(_on_plug_moved.unbind(2))
			plug.dropped.connect(_on_plug_moved.unbind(1))
			_tint_plug(plug, CORD_COLORS[c])
			_plugs[e].append(plug)
	_build_rope()
	# Ports fire on the frame the plug seats; resolve once the room is up so a
	# cable restored into sockets reports what it is already carrying.
	call_deferred("_resolve")


## Colour a plug body to its cord, so the same wire can be recognised at both ends.
##
## Surface 0 of the baked plug is the plastic and surface 1 the metal — the split
## exists for exactly this (see Tools/gen_rca_plug.gd). The baked material is shared
## by every plug in the room, so it is duplicated before a colour goes into it.
func _tint_plug(plug: RcaPlug, col: Color) -> void:
	var tip := plug.get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null:
		return
	var base := tip.mesh.surface_get_material(0) as StandardMaterial3D
	if base == null:
		return
	var mat := base.duplicate() as StandardMaterial3D
	mat.albedo_color = col
	tip.set_surface_override_material(0, mat)


## Wire the ribbon to its six plugs. Both ends fray into one group per cord, so
## every cord gets its own tail and its own anchor.
func _build_rope() -> void:
	_rope.ribbon_count = CORDS
	_rope.ribbon_colors = PackedColorArray(CORD_COLORS)
	# Read in the START anchor's local space. The lead has no start anchor once
	# both ends fray, so this is world: the ribbon lies flat across X.
	_rope.ribbon_axis = Vector3(1, 0, 0)
	var groups := PackedInt32Array()
	for c in CORDS:
		groups.append(c)
	_rope.fray_start_groups = groups
	_rope.fray_end_groups = groups
	# The trunk ends at each breakout and nothing holds it there; the tails do.
	_rope.start_node = null
	_rope.end_node = null
	for c in CORDS:
		_rope.set_fray_start_node(c, _plugs[End.A][c])
		_rope.set_fray_end_node(c, _plugs[End.B][c])
		# End the tail at the connector's cable boss rather than at the plug's
		# origin, which sits 40 mm forward at the collar.
		_rope.set_fray_start_anchor_offset(c, _plugs[End.A][c].cable_anchor)
		_rope.set_fray_end_anchor_offset(c, _plugs[End.B][c].cable_anchor)
	_rope._init_points()


func _on_plug_moved() -> void:
	# A grab or a drop lands before the snap zone has taken or released the plug,
	# so read the ports next frame.
	call_deferred("_resolve")


## Called by an RcaPort when it takes or releases one of this lead's plugs. The
## socket is the authority on seating — see the note in RcaPort._ready — so this is
## the signal that actually keeps the routing honest; the plug's own grab signals
## are a belt-and-braces second path to the same resolve.
func on_plug_seating_changed() -> void:
	call_deferred("_resolve")


## Work out what each cord joins, and tell every device involved.
##
## Reported as a list of {out_port, in_port} pairs — direction sorted here so a
## device never has to care which end of the lead it is on, and a cord between two
## outputs (or two inputs, or one loose end) is simply left out.
func _resolve() -> void:
	if not is_inside_tree():
		return
	var links: Array[Dictionary] = []
	var devices: Array[Node3D] = []
	for c in CORDS:
		var pa: RcaPort = (_plugs[End.A][c] as RcaPlug).seated_port()
		var pb: RcaPort = (_plugs[End.B][c] as RcaPlug).seated_port()
		if pa == null or pb == null:
			continue
		var out_port: RcaPort = null
		var in_port: RcaPort = null
		if pa.direction == RcaPort.Direction.OUT and pb.direction == RcaPort.Direction.IN:
			out_port = pa
			in_port = pb
		elif pb.direction == RcaPort.Direction.OUT and pa.direction == RcaPort.Direction.IN:
			out_port = pb
			in_port = pa
		else:
			continue        # source to source, or sink to sink: carries nothing
		links.append({"out": out_port, "in": in_port, "cord": c})
		for port: RcaPort in [out_port, in_port]:
			var dev: Node3D = port.get_device()
			if dev != null and not devices.has(dev):
				devices.append(dev)

	# Devices that were carrying something and now are not have to hear about it
	# too, or a pulled cord leaves a picture on the screen.
	for dev in _last_devices:
		if is_instance_valid(dev) and not devices.has(dev):
			devices.append(dev)
	_last_devices = devices.duplicate()

	for dev in devices:
		if is_instance_valid(dev):
			dev.on_av_topology_changed(links)
	topology_changed.emit()


## Every link this lead currently carries, for a device that wants to re-read them
## without waiting for a change (a deck coming out of standby, say).
func links() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c in CORDS:
		var pa: RcaPort = (_plugs[End.A][c] as RcaPlug).seated_port()
		var pb: RcaPort = (_plugs[End.B][c] as RcaPlug).seated_port()
		if pa == null or pb == null:
			continue
		if pa.direction == RcaPort.Direction.OUT and pb.direction == RcaPort.Direction.IN:
			out.append({"out": pa, "in": pb, "cord": c})
		elif pb.direction == RcaPort.Direction.OUT and pa.direction == RcaPort.Direction.IN:
			out.append({"out": pb, "in": pa, "cord": c})
	return out
