## CablePlug — the grabbable end of a cable that snaps into a TV's CompositePort.
## Must be in the "composite_plug" group so the TV's snap zone accepts it.
## Holds a back-reference to the parent RetroSystem.
class_name CablePlug
extends XRToolsPickable


## The system this cable belongs to (set by system.gd when cable is instantiated)
var _system: RetroSystem = null


func _ready() -> void:
	super._ready()
	# Add to the snap group so TV's CompositePort (snap_require = "composite_plug") accepts us
	add_to_group("composite_plug")


## Returns the system this cable belongs to
func get_system() -> RetroSystem:
	return _system


## Set the owning system (called by the system when creating the cable)
func set_system(system: RetroSystem) -> void:
	_system = system
