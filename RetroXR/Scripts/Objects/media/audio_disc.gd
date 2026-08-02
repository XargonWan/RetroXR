## AudioDisc — a physical audio CD that snaps into a CDPlayer's slot and carries
## the path to a music album (a folder of audio tracks, or a single audio file).
## Group "audio_disc" is what lets the player's slot accept it. Mirrors DVDDisc.
class_name AudioDisc
extends XRToolsPickable

## Path to the album: a folder of audio files, or a single audio file.
@export var album_path: String = "":
	set(value):
		album_path = value

## Human-readable label printed on the disc face.
@export var album_label: String = "":
	set(value):
		album_label = value
		_update_label()

@onready var _label: Label3D = get_node_or_null("DiscLabel")


func _ready() -> void:
	super._ready()
	add_to_group("audio_disc")
	_update_label()


func get_album_path() -> String:
	return album_path


## Netplay: show transfer progress on the disc face (empty string restores the
## album label). Called by NetObjectSync while fetching the album over the wire.
func net_set_download_status(status: String) -> void:
	if _label:
		_label.text = album_label if status.is_empty() else status


func _update_label() -> void:
	if _label:
		_label.text = album_label
