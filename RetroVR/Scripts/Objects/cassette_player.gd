## CassettePlayer — a pickable cassette deck that plays an inserted audio tape
## (AudioCassette). A linear tape: play / pause / stop / ff / rew only (no track
## skip). Tracks in a multi-song album still auto-advance as the tape "plays
## through"; the remote shows the same reduced control set.
class_name CassettePlayer
extends RetroAudioPlayer


func _ready() -> void:
	_media_group = "audio_cassette"
	super._ready()
	add_to_group("cassette_player")
