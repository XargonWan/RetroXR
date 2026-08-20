## Link-cable self-tests — the decisions a link lead makes, headless.
##
##     "$godot" --headless --path RetroXR res://Tests/link_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is here is what can be decided without a core: which sockets will take a
## link plug, which machine a socket belongs to, and the connect/disconnect
## bookkeeping that decides whether two cores are told they share a wire. Whether
## a linked pair actually trades bytes needs two real cores and lives in the
## coordinator's own C++ tests (libretro-godot/tests/run_tests.py), which is also
## where the deadlock and determinism cases are.
##
## Two of these are the regression record for traps this feature can fall into.
## A link lead that reported itself to AvGraph would put a television in the
## business of routing serial traffic, and a cable that stayed joined after being
## carried out of the room would leave two cores waiting on each other over a
## lead that no longer exists.
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[link] TIMEOUT")
		get_tree().quit(1))
	_test_plug_gating()
	_test_port_pins_its_channel()
	_test_machine_lookup()
	_test_libretro_lookup()
	_test_cable_is_not_av()
	await _test_disconnect_is_idempotent()
	await _test_cable_scene()
	await _test_port_scene()
	print("[link] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[link] PASS  %s" % name)
	else:
		_fail += 1
		print("[link] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


## A socket in the tree, so _ready has run. Caller frees it.
func _port() -> LinkPort:
	var p := LinkPort.new()
	add_child(p)
	return p


# ── The gate ────────────────────────────────────────────────────────────────
# plug_group() is the whole of what stops a lead going somewhere it could not go
# on real hardware, and it only works if both halves agree.

func _test_plug_gating() -> void:
	var port := _port()
	var plug := LinkPlug.new()
	add_child(plug)

	_eq("port and plug name the same group", port.plug_group(), plug.plug_group())
	_eq("the group is link_plug", port.plug_group(), "link_plug")

	# A link lead must not fit an A/V socket, and a phono cord must not fit this
	# one. Asserted against the real classes rather than string literals, so
	# renaming a group cannot quietly open the gate.
	var rca := RcaPort.new()
	add_child(rca)
	_ok("a link socket does not take a phono plug", port.plug_group() != rca.plug_group())

	var trs := TrsPort.new()
	add_child(trs)
	_ok("a link socket does not take a stereo plug", port.plug_group() != trs.plug_group())

	# The gate is enforced through the snap zone, so the requirement has to have
	# actually been applied and not just be available to read.
	_eq("the socket requires that group to snap", port.snap_require, port.plug_group())

	port.queue_free()
	plug.queue_free()
	rca.queue_free()
	trs.queue_free()


func _test_port_pins_its_channel() -> void:
	var port := _port()
	# Inherited from RcaPort but meaningless on a cable that carries neither
	# picture nor sound, so it is pinned rather than left for a scene to set
	# wrong.
	_eq("channel is pinned", port.channel, RcaPort.Channel.VIDEO)
	_ok("the jack visual is off", not port.show_jack)
	port.queue_free()


# ── Finding the machine ─────────────────────────────────────────────────────

func _test_machine_lookup() -> void:
	var loose := _port()
	_eq("a socket owned by nobody has no machine", loose.get_machine(), null)
	loose.queue_free()

	var machine := _StubMachine.new()
	add_child(machine)
	var shell := Node3D.new()
	machine.add_child(shell)          # a socket may sit any depth inside a machine
	var port := LinkPort.new()
	shell.add_child(port)

	_eq("a socket finds the machine that owns it", port.get_machine(), machine)
	machine.queue_free()


func _test_libretro_lookup() -> void:
	var machine := _StubMachine.new()
	add_child(machine)
	var port := LinkPort.new()
	machine.add_child(port)

	# A cable seated into a console that has not been switched on is ordinary,
	# not an error: the link should simply come up when it is powered.
	_eq("an unpowered machine yields no core", port.get_libretro(), null)
	machine.queue_free()


# ── Not an A/V lead ─────────────────────────────────────────────────────────

func _test_cable_is_not_av() -> void:
	var cable := LinkCable.new()
	add_child(cable)
	# AvGraph duck-types on links(), so an empty list is how a lead says "not
	# mine". A link cable reporting itself here would drag televisions into
	# routing serial traffic.
	_eq("a link cable reports no A/V links", cable.links().size(), 0)
	cable.queue_free()


# ── Coming apart ────────────────────────────────────────────────────────────

func _test_disconnect_is_idempotent() -> void:
	var cable := LinkCable.new()
	add_child(cable)

	# Never joined, so there is nothing to undo. This runs on every unseated
	# resolve and on the way out of the tree, so it has to be safe to call at any
	# time and any number of times.
	cable._disconnect()
	cable._disconnect()
	_eq("a cable that was never joined records no link", cable._linked.size(), 0)

	# Neither machine is running, and the cable joins them anyway. That is the
	# behaviour a cable has: seating one into a console that is switched off is
	# an ordinary thing to do, and the link comes alive when both cores attach
	# their serial hardware. Refusing here would mean a player had to power both
	# handhelds before plugging them together, which no cable has ever required.
	var m1 := _StubMachine.new()
	var m2 := _StubMachine.new()
	add_child(m1)
	add_child(m2)
	m1.libretro = Libretro.new()
	m2.libretro = Libretro.new()
	m1.add_child(m1.libretro)
	m2.add_child(m2.libretro)
	var p1 := LinkPort.new()
	var p2 := LinkPort.new()
	m1.add_child(p1)
	m2.add_child(p2)

	cable._connect_ports(p1, p2)
	_eq("two idle machines are still cabled together", cable._linked.size(), 2)
	cable._disconnect()

	# And the guard against a machine cabled to itself, which the room can
	# present as two sockets on one handheld.
	cable._connect_ports(p1, p1)
	_eq("a machine cabled to itself is not recorded", cable._linked.size(), 0)

	# Disconnect has to survive the ends being gone. A machine can be carried out
	# of the room, or the room torn down, between joining and pulling.
	cable._linked = [
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m2.libretro, "port": 0},
	]
	m2.libretro.free()
	cable._disconnect()
	_eq("disconnect clears even when an end is gone", cable._linked.size(), 0)

	m1.queue_free()
	m2.queue_free()
	cable.queue_free()
	await get_tree().process_frame



