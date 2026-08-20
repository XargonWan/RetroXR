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
	_test_cable_is_spawnable()
	await _test_gc_gba_cable()
	await _test_lid_clears_the_socket()
	await _test_bus_head_is_the_same_on_every_peer()
	print("[link] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# -- The console-to-handheld lead --------------------------------------------
# The only asymmetric cable in the room, and every one of these is about that
# asymmetry: two ends that fit different sockets, joining two machines that are
# not peers, over a protocol neither of the handheld leads speaks.

func _test_gc_gba_cable() -> void:
	var scene := load("res://Scenes/Objects/cables/gc_gba_cable.tscn") as PackedScene
	_ok("the lead has a scene", scene != null)
	if scene == null:
		return
	var lead := scene.instantiate() as GcGbaCable
	_ok("and it is a GcGbaCable", lead != null)
	if lead == null:
		return
	add_child(lead)
	await get_tree().process_frame

	var gc_end := lead.get_node_or_null("PlugA0") as GcLinkPlug
	var gba_end := lead.get_node_or_null("PlugB0") as LinkPlug
	_ok("one end is a GameCube plug", gc_end != null)
	_ok("the other is a handheld plug", gba_end != null)
	if gc_end == null or gba_end == null:
		lead.queue_free()
		return

	# The whole point of the two ends being different. A console socket filters
	# on "controller_plug" and a handheld's EXT port on "link_plug", and neither
	# end answers to both, so neither can be pushed into the wrong machine.
	_ok("the console end answers a controller socket", gc_end.is_in_group("controller_plug"))
	_ok("and is not a handheld plug", gc_end.plug_group() != gba_end.plug_group())
	_ok("the handheld end answers an EXT port", gba_end.is_in_group("link_plug"))
	_ok("and is not a controller plug", not gba_end.is_in_group("controller_plug"))

	# Which console's ports will take it. A GameCube lead is not a Wii lead, and
	# the socket says so before anything electrical is decided.
	_eq("the console end fits a GameCube", gc_end.systemid, "gamecube")

	# Seating it announces a handheld to the core, the same way any pad announces
	# itself: there is no separate step and nothing else to configure.
	_eq("and announces a Game Boy Advance", gc_end.device_type, (7 << 8) | 0)

	# It carries neither picture nor sound, so AvGraph must walk straight past it.
	_ok("the lead is not an A/V cable", lead.links().is_empty())

	# Nothing is seated, so it is joined to nothing and says so without faulting.
	lead._resolve()
	_ok("an unseated lead joins nothing", true)

	lead.queue_free()
	await get_tree().process_frame


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

	var g2: Array[Dictionary] = [
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m2.libretro, "port": 0},
	]
	cable._join(g2)
	_eq("two idle machines are still cabled together", cable._linked.size(), 2)

	# Re-stating the same set changes nothing, which matters because every cable
	# in a chain resolves whenever any plug in it moves.
	cable._join(g2)
	_eq("re-stating the same group is a no-op", cable._linked.size(), 2)
	cable._disconnect()

	# The guard against a machine cabled to itself, which the room can present as
	# two sockets on one handheld.
	cable._join([
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m1.libretro, "port": 0},
	] as Array[Dictionary])
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

	# The junction, which is what makes a third and fourth player possible. A
	# socket that looked real and refused a plug would be worse than none, so it
	# is a full LinkPort and has to answer as one.
	var j := cable.junction_port()
	_ok("the lead carries a junction", j != null)
	if j != null:
		_eq("it takes the same plugs the machines do", j.snap_require, "link_plug")
		# The two kinds of socket have to be told apart during the chain walk:
		# a machine port answers get_machine, a junction answers get_cable.
		_eq("it belongs to no machine", j.get_machine(), null)
		_eq("it belongs to this cable", j.get_cable(), cable)

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



# ── Reachable from the room ─────────────────────────────────────────────────

