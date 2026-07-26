## PageSfx — the sound of paper moving, generated rather than shipped.
##
## RetroVR has no sound-effect assets at all: every AudioStreamPlayer3D in the
## project is a continuous media stream fed by libVLC or an emulator core. A
## page turn is broadband noise under an envelope, which synthesises convincingly
## in a few lines, so this stays an asset-free node.
##
## Players are pooled the way godot-xr-tools' movement_footstep does it — riffling
## quickly through a book overlaps several turns, and one player would cut each
## sound off with the next.
class_name PageSfx
extends Node3D

const MIX_RATE := 22050
const POOL_SIZE := 3

var _riffle: AudioStreamWAV
var _settle: AudioStreamWAV
var _pool: Array[AudioStreamPlayer3D] = []


func _ready() -> void:
	_riffle = _make_riffle()
	_settle = _make_settle()
	for i in POOL_SIZE:
		var player := AudioStreamPlayer3D.new()
		player.unit_size = 0.35
		player.max_db = -6.0
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.max_distance = 6.0
		add_child(player)
		_pool.append(player)


## Paper sweeping past paper. `speed` scales pitch so a fast flick sounds
## sharper than a slow drag.
func play_riffle(speed: float = 1.0) -> void:
	_play(_riffle, clampf(speed, 0.7, 1.5), -3.0)


## The soft slap of a page landing on the stack.
func play_settle() -> void:
	_play(_settle, randf_range(0.94, 1.06), -6.0)


func _play(stream: AudioStreamWAV, pitch: float, db: float) -> void:
	for player in _pool:
		if player.playing:
			continue
		player.stream = stream
		player.pitch_scale = pitch
		player.volume_db = db
		player.play()
		return


## Shape white noise into paper: difference it to brighten, then one-pole
## low-pass so it sits in the 2-6 kHz band a page actually occupies.
func _shape(count: int, hp: float, lp_k: float, envelope: Callable) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	var data := PackedByteArray()
	data.resize(count * 2)
	var prev := 0.0
	var lp := 0.0
	for i in count:
		var white := rng.randf_range(-1.0, 1.0)
		var bright := white - prev * hp
		prev = white
		lp += (bright - lp) * lp_k
		var sample: float = lp * float(envelope.call(float(i) / float(count)))
		data.encode_s16(i * 2, int(clampf(sample, -1.0, 1.0) * 32000.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav


func _make_riffle() -> AudioStreamWAV:
	# A swell rather than a hit — the sheet is in motion the whole time — with a
	# slow flutter over it so it reads as many leaves rather than one surface.
	return _shape(int(MIX_RATE * 0.30), 0.85, 0.45, func(t: float) -> float:
		return pow(sin(PI * t), 1.4) * (0.72 + 0.28 * sin(t * 130.0)) * 0.55)


func _make_settle() -> AudioStreamWAV:
	# Duller and shorter: a sheet dropping the last millimetre onto the stack.
	return _shape(int(MIX_RATE * 0.13), 0.35, 0.14, func(t: float) -> float:
		return exp(-t * 16.0) * 0.7)
