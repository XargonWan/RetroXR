## QualityManager — Autoload singleton that adapts visual quality per platform.
##
## Desktop VR gets high bloom and ambilight.
## Quest 3 gets stripped-down glow, depth fog only, and reduced lighting.
extends Node


## Preloaded environment resources
@export var env_desktop: Environment = preload("res://Resources/env_desktop.tres")
@export var env_quest: Environment = preload("res://Resources/env_quest.tres")

## Ambilight sampling interval (frames between color updates)
var ambilight_interval: int = 10

var _desktop: bool


func _ready() -> void:
	_desktop = OS.get_name() != "Android"
	ambilight_interval = 10 if _desktop else 30
	apply_environment()
	_adjust_lights()


## Apply the platform-appropriate environment to the WorldEnvironment node.
## Called automatically in _ready() and by SceneManager when returning to arcade.
func apply_environment() -> void:
	var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_env:
		world_env.environment = env_desktop if _desktop else env_quest


func is_desktop() -> bool:
	return _desktop


func _adjust_lights() -> void:
	# Ceiling lights — dimmer for arcade feel, extra dim on Quest
	var ceil_energy := 0.8 if _desktop else 0.6
	for light in get_tree().get_nodes_in_group("ceiling_light"):
		if light is Light3D:
			light.light_energy = ceil_energy

	# Neon sign lights — reduced on Quest
	var neon_energy := 1.5 if _desktop else 0.5
	for light in get_tree().get_nodes_in_group("neon_light"):
		if light is Light3D:
			light.light_energy = neon_energy