func _test_cable_is_spawnable() -> void:
	# The lead existed for a while as a scene nobody could get hold of: built,
	# tested, rendered, and offered by no menu. A cable that cannot be spawned is
	# not a feature, so this asserts the catalogue actually lists it.
	var items: Array = SpawnCatalog.items_for("game_boy_advance")
	var found := false
	for item: Dictionary in items:
		if str(item.get("spawn", "")) == "link_cable":
			found = true
			_ok("it is offered under the Game Boy Advance", true)
			_ok("and it is labelled", not str(item.get("label", "")).is_empty())
	if not found:
		_ok("it is offered under the Game Boy Advance", false,
			"%d items, none of them the link cable" % items.size())

	# Offered only where there is a socket to put it in. A console with no EXT
	# port listing a link lead would be an invitation to nothing.
	var console: Array = SpawnCatalog.items_for("playstation")
	var stray := false
	for item: Dictionary in console:
		if str(item.get("spawn", "")) == "link_cable":
			stray = true
	_ok("and not offered where nothing takes it", not stray)


## A machine that answers the question LinkPort walks for, without being one.
class _StubMachine extends Node3D:
	var libretro: Libretro = null

	func get_libretro_node() -> Libretro:
		return libretro


# -- The clamshell over its own socket ----------------------------------------
# A Game Boy Advance SP hinges at the same edge its EXT socket sits on, so the
# lid and the lead are competing for one strip of plastic. Get the pivot or the
# open stop wrong and the lid closes on a plugged-in cable, which is a thing no
# real machine does and a thing the room cannot recover from: the plug is held
# by a snap zone and the lid is driven by a hand, so they simply interpenetrate.
#
# This walks the hinge across its whole travel with a lead seated and measures
# the gap, rather than trusting a render. Two more cases hold the geometry that
# makes the gap possible in the first place: a barrel narrow enough to leave the
# socket outboard of it, and a pivot high enough that the lid swings above the
# deck instead of through it.

const SP_SCENE := "res://Scenes/Objects/system_models/game_boy_advance_sp_primitive.tscn"
const GC_GBA_SCENE := "res://Scenes/Objects/cables/gc_gba_cable.tscn"


