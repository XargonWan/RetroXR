## InputReceiver — the dongle every receiver is made of.
##
## A receiver is a small box on a 1 m lead that seats in a machine's controller
## port and forwards ONE real input device to it, with nothing held. It exists so
## your hands stay free: put the Quest controllers down and the room still works
## while the game runs on the pad, keyboard or mouse in front of you.
##
## The three subclasses differ only in what they forward:
##   PadReceiver       one named gamepad, chosen when it was spawned
##   KeyboardReceiver  the host keyboard
##   MouseReceiver     the host mouse
##
## The object IS the binding. Nothing is selected, captured or arbitrated — seat
## one per destination, unplug it to stop. Two keyboard receivers in two machines
## is a fan-out, not an ambiguity: there is one real keyboard and both ports get
## it, which is what a splitter does and what you asked for by seating two.
##
## Structurally this is RetroMultitap, not RetroController: an object that lives
## in a controller port without ever being the thing you hold. Cable, plug and
## port plumbing are borrowed from that file almost verbatim.
class_name InputReceiver
extends XRToolsPickable

const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")

## Every live receiver. Membership is the only bookkeeping any of this needs, and
## Godot drops a freed node from its groups by itself — so there is no claim to
## release and nothing to leak when one is binned mid-session.
const GROUP := &"input_receiver"

## Long enough to sit the receiver on the shelf beside the console rather than
## have it dangle off the port, short enough not to festoon the room. The
## controller lead it is built from is 1.80 m, which is a pad's reach to a sofa —
## a receiver never needs that because the DEVICE is what travels.
const LEAD_LENGTH := 1.0

## Which console moulds its own controller connector. A receiver is universal, so
## unlike every other peripheral it cannot know its plug until it seats — on
## plug-in it adopts the connector of whatever it went into, and drops back to the
## generic one when pulled out.
##
## These mirror the plug_mesh_path exports on the pads that wear them
## (nes_controller.tscn, atari_2600_cx40.tscn). Two places now know each
## connector; a third would be one too many, so if this grows past a handful ask
## the console for its connector instead of listing it here.
const PORT_CONNECTORS := {
	"nes": "res://imported-assets/controllers/nes/nes_controller_plug.res",
	"atari2600": "res://Scenes/Objects/controllers/atari/atari_2600_plug_cx40.res",
}

## Announced to the console when the plug seats. Overridden per subclass.
var device_type: int = 0

## Universal — RetroSystem._accepts_plug reads this off the plug, and an empty
## string fits every console's port.
var systemid: String = ""

# Port connection state (the console port this receiver's plug occupies).
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable (same pattern as RetroController / RetroMultitap).
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
var _pending_port_restore: Dictionary = {}

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _led: MeshInstance3D = $Led
@onready var _label: Label3D = $NameLabel
@onready var _glyph: Label3D = $GlyphLabel


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	add_to_group(GROUP)
	refresh_label()
	set_led(false)
	_spawn_cable()


# ── What a subclass fills in ──────────────────────────────────────────────────

## What this receiver prints on its own case.
func receiver_label() -> String:
	return "RECEIVER"


## The device it forwards, printed as Nerd Font glyphs. One symbol says at a
## glance what a box on the floor is for, which a three-letter word does not, and
## the codepoints come from the shared TransportGlyphs table so a dongle and the
## held device's own capture icon cannot drift into two different symbols.
##
## Rendered text rather than a single key, because the wireless devices prefix a
## Bluetooth mark to theirs.
func receiver_glyph() -> String:
	return ""


## True while it has a device to forward. Drives the LED: red means this dongle
## is doing nothing, which is a state and not an error — a receiver restored into
## a room whose pad is switched off says exactly that until the pad comes back.
func is_bound() -> bool:
	return true


## True when seated in a port AND holding a device: the gate every subclass tests
## before writing to a core.
func is_live() -> bool:
	return _connected_system != null and _port_index >= 0 and is_bound()


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_adopt_connector(system.systemid)
	set_led(is_bound())
	print("[%s] -> %s port %d" % [receiver_label(), system.systemid, port_index])


