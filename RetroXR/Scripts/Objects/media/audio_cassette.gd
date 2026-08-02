## AudioCassette — a physical audio tape that snaps into a CassettePlayer's slot
## and carries the path to a music album (a folder of audio tracks, or a single
## audio file). Group "audio_cassette" is what lets the player's slot accept it.
## Mirrors VCRTape, but for audio.
class_name AudioCassette
extends XRToolsPickable

## Path to the album: a folder of audio files, or a single audio file.
@export var album_path: String = ""

## Display label (album name, shown on the cassette face).
@export var album_label: String = "":
	set(v):
		album_label = v
		_update_label()


func _ready() -> void:
	super._ready()
	add_to_group("audio_cassette")
	_update_label()


func _update_label() -> void:
	var lbl := get_node_or_null("CassetteLabel") as Label3D
	if lbl:
		lbl.text = album_label


## Netplay: show transfer progress on the cassette label (empty string restores
## the album label). Called by NetObjectSync while fetching the album.
func net_set_download_status(status: String) -> void:
	var lbl := get_node_or_null("CassetteLabel") as Label3D
	if lbl:
		lbl.text = album_label if status.is_empty() else status


func get_album_path() -> String:
	return album_path