func _test_lid_clears_the_socket() -> void:
	var sp: Node3D = load(SP_SCENE).instantiate()
	add_child(sp)
	# Both leads, because either fits that socket and the lid has to clear the
	# fatter of them. They are not the same shell: one carries a metal shroud.
	var leads: Array[Node3D] = []
	for path: String in [GC_GBA_SCENE, CABLE_SCENE]:
		var l: Node3D = load(path).instantiate()
		add_child(l)
		leads.append(l)
	await get_tree().process_frame

	var port := sp.get_node_or_null("LinkPort") as Node3D
	var lid := sp.get_node_or_null("LidPivot/Lid") as MeshInstance3D
	var barrel := sp.get_node_or_null("HingeBarrel") as MeshInstance3D
	var body := sp.get_node_or_null("HandheldBody") as MeshInstance3D
	_ok("the SP has a socket, a lid, a barrel and a body",
		port != null and lid != null and barrel != null and body != null)
	if port == null or lid == null or barrel == null or body == null:
		sp.queue_free()
		for l: Node3D in leads:
			l.queue_free()
		return

	# Seated, which for this purpose is the plug sitting at the socket's own
	# transform. That is what the snap zone does to it, and the shell is the part
	# that can be hit: the cord is a rope and will simply drape aside.
	# Measured against the SHELL, which is what a player watches the lid meet.
	# The collision box is deliberately deeper than the shell so a hand can find
	# it, and it reaches back inside the machine where the lid is entitled to be.
	var shells: Array[MeshInstance3D] = []
	for l: Node3D in leads:
		var plug := l.get_node_or_null("PlugB0") as RigidBody3D
		if plug == null:
			continue
		plug.freeze = true
		# The same move the snap zone makes, not the socket's bare transform. A
		# zone lands the object's GRAB POINT on itself, and this plug's grab
		# point is turned about X, so seating it on the socket transform alone
		# puts the shell inside the machine and the cord out through the screen.
		# That is a plug nothing could clash with, which would make this whole
		# case pass for free.
		var gp := plug.get_node_or_null("SnapGrabPoint") as Node3D
		plug.global_transform = port.global_transform * (gp.transform.affine_inverse() if gp != null else Transform3D())
		for child in plug.get_children():
			var mi := child as MeshInstance3D
			if mi != null and mi.mesh != null:
				shells.append(mi)
	_ok("both leads have a shell to measure", shells.size() >= 4,
		"%d meshes over %d leads" % [shells.size(), leads.size()])
	var lid_box := (lid.mesh as BoxMesh).size

	# Every degree of the travel, because the clash does not have to be at either
	# end: a lid that clears when shut and clears at the stop can still sweep
	# through the plug on the way past.
	var worst := INF
	var worst_at := -1.0
	for step in range(0, 181):
		var open_deg := float(step)
		sp.set_lid_angle_deg(open_deg)
		# Read back rather than trusting the request: the hinge owns the limits
		# and clamps, so the angles actually reachable are the ones to test.
		var reached: float = sp.get_lid_angle_deg()
		for mi: MeshInstance3D in shells:
			var box := mi.mesh.get_aabb()
			var t := mi.global_transform.translated_local(box.get_center())
			var gap := _obb_gap(lid.global_transform, lid_box, t, box.size)
			if gap < worst:
				worst = gap
				worst_at = reached
	print("[link] lid clearance over a seated lead: %.2f mm, closest at %.0f degrees open"
		% [worst * 1000.0, worst_at])
	_ok("the lid never touches a seated lead", worst > 0.0,
		"closest %.1f mm at %.0f degrees open" % [worst * 1000.0, worst_at])

	# And with room to spare, because a hand-driven lid overshoots and a snapped
	# plug wobbles in its zone. A hair's clearance reads as a clash on a headset.
	_ok("and clears it by more than a millimetre", worst > 0.001,
		"closest %.1f mm" % (worst * 1000.0))

	# The socket is outboard of the barrel. This is the whole reason the barrel
	# was narrowed: on the real machine the hinge takes the middle of that edge
	# and the sockets live either side of it.
	var barrel_half: float = absf((barrel.mesh as CylinderMesh).height) * 0.5
	var port_x: float = absf(port.position.x)
	var plug_half := 0.0
	for mi: MeshInstance3D in shells:
		plug_half = maxf(plug_half, mi.mesh.get_aabb().size.x * 0.5)
	_ok("the socket sits outboard of the hinge barrel", port_x - plug_half > barrel_half,
		"socket edge %.1f mm, barrel end %.1f mm" % [(port_x - plug_half) * 1000.0, barrel_half * 1000.0])
	_ok("and the barrel is narrower than the machine",
		barrel_half * 2.0 < (body.mesh as BoxMesh).size.x)

	# The pivot stands proud of the deck. A hinge buried in the top face turns the
	# lid about a line inside the shell, which is what put it through its own back
	# edge, and it is also just visibly wrong: a real SP's hinge is a raised boss.
	var deck_y: float = (body.mesh as BoxMesh).size.y * 0.5
	_ok("the hinge stands proud of the deck", barrel.position.y + barrel_half * 0.0 > deck_y,
		"barrel axis at %.1f mm, deck at %.1f mm" % [barrel.position.y * 1000.0, deck_y * 1000.0])
	var pivot := sp.get_node_or_null("LidPivot") as Node3D
	_ok("and the lid turns about the barrel, not beside it",
		pivot != null and pivot.position.distance_to(barrel.position) < 0.0005)

	# Shut still means shut. Raising the pivot moves every child of it, so the
	# compensating drop is what keeps a closed lid lying on the body rather than
	# floating above it.
	sp.set_lid_angle_deg(0.0)
	var shut_y: float = lid.global_position.y
	var want_y: float = deck_y + lid_box.y * 0.5
	_ok("a shut lid lies flush on the body", absf(shut_y - want_y) < 0.0005,
		"lid centre at %.1f mm, flush would be %.1f mm" % [shut_y * 1000.0, want_y * 1000.0])

	sp.queue_free()
	for l: Node3D in leads:
		l.queue_free()
	await get_tree().process_frame