func on_unplugged() -> void:
	on_going_idle()
	_connected_system = null
	_port_index = -1
	_adopt_connector("")
	set_led(false)


## Called before the port is let go, for a subclass with something to quieten
## (a rumbling pad, a key still held down).
func on_going_idle() -> void:
	pass


## The console this receiver is plugged into, or null. Read by ScenePersistence,
## which needs the machine to ask it for the cabinet socket.
func get_connected_system() -> RetroSystem:
	return _connected_system if is_instance_valid(_connected_system) else null


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


## Wear the connector of the console we are in — an NES 7-pin, an Atari DE-9 —
## and the generic moulding when we are in nothing. An unlisted console keeps the
## generic plug rather than the last console's, which is why this is called with
## "" on unplug rather than simply skipped.
func _adopt_connector(sysid: String) -> void:
	if _cable_plug == null or not is_instance_valid(_cable_plug):
		return
	_cable_plug.set_plug_mesh(str(PORT_CONNECTORS.get(sysid, "")))
	# And move the cord's end with it. set_plug_mesh recomputes cable_anchor for
	# the new shell, and a rope still ending at the plug's ORIGIN ends on the
	# mating face — which, seated, is buried inside the socket, so the cord looks
	# detached from the connector it is supposed to leave. Every other cabled
	# peripheral sets this once at spawn because its connector never changes; a
	# receiver adopts a new one on every plug-in, so it is re-applied here.
	_apply_cable_anchor()


func _apply_cable_anchor() -> void:
	if _cable_rope == null or not is_instance_valid(_cable_rope) or _cable_plug == null:
		return
	_cable_rope.end_anchor_offset = _cable_plug.cable_anchor
	# And which way it leaves, so an angled connector can say so in its asset
	# rather than in code. Note plug_exit_axis is one value for the whole rope:
	# a lead with a different connector at each end would need a per-end axis in
	# VerletRope, which nothing wants yet.
	_cable_rope.plug_exit_axis = _cable_plug.cable_exit_axis


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	# The lead leaves the back of the case.
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.set_rope_length(LEAD_LENGTH)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_apply_cable_anchor()
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


func _physics_process(_delta: float) -> void:
	# Cable rope clamp (same as RetroController / RetroMultitap).
	if _cable_plug != null and _cable_attach_point != null and _max_rope_length > 0.0 \
			and not _cable_plug.is_picked_up() and _connected_system == null:
		var attach_pos := _cable_attach_point.global_position
		var diff := _cable_plug.global_position - attach_pos
		var dist := diff.length()
		if dist > _max_rope_length:
			var dir := diff / dist
			_cable_plug.global_position = attach_pos + dir * _max_rope_length
			var outward := dir.dot(_cable_plug.linear_velocity)
			if outward > 0.0:
				_cable_plug.linear_velocity -= dir * outward


# ── Presentation ──────────────────────────────────────────────────────────────

## Red while this dongle is forwarding nothing, lit while it is. It explains
## itself without a panel, which is the whole reason it is an object rather than
## a setting.
func set_led(bound: bool) -> void:
	if _led == null:
		return
	var mat := _led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = Color(0.15, 0.85, 0.30) if bound else Color(0.85, 0.12, 0.12)
	mat.emission = mat.albedo_color


func refresh_label() -> void:
	if _label != null:
		_label.text = receiver_label()
	if _glyph != null:
		var glyphs := receiver_glyph()
		_glyph.visible = not glyphs.is_empty()
		if not glyphs.is_empty():
			# The font is a FontVariation chaining the symbol font behind the
			# project default; an unchained label renders the codepoint as tofu.
			_glyph.font = TransportGlyphs.font()
			_glyph.text = glyphs


# ── Teardown ──────────────────────────────────────────────────────────────────

## Take the lead with it. The plug is a separate scene parented to the room, so
## freeing only the body would leave a cord hanging off a freed anchor — the same
## rule RetroController's cable follows.
func drop_and_free() -> void:
	if _cable_plug != null and is_instance_valid(_cable_plug):
		_cable_plug.drop()
	if _cable_instance != null and is_instance_valid(_cable_instance):
		_cable_instance.queue_free()
	queue_free()
