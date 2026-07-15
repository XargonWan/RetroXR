## CDPlayer — a pickable CD deck that plays an inserted audio CD (AudioDisc). Adds
## Prev/Next track skipping on top of the shared RetroAudioPlayer transport; the
## TV remote shows the full set (prev / play / pause / stop / ff / rew / next).
class_name CDPlayer
extends RetroAudioPlayer


func _ready() -> void:
	_media_group = "audio_disc"
	super._ready()
	add_to_group("cd_player")
