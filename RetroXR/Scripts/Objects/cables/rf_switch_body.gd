## The RXR-003's grey box: the part a player actually picks up.
##
## A pickable and nothing else. Every routing decision belongs to the RfSwitch root
## above it, which is a CompositeCable and already knows how to answer them — this
## exists because a lead has no body to grab and the switch does.
class_name RfSwitchBody
extends XRToolsPickable

const HINT_HEIGHT := 0.07

var _hint: HeldHint = null


func _ready() -> void:
	super._ready()
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)


func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)


func _on_dropped_signal(_pickable: Node3D) -> void:
	if _hint:
		_hint.on_dropped()


## Bin the whole switch, not just the box.
##
## TrashCan._delete_with_dependents calls this on any pickable that has it and
## queue_frees it otherwise, and freeing the box alone would leave the root, both
## ropes and both plugs alive with a freed anchor node — the ropes read their
## anchors' global transforms every frame. Binning a PLUG already takes the whole
## switch with it, because plug.cable points at the root and TrashCan._free_lead
## follows it; this is the same rule for the other handle.
func drop_and_free() -> void:
	var root := get_parent()
	if root != null and is_instance_valid(root) and root.has_method("drop_and_free"):
		root.call("drop_and_free")
	else:
		queue_free()
