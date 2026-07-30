class_name SpatialAudioEmitter
extends Node3D

## One spatialised sound source, with two interchangeable backends.
##
## SDK backend: HRTF voices from the Meta XR Audio SDK, mixed by the
## metaxr-audio GDExtension. Fallback backend: the AudioStreamPlayer3D +
## AudioStreamGenerator pair this project used everywhere before, with the same
## unit_size / max_distance values so nothing regresses when the SDK is absent.
##
## The backend is chosen once at _ready and never changes. Callers push stereo
## PCM and set a volume; they do not know or care which one is running.

## Half the distance between the left and right speakers, in metres. A TV or a
## hi-fi radiates from two points; a handheld is a single speaker, so leave this
## at 0.0 and one voice is used.
@export var speaker_separation: float = 0.0

## Godot's ATTENUATION_INVERSE_DISTANCE parameters, used by both backends so the
## two sound alike at a distance.
@export var unit_size: float = 3.0
@export var max_distance: float = 15.0

const _MUTE_DB := -80.0

var _use_sdk := false
var _volume := 1.0

# Engine.register_singleton from a GDExtension does not create a GDScript global
# identifier the way an autoload does, so the singleton has to be fetched and
# cached rather than referenced by bare name.
var _mx: Object = null

# SDK backend
var _voice_l := -1
var _voice_r := -1

# Fallback backend
var _player: AudioStreamPlayer3D = null
var _playback: AudioStreamGeneratorPlayback = null

# Where the sound should appear to come from. Defaults to this node, but a
# device can redirect it (the emulator's audio moves to whichever TV is showing
# the picture).
var _emit_origin := Vector3.ZERO
var _emit_override := false


func _ready() -> void:
	_use_sdk = _sdk_available()
	if _use_sdk:
		_voice_l = _mx.create_voice()
		if speaker_separation > 0.0:
			_voice_r = _mx.create_voice()
		# Out of voices: fall back rather than run silent.
		if _voice_l < 0:
			_use_sdk = false
	if not _use_sdk:
		_setup_fallback()
	set_process(true)


func _exit_tree() -> void:
	if _use_sdk:
		if _voice_l >= 0:
			_mx.destroy_voice(_voice_l)
		if _voice_r >= 0:
			_mx.destroy_voice(_voice_r)
		_voice_l = -1
		_voice_r = -1


func _sdk_available() -> bool:
	if not Engine.has_singleton("MetaXRAudio"):
		return false
	_mx = Engine.get_singleton("MetaXRAudio")
	return _mx != null and _mx.is_available()


func _setup_fallback() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = float(AudioServer.get_mix_rate())
	gen.buffer_length = 0.25
	_player = AudioStreamPlayer3D.new()
	_player.name = "AudioStreamPlayer3D"
	_player.stream = gen
	_player.unit_size = unit_size
	_player.max_distance = max_distance
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()


func _process(_delta: float) -> void:
	var origin := _emit_origin if _emit_override else global_position
	if _use_sdk:
		# The mixer skips the underlying SDK call when the position has not
		# changed, so writing this every frame is safe -- it saves a lock, and
		# most emitters here rewrite a position that never moved.
		_mx.set_voice_position(_voice_l, origin + _speaker_offset(-1.0))
		if _voice_r >= 0:
			_mx.set_voice_position(_voice_r, origin + _speaker_offset(1.0))
	elif _player != null and is_instance_valid(_player):
		_player.global_position = origin


func _speaker_offset(sign_x: float) -> Vector3:
	if _voice_r < 0 or speaker_separation <= 0.0:
		return Vector3.ZERO
	return global_transform.basis.x.normalized() * (sign_x * speaker_separation)


## Emit from somewhere other than this node's own position -- used when a
## console's sound should come from the TV it is plugged into.
func set_emit_position(pos: Vector3) -> void:
	_emit_origin = pos
	_emit_override = true


## Go back to emitting from this node.
func clear_emit_position() -> void:
	_emit_override = false


## How many frames the producer should hand over right now. Deliberately not
## "all the free space": queue depth is latency, and filling a large buffer to
## the brim is what makes the existing generator path carry ~250 ms.
func frames_wanted() -> int:
	if _use_sdk:
		return _mx.voice_frames_wanted(_voice_l)
	if _playback == null:
		return 0
	return _playback.get_frames_available()


## Push interleaved stereo. Deinterleaved into two voices when this emitter has
## separated speakers, summed to the single voice otherwise.
func push_stereo(frames: PackedVector2Array) -> void:
	if frames.is_empty():
		return
	if _use_sdk:
		# Passing -1 for the right voice downmixes in C++. Doing it here with a
		# per-sample GDScript loop cannot keep a 48 kHz ring fed and starves the
		# voice outright.
		_mx.push_stereo_frames(_voice_l, _voice_r, frames)
	elif _playback != null:
		_playback.push_buffer(frames)


## Drop anything still queued, so a device that stops and later restarts does
## not replay a stale tail.
func flush() -> void:
	if _use_sdk:
		_mx.flush_voice(_voice_l)
		if _voice_r >= 0:
			_mx.flush_voice(_voice_r)
	elif _player != null and is_instance_valid(_player):
		# The generator has no flush; restarting the stream is the equivalent.
		_player.stop()
		_player.play()
		_playback = _player.get_stream_playback()


## 0.0 .. 1.0. Keeps the -80 dB mute floor the device scripts already assume.
func set_volume(volume: float) -> void:
	_volume = clampf(volume, 0.0, 1.0)
	if _use_sdk:
		_mx.set_voice_gain(_voice_l, _volume)
		if _voice_r >= 0:
			_mx.set_voice_gain(_voice_r, _volume)
	elif _player != null:
		_player.volume_db = _MUTE_DB if _volume <= 0.0 else linear_to_db(_volume)


func get_volume() -> float:
	return _volume


## True when this emitter is running on the Meta XR Audio SDK rather than
## Godot's built-in panning. Probes assert on this.
func is_spatialised() -> bool:
	return _use_sdk
