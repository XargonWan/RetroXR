## TrashCan — a pickable trash can that deletes objects dropped inside it.
## When a held XRToolsPickable enters the TrashArea, its PickableHighlight turns red.
## Releasing the object while it is inside the area deletes it.
class_name TrashCan
extends XRToolsPickable

@onready var _trash_area: Area3D = $TrashArea

# Pickables currently tracked as "in trash" (held and inside the detection zone).
# key: XRToolsPickable node, value: true (used as a set)
var _objects_in_trash: Dictionary = {}


func _ready() -> void:
	super._ready()


func _process(_delta: float) -> void:
	# Build the current set of all pickables (held or not) overlapping the zone.
	# Polling is more reliable than body_entered/exited for kinematically moved bodies.
	var in_area: Dictionary = {}
	for body in _trash_area.get_overlapping_bodies():
		if body == self:
			continue
		var pickable := body as XRToolsPickable
		if pickable:
			in_area[pickable] = true

	# Track newly entered held pickables → turn red.
	for body in in_area.keys():
		var pickable := body as XRToolsPickable
		if pickable.is_picked_up() and not _objects_in_trash.has(pickable):
			_objects_in_trash[pickable] = true
			_set_trash_highlight(pickable, true)
			print("[TrashCan] '%s' entered trash zone" % pickable.name)

	# Handle existing tracked pickables.
	for body in _objects_in_trash.keys().duplicate():
		if not is_instance_valid(body):
			_objects_in_trash.erase(body)
			continue
		var pickable := body as XRToolsPickable
		if not in_area.has(body):
			# Left the detection zone — restore normal highlight.
			_objects_in_trash.erase(body)
			_set_trash_highlight(pickable, false)
			print("[TrashCan] '%s' left trash zone" % pickable.name)
		elif not pickable.is_picked_up():
			# Released inside the zone → delete it (with its dependents).
			_objects_in_trash.erase(body)
			_set_trash_highlight(pickable, false)
			print("[TrashCan] deleting '%s'" % pickable.name)
			_delete_with_dependents(pickable)


## Delete a trashed object together with everything it owns, and release
## everything it merely holds:
## - a running system is powered off first (clean emulation-thread shutdown)
## - its cable (rope + plug live at the scene root, not under the pickable)
##   is freed, plug dropped out of any snap zone first
## - media snapped into its slots (cartridge/disc/tape/memory card) is freed
##   too — otherwise it stays frozen in mid-air where the slot was
## - foreign plugs snapped into its ports belong to OTHER devices' cables and
##   are only dropped, never freed
## Bare plugs themselves are not deletable — freeing one would orphan its
## owner's rope — so they just fall out of the can.
func _delete_with_dependents(pickable: XRToolsPickable) -> void:
	if pickable is CablePlug or pickable is ControllerPlug:
		print("[TrashCan] '%s' is a cable plug — not deletable" % pickable.name)
		return

	if pickable is RetroSystem and (pickable as RetroSystem).is_powered_on:
		(pickable as RetroSystem).power_off()

	# Release or free everything snapped into this object's zones.
	for zone in pickable.find_children("*", "XRToolsSnapZone", true, false):
		var held: Node3D = zone.picked_up_object
		if held == null or not is_instance_valid(held):
			continue
		zone.drop_object()
		if held is CablePlug or held is ControllerPlug or held.is_in_group("controller_plug"):
			continue   # another device's cable end — released, not deleted
		print("[TrashCan] deleting snapped '%s'" % held.name)
		if held.has_method("drop_and_free"):
			held.call("drop_and_free")
		else:
			held.queue_free()

	# Free the object's own cable (spawned at the scene root).
	var cable: Variant = pickable.get("_cable_instance")
	if cable is Node and is_instance_valid(cable):
		for plug_name: String in ["CablePlug", "ControllerPlug"]:
			var plug := (cable as Node).get_node_or_null(plug_name)
			if plug and plug.has_method("drop"):
				plug.call("drop")
		(cable as Node).queue_free()

	if pickable.has_method("drop_and_free"):
		pickable.call("drop_and_free")
	else:
		pickable.queue_free()


func _set_trash_highlight(pickable: XRToolsPickable, in_trash: bool) -> void:
	for child in pickable.get_children():
		if child is PickableHighlight:
			child.set_trash_mode(in_trash)
			return
