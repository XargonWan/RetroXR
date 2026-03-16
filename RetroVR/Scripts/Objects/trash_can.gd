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
			# Released inside the zone → delete it.
			_objects_in_trash.erase(body)
			_set_trash_highlight(pickable, false)
			print("[TrashCan] deleting '%s'" % pickable.name)
			pickable.queue_free()


func _set_trash_highlight(pickable: XRToolsPickable, in_trash: bool) -> void:
	for child in pickable.get_children():
		if child is PickableHighlight:
			child.set_trash_mode(in_trash)
			return
