## Reusable spatial audio source for RetroVR's live-PCM devices (VCR, DVD, CD,
## cassette). Wraps an AudioStreamPlayer3D fed by an AudioStreamGenerator and folds
## in the shared tuning, dynamic occlusion, and optional "emit from another node"
## repositioning that every device used to hand-roll for itself.
##
## Typical use by a device:
##     _emitter = SpatialAudioEmitter.new()
##     add_child(_emitter)
##     _emitter.configure(mix_rate, SpatialAudioPresets.TABLETOP)
##     _emitter.set_occluder_exclude([self])   # don't self-occlude
##     ...
##     _emitter.start()                        # on play
##     var n := _emitter.frames_available()
##     _emitter.push(pcm_frames)               # each frame while playing
##     _emitter.set_volume_db(db)              # volume / scan-mute
##     _emitter.stop()                         # on stop
##
## Left unset, the emitter stays parented to the device and follows it around.
## set_follow(node) makes the sound emanate from another node instead (the VCR/DVD
## point theirs at the connected TV so the audio comes from the picture).
class_name SpatialAudioEmitter
extends Node3D

var _asp: AudioStreamPlayer3D = null
var _playback: AudioStreamGeneratorPlayback = null
var _follow: Node3D = null
var _exclude: Array = []

# Occlusion raycasts are cheap, but on the CPU-bound Quest we still only run them
# every few frames — inaudible at that rate, and it keeps the per-machine cost near
# zero when several devices play at once.
var _occ_accum := 0.0
const _OCC_INTERVAL_DESKTOP := 0.0    # every frame
const _OCC_INTERVAL_MOBILE := 0.10    # ~10 Hz on Android/Quest
var _occ_interval := _OCC_INTERVAL_DESKTOP


func _ready() -> void:
	_occ_interval = _OCC_INTERVAL_MOBILE if OS.get_name() == "Android" else _OCC_INTERVAL_DESKTOP


## Build the underlying player + generator and apply a SpatialAudioPresets preset.
## Call once, before start().
func configure(mix_rate: float, preset: Dictionary, buffer_length: float = 0.25) -> void:
	if _asp != null:
		return
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = mix_rate if mix_rate > 0.0 else 48000.0
	gen.buffer_length = buffer_length
	_asp = AudioStreamPlayer3D.new()
	_asp.name = "AudioStreamPlayer3D"
	_asp.stream = gen
	add_child(_asp)
	SpatialAudioPresets.apply(_asp, preset)


## Begin voicing and latch the generator playback so push() can feed it.
func start() -> void:
	if _asp == null:
		return
	_asp.play()
	_playback = _asp.get_stream_playback() as AudioStreamGeneratorPlayback


## Stop voicing and drop the playback.
func stop() -> void:
	if _asp:
		_asp.stop()
	_playback = null


## True while the generator playback is live and accepting frames.
func is_active() -> bool:
	return _playback != null


## Free generator frames the source may fill right now (0 if not started).
func frames_available() -> int:
	return _playback.get_frames_available() if _playback != null else 0


## Push decoded PCM into the generator (call with at most frames_available()).
func push(frames: PackedVector2Array) -> void:
	if _playback != null and frames.size() > 0:
		_playback.push_buffer(frames)


## Set the source level in decibels (device owns volume / scan-mute policy).
func set_volume_db(db: float) -> void:
	if _asp:
		_asp.volume_db = db


func get_volume_db() -> float:
	return _asp.volume_db if _asp else -80.0


## Emanate the sound from `target` instead of this node's own position (e.g. the
## connected TV). Pass null to go back to emitting from the device itself.
func set_follow(target: Node3D) -> void:
	_follow = target


## Bodies (CollisionObject3D or RID) the occlusion ray should ignore — normally
## the emitting device's own body so it doesn't muffle itself.
func set_occluder_exclude(bodies: Array) -> void:
	_exclude = bodies


func _process(delta: float) -> void:
	if _asp == null or not _asp.playing:
		return
	if _follow != null and is_instance_valid(_follow):
		global_position = _follow.global_position
	_occ_accum += delta
	if _occ_accum >= _occ_interval:
		SpatialAudioPresets.update_occlusion(_asp, _occ_accum, _exclude)
		_occ_accum = 0.0
