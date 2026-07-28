## QualityManager — Autoload singleton that adapts visual quality per platform.
##
## Desktop VR gets high bloom and ambilight.
## Quest 3 gets stripped-down glow, depth fog only, and reduced lighting.
##
## Also owns the user-facing graphics settings from the menu's GRAPHICS tab
## (MSAA, shadow quality), persisted to user://graphics_prefs.json.
extends Node

const PREFS_PATH := "user://graphics_prefs.json"

## Shadow tiers offered in the GRAPHICS tab. OFF is the original look: no light
## in the room casts a shadow at all.
enum ShadowQuality { OFF, LOW, MEDIUM, HIGH }

## Positional shadow atlas edge, soft-shadow filter and depth precision per tier.
## The directional atlas gets twice the edge — it covers the whole room in one
## map where the positional atlas is subdivided between lights.
const SHADOW_TIERS := {
	ShadowQuality.LOW: {
		"atlas": 1024,
		"filter": RenderingServer.SHADOW_QUALITY_HARD,
		"bits16": true,
	},
	ShadowQuality.MEDIUM: {
		"atlas": 2048,
		"filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"bits16": true,
	},
	ShadowQuality.HIGH: {
		"atlas": 4096,
		"filter": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"bits16": false,
	},
}

## Preloaded environment resources
@export var env_desktop: Environment = preload("res://Resources/env_desktop.tres")
@export var env_quest: Environment = preload("res://Resources/env_quest.tres")

## Ambilight sampling interval (frames between color updates)
var ambilight_interval: int = 10

## Viewport.MSAA_* level applied to the root (XR) viewport.
var msaa_3d: int = Viewport.MSAA_2X
var shadow_quality: ShadowQuality = ShadowQuality.OFF

var _desktop: bool


func _ready() -> void:
	_desktop = OS.get_name() != "Android"
	ambilight_interval = 10 if _desktop else 30
	msaa_3d = get_tree().root.msaa_3d
	# Quest is CPU-bound before shadows are even in the picture, so it starts
	# where it was; desktop gets the shadows this setting exists to provide.
	shadow_quality = ShadowQuality.MEDIUM if _desktop else ShadowQuality.OFF
	_load_prefs()
	apply_environment()
	_adjust_lights()
	apply_msaa()
	apply_shadow_quality()
	# Lights arrive with every scene load and every spawned TV or handheld, so
	# each one is configured as it enters the tree rather than swept for.
	get_tree().node_added.connect(_on_node_added)


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


# ── Graphics settings ─────────────────────────────────────────────────────────

func set_msaa(mode: int) -> void:
	msaa_3d = clampi(mode, Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
	apply_msaa()
	save_prefs()


func apply_msaa() -> void:
	get_tree().root.msaa_3d = msaa_3d as Viewport.MSAA


func shadows_enabled() -> bool:
	return shadow_quality != ShadowQuality.OFF


func set_shadow_quality(level: int) -> void:
	shadow_quality = clampi(level, ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality
	apply_shadow_quality()
	save_prefs()


## Push the current tier at the renderer, then at every Light3D already in the
## tree. Lights added later are caught by _on_node_added.
func apply_shadow_quality() -> void:
	var tier: Dictionary = SHADOW_TIERS.get(shadow_quality, SHADOW_TIERS[ShadowQuality.MEDIUM])
	var atlas: int = tier["atlas"]
	var bits16: bool = tier["bits16"]

	var root := get_tree().root
	root.positional_shadow_atlas_size = atlas
	root.positional_shadow_atlas_16_bits = bits16
	RenderingServer.directional_shadow_atlas_set_size(atlas * 2, bits16)
	RenderingServer.directional_soft_shadow_filter_set_quality(tier["filter"])
	RenderingServer.positional_soft_shadow_filter_set_quality(tier["filter"])

	for node in root.find_children("*", "Light3D", true, false):
		configure_light(node as Light3D)


## Apply the current shadow tier to one light, so a spawned TV or handheld
## matches the room it was spawned into.
func configure_light(light: Light3D) -> void:
	if light == null:
		return
	light.shadow_enabled = shadows_enabled()
	if light is DirectionalLight3D and light.shadow_enabled:
		# One orthogonal split covers the whole room from a single map; four
		# splits spend most of their resolution near the camera, which is what
		# the higher tiers are paying for.
		var dir_light := light as DirectionalLight3D
		dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL \
			if shadow_quality == ShadowQuality.LOW \
			else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS


func _on_node_added(node: Node) -> void:
	if node is Light3D:
		configure_light(node as Light3D)


# ── Persistence ───────────────────────────────────────────────────────────────

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	msaa_3d = clampi(_prefs_int(data, "msaa_3d", msaa_3d),
		Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
	shadow_quality = clampi(_prefs_int(data, "shadow_quality", shadow_quality),
		ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality


func save_prefs() -> void:
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("QualityManager: cannot write %s" % PREFS_PATH)
		return
	file.store_string(JSON.stringify({
		"msaa_3d": msaa_3d,
		"shadow_quality": int(shadow_quality),
	}))
	file.close()


## JSON numbers arrive as floats and a null would make int() fail outright.
func _prefs_int(data: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return int(value)
	return fallback