# ── The scenes ──────────────────────────────────────────────────────────────
# Importing a scene proves it parses. Only building one proves the scripts and
# node types actually fit together.

const CABLE_SCENE := "res://Scenes/Objects/cables/link_cable.tscn"
const PORT_SCENE := "res://Scenes/Objects/cables/link_port.tscn"


func _test_cable_scene() -> void:
	var packed: PackedScene = load(CABLE_SCENE)
	_ok("the cable scene loads", packed != null)
	if packed == null:
		return
	var cable := packed.instantiate() as LinkCable
	_ok("it builds as a LinkCable", cable != null)
	if cable == null:
		return
	add_child(cable)

	var a := cable.get_node_or_null("PlugA0") as LinkPlug
	var b := cable.get_node_or_null("PlugB0") as LinkPlug
	_ok("both ends are link plugs", a != null and b != null)
	if a == null or b == null:
		cable.queue_free()
		return

	# One cord, so CompositeCable takes its single-rope path. A miscount here
	# would send it down the ribbon path looking for a breakout that does not
	# exist.
	_eq("it is a one-cord lead", cable.cord_count(), 1)
	_ok("it has a rope", cable.get_node_or_null("VerletRope") != null)

	# Both ends answer to the group their sockets require, which is the whole of
	# what decides where this lead will go.
	_ok("end A is in the link group", a.is_in_group("link_plug"))
	_ok("end B is in the link group", b.is_in_group("link_plug"))

	# The trap the two-mesh split exists for. RcaPlug derives the cord's exit from
	# PlugTip's AABB alone, so folding the keyed nose into that mesh would drag
	# the anchor forward of the mating face and run the tail out through the
	# barrel. The shell is 20 mm deep behind an origin that sits on that face, so
	# the cord has to leave 20 mm back.
	_ok("the cord leaves the back of the shell",
		absf(a.cable_anchor.z - -0.02) < 0.0005,
		"anchor z = %f" % a.cable_anchor.z)
	_ok("and on the axis", absf(a.cable_anchor.x) < 0.0005 and absf(a.cable_anchor.y) < 0.0005)

	# The two ends are not interchangeable and the shells have to say so. End A is
	# always handed to LinkConnect first, so its machine owns the clock, and on
	# the real cable that end is purple against a grey secondary. CompositeCable
	# would repaint both from the cord palette, which is why LinkCable overrides
	# _tint_plug — drop that override and this goes red rather than silently
	# turning a two-tone lead into one colour.
	var ma := (a.get_node("PlugTip") as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	var mb := (b.get_node("PlugTip") as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	_ok("both shells are painted", ma != null and mb != null)
	if ma != null and mb != null:
		_ok("the two ends are different colours", ma.albedo_color != mb.albedo_color,
			"both %s" % str(ma.albedo_color))
		# The master end is the purple one, so it has to be the bluer of the two.
		_ok("end A is the purple shell", ma.albedo_color.b > ma.albedo_color.r + 0.1,
			"A = %s" % str(ma.albedo_color))
		_ok("end B is the grey shell", absf(mb.albedo_color.b - mb.albedo_color.r) < 0.06,
			"B = %s" % str(mb.albedo_color))

	cable.queue_free()
	await get_tree().process_frame


func _test_port_scene() -> void:
	var packed: PackedScene = load(PORT_SCENE)
	_ok("the port scene loads", packed != null)
	if packed == null:
		return
	var port := packed.instantiate() as LinkPort
	_ok("it builds as a LinkPort", port != null)
	if port == null:
		return
	add_child(port)

	# The gate, as the socket actually enforces it rather than as the class
	# merely reports it.
	_eq("it requires a link plug", port.snap_require, "link_plug")

	# Named LinkJack rather than RcaJack on purpose, so the inherited channel
	# tinting cannot repaint a socket that carries no signal.
	_ok("its jack is out of RcaPort's reach", port.get_node_or_null("RcaJack") == null)
	_ok("but it has one", port.get_node_or_null("LinkJack") != null)

	port.queue_free()
	await get_tree().process_frame


## A machine that answers the question LinkPort walks for, without being one.
class _StubMachine extends Node3D:
	var libretro: Libretro = null

	func get_libretro_node() -> Libretro:
		return libretro
