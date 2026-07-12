## DVDDisc — a physical DVD that snaps into a DVDPlayer's slot and carries the
## path to a DVD image (a VIDEO_TS/ folder or an .iso/.img file). Mirrors VCRTape,
## but round. Group "dvd_disc" is what lets the player's slot accept it.
class_name DVDDisc
extends XRToolsPickable

## Path to the DVD image: a VIDEO_TS folder, or an .iso/.img file.
@export var dvd_path: String = "":
	set(value):
		dvd_path = value

## Human-readable label printed on the disc face.
@export var dvd_label: String = "":
	set(value):
		dvd_label = value
		_update_label()

@onready var _label: Label3D = $DiscLabel


func _ready() -> void:
	super._ready()
	add_to_group("dvd_disc")
	_update_label()


func get_dvd_path() -> String:
	return dvd_path


func _update_label() -> void:
	if _label:
		_label.text = dvd_label
