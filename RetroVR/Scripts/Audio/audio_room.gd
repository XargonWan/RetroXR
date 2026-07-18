extends Node
## Arcade room acoustics. Spawns one large Area3D reverb zone (as an autoload it
## persists across scene changes) so every spatialised source with area_mask 1 —
## the emulator cabinets, the DVD/VCR at their TVs, the CD/cassette decks — sends
## a copy of its audio to the wet-only "Reverb" bus in default_bus_layout.tres.
## The dry signal still plays straight to Master, so this only adds room tail; it
## never replaces the direct sound.
##
## A single uniform zone (rather than per-space zones) is deliberate: the arcade
## is one room, and a uniform tail is both cheaper and free of seams as you walk
## around. The mechanism extends to multiple zones later if distinct spaces are
## added — just add more Area3Ds with their own reverb_bus_amount.

## Half-extents of the reverb box (m). Large enough to enclose the whole arcade
## and the player at all times, centred on the world origin.
const ROOM_HALF_EXTENT := Vector3(30.0, 12.0, 30.0)

## How much of each source is sent to the reverb bus (0..1) and how uniformly it
## applies across the zone.
const REVERB_AMOUNT := 0.55
const REVERB_UNIFORMITY := 0.7


func _ready() -> void:
	var area := Area3D.new()
	area.name = "RoomReverbZone"
	# Sit on the "World" audio layer that the presets' area_mask (1) matches.
	area.collision_layer = 1
	area.collision_mask = 0
	# Reverb is applied by the audio server from the zone shape; no physics body
	# monitoring is needed, so keep it inert to the physics world.
	area.monitoring = false
	area.monitorable = false
	area.reverb_bus_enabled = true
	area.reverb_bus_name = &"Reverb"
	area.reverb_bus_amount = REVERB_AMOUNT
	area.reverb_bus_uniformity = REVERB_UNIFORMITY

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = ROOM_HALF_EXTENT * 2.0
	shape.shape = box
	area.add_child(shape)
	add_child(area)