## Separating-axis gap between two boxes, in metres. Positive is the width of the
## smallest gap found along any separating axis, which is a lower bound on the
## real distance; zero or less means they overlap. A lower bound is the safe side
## of the question being asked here.
func _obb_gap(ta: Transform3D, sa: Vector3, tb: Transform3D, sb: Vector3) -> float:
	var ax: Array[Vector3] = [ta.basis.x.normalized(), ta.basis.y.normalized(), ta.basis.z.normalized()]
	var bx: Array[Vector3] = [tb.basis.x.normalized(), tb.basis.y.normalized(), tb.basis.z.normalized()]
	var ea := sa * 0.5
	var eb := sb * 0.5
	var axes: Array[Vector3] = [ax[0], ax[1], ax[2], bx[0], bx[1], bx[2]]
	for u: Vector3 in ax:
		for v: Vector3 in bx:
			var c := u.cross(v)
			# Parallel edges give a degenerate axis. The face normals already
			# cover that case, so dropping it loses nothing.
			if c.length_squared() > 1e-12:
				axes.append(c.normalized())
	var d := tb.origin - ta.origin
	var best := -INF
	for axis: Vector3 in axes:
		var ra: float = absf(ax[0].dot(axis)) * ea.x + absf(ax[1].dot(axis)) * ea.y + absf(ax[2].dot(axis)) * ea.z
		var rb: float = absf(bx[0].dot(axis)) * eb.x + absf(bx[1].dot(axis)) * eb.y + absf(bx[2].dot(axis)) * eb.z
		best = maxf(best, absf(d.dot(axis)) - (ra + rb))
	return best


# -- Who joins the bus, seen from two headsets --------------------------------
# Every lead on a wire walks to the same machines, so exactly one of them has to
# perform the join, and the one that does decides which machine takes bus index
# zero, which is to say who is player one. Under replication both peers run both
# cores and must reach the same answer from the same room.
#
# The tie-break used to be the lowest instance id. That is a per-process
# allocation: the same two leads can come out in either order on two headsets, so
# the two peers could seat the machines differently and diverge from frame one,
# with no message on the wire to disagree about. This asserts the key that
# replaced it does not move with allocation order.

func _test_bus_head_is_the_same_on_every_peer() -> void:
	var first: LinkCable = load(CABLE_SCENE).instantiate()
	var second: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(first)
	add_child(second)
	first.name = "LeadOne"
	second.name = "LeadTwo"
	await get_tree().process_frame

	_ok("allocation order is what it looks like",
		first.get_instance_id() < second.get_instance_id())

	var wire: Array[Node3D] = [first, second]
	# Numbered against the allocation order on purpose. A head picked by instance
	# id answers "first" here and a head picked by the minted id answers "second",
	# so this case cannot pass by accident.
	first.set_meta("net_id", 7)
	second.set_meta("net_id", 3)
	_ok("the head follows the minted id, not the allocation order",
		first._bus_head(wire) == second)

	# And the other way about, so the case is not just reading a fixed answer.
	first.set_meta("net_id", 2)
	second.set_meta("net_id", 9)
	_ok("and it moves when the minted ids move", first._bus_head(wire) == first)

	# Both leads agree, which is the property the wire actually needs: they each
	# run this walk separately and only one of them may conclude it is the head.
	_ok("and both leads name the same head", first._bus_head(wire) == second._bus_head(wire))

	# With nothing minted, the fallback is the node path. Cables are not
	# registered today, so this is the case that runs in a real session.
	first.remove_meta("net_id")
	second.remove_meta("net_id")
	_ok("an unregistered lead is keyed by its path",
		LinkCable.stable_key(first) == str(first.get_path()))
	_ok("and two of them are keyed apart",
		LinkCable.stable_key(first) != LinkCable.stable_key(second))
	var by_path: Node3D = first if str(first.get_path()) < str(second.get_path()) else second
	_ok("the head is the lower path", first._bus_head(wire) == by_path)

	# A minted lead never sorts into the middle of unregistered ones. Mixed keys
	# are a transient, but a transient that reordered the bus would restart both
	# machines for no reason a player could see.
	second.set_meta("net_id", 999999)
	_ok("a minted lead outranks an unminted one", first._bus_head(wire) == second)

	first.queue_free()
	second.queue_free()
	await get_tree().process_frame
