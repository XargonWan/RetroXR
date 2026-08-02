## QualityManager — Autoload singleton that adapts visual quality per platform
## and owns the user-facing graphics settings from the menu's GRAPHICS tab
## (render scale, MSAA, shadows, ambient occlusion), persisted to
## user://graphics_prefs.json.
##
## Each room authors its own Environment for its own look — the arcade's neon
## haze is not the den's warm lamplight — so the settings here are layered onto
## whatever Environment the current scene brought, never swapped for one.
extends Node

const PREFS_PATH := "user://graphics_prefs.json"


## Shadow tiers offered in the GRAPHICS tab. OFF is the original look: no light
## in the room casts a shadow at all.
enum ShadowQuality { OFF, LOW, MEDIUM, HIGH }

## Screen-space ambient occlusion tiers. Forward+ only — see supports_post_effects().
enum AOQuality { OFF, LOW, HIGH }

## Post-process edge smoothing, which catches what MSAA cannot: MSAA only samples
## geometry edges, so the procedural carpet, wood and neon shaders alias straight
## through it. TAA would cover the same ground but is not offered — it is inert on
## the mobile backend (measured: 0.004 mean pixel change against 0.493 for SMAA)
## and its history buffer smears under head motion.
enum PostAA { OFF, FXAA, SMAA }

## The one control most people will ever touch. CUSTOM is not selectable — it is
## what the preset becomes once an individual row is moved away from it.
enum Preset { LOW, MEDIUM, HIGH, CUSTOM }

## Render scale is deliberately absent: it is desktop-only and a taste call
## (supersampling), not a quality tier, so a preset never moves it.
const PRESETS := {
	Preset.LOW: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.OFF,
		"shadows": ShadowQuality.OFF, "ao": AOQuality.OFF,
	},
	Preset.MEDIUM: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.SMAA,
		"shadows": ShadowQuality.MEDIUM, "ao": AOQuality.LOW,
	},
	Preset.HIGH: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.SMAA,
		"shadows": ShadowQuality.HIGH, "ao": AOQuality.HIGH,
	},
}

## Positional shadow atlas edge, soft-shadow filter and depth precision per tier.
## The directional atlas gets twice the edge — it covers the whole room in one
## map where the positional atlas is subdivided between lights.
const SHADOW_TIERS := {
	ShadowQuality.OFF: {
		# Nothing casts at this tier, so an atlas would be VRAM reserved to go
		# unread — hand the smallest one back instead of leaving a tier's worth
		# allocated after switching down.
		"atlas": 256,
		"filter": RenderingServer.SHADOW_QUALITY_HARD,
		"bits16": true,
	},
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

## Half-resolution AO is the whole difference between the two tiers in cost.
const AO_TIERS := {
	AOQuality.LOW:  {"quality": RenderingServer.ENV_SSAO_QUALITY_LOW,  "half_size": true},
	AOQuality.HIGH: {"quality": RenderingServer.ENV_SSAO_QUALITY_HIGH, "half_size": false},
}

## Below 1.0 the 3D pass renders small and is upscaled into the full-size (eye)
## buffer; above 1.0 it supersamples.
const RENDER_SCALE_MIN := 0.5
const RENDER_SCALE_MAX := 1.5

## Ambilight sampling interval (frames between color updates)
var ambilight_interval: int = 10

## Viewport.MSAA_* level applied to the root (XR) viewport.
var msaa_3d: int = Viewport.MSAA_2X
var post_aa: PostAA = PostAA.OFF
var preset: Preset = Preset.CUSTOM
var shadow_quality: ShadowQuality = ShadowQuality.OFF
var ao_quality: AOQuality = AOQuality.OFF
var render_scale: float = 1.0
## Desktop window state. Empty resolution means "leave the window where it is".
var window_mode: String = ""
var resolution: String = ""

var _desktop: bool


func _ready() -> void:
	_desktop = OS.get_name() != "Android"
	ambilight_interval = 10 if _desktop else 30
	# Quest starts where it always was; desktop takes the tier these settings exist
	# to provide. Applied before _load_prefs so a saved preset wins.
	apply_preset(Preset.LOW if not _desktop else Preset.MEDIUM, false)
	_load_prefs()
	_adjust_lights()
	apply_render_scale()
	apply_msaa()
	apply_post_aa()
	apply_forced_quality()
	apply_shadow_quality()
	apply_ao_quality()
	# Lights and each room's WorldEnvironment arrive with every scene load, and
	# lights also with every spawned TV or handheld, so both are configured as
	# they enter the tree rather than swept for.
	get_tree().node_added.connect(_on_node_added)
	_log_state()


## Report what the settings actually resolved to, so a wrong renderer string or a
## stale pref is visible in logcat instead of only in the headset — the same
## reason xr_init logs its eye buffer.
func _log_state() -> void:
	var root := get_tree().root
	print(("QualityManager: renderer '%s', scale %.2f (mode %d), msaa %d, post_aa %d, "
		+ "preset %d, shadows %d, ao %d, atlas %d") % [
		RenderingServer.get_current_rendering_method(), root.scaling_3d_scale,
		root.scaling_3d_mode, root.msaa_3d, root.screen_space_aa, preset,
		shadow_quality, ao_quality, root.positional_shadow_atlas_size])


## Screen-space effects (SSAO here, plus SSIL/SSR/volumetric fog if they are
## ever added) are Forward+ only. Android renders with the mobile backend, where
## setting them is silently a no-op — measured, not assumed.
func supports_post_effects() -> bool:
	return _is_forward_plus()


func _is_forward_plus() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"


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

## Scaling the 3D pass at all breaks the mobile backend's XR viewport, in both
## directions and for both upscalers. Measured on a Quest 3: 0.5x logs
## `!draw_list.active` ~177 times a frame (510,724 in 40 s, against 0 at 1.0x),
## and 1.5x renders the scene into a corner of the eye buffer with stale frame
## data filling the rest. Neither shows up on a desktop SubViewport under the
## same backend, so only the headset catches it. The knob is therefore not
## offered there — 1.0 is the only safe value, and the way to spend resolution
## on that headset is the eye-buffer multiplier in xr_init.gd instead.
func supports_render_scale() -> bool:
	return _is_forward_plus()


func set_render_scale(scale: float) -> void:
	render_scale = clampf(scale, RENDER_SCALE_MIN, RENDER_SCALE_MAX) \
		if supports_render_scale() else 1.0
	apply_render_scale()
	save_prefs()


func apply_render_scale() -> void:
	var root := get_tree().root
	root.scaling_3d_scale = render_scale
	# FSR1 is a spatial upscaler, so it has none of the temporal ghosting that
	# rules FSR2 out for a head-tracked view. At 1.0 and above it would only cost
	# a pass for nothing, so bilinear takes over there.
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if render_scale < 1.0 \
		else Viewport.SCALING_3D_MODE_BILINEAR


## Window mode and resolution were the only GRAPHICS rows that reset every launch,
## which read as a bug sitting next to rows that do persist. Headsets have no
## desktop window to restore, so this is desktop-only.
func set_window_state(mode: String, res: String) -> void:
	if not mode.is_empty():
		window_mode = mode
	if not res.is_empty():
		resolution = res
	save_prefs()


func set_msaa(mode: int) -> void:
	msaa_3d = clampi(mode, Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
	apply_msaa()
	_mark_custom()
	save_prefs()


func apply_msaa() -> void:
	get_tree().root.msaa_3d = msaa_3d as Viewport.MSAA


func set_post_aa(mode: int) -> void:
	post_aa = clampi(mode, PostAA.OFF, PostAA.SMAA) as PostAA
	apply_post_aa()
	_mark_custom()
	save_prefs()


func apply_post_aa() -> void:
	var root := get_tree().root
	match post_aa:
		PostAA.FXAA:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		PostAA.SMAA:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
		_:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED


## Settings with a strictly correct answer, so they are applied rather than asked
## about. Debanding is a dither pass costing almost nothing, and this room is
## mostly the dark gradients that band; anisotropic filtering sharpens floors at
## grazing angles, which is most of what a room-scale scene is looked at through.
func apply_forced_quality() -> void:
	var root := get_tree().root
	root.use_debanding = true
	root.anisotropic_filtering_level = Viewport.ANISOTROPY_8X


## Drive every tiered setting at once. `persist` is false only for the boot-time
## default, which must not write a prefs file before one has been read.
func apply_preset(level: Preset, persist: bool = true) -> void:
	preset = level
	var tier: Dictionary = PRESETS.get(level, {})
	if tier.is_empty():
		return
	msaa_3d = tier["msaa"]
	post_aa = tier["post_aa"]
	shadow_quality = tier["shadows"]
	# AO is Forward+ only; a preset must not switch on what the backend ignores.
	ao_quality = tier["ao"] if supports_post_effects() else AOQuality.OFF
	if is_inside_tree():
		apply_msaa()
		apply_post_aa()
		apply_shadow_quality()
		apply_ao_quality()
	if persist:
		save_prefs()


## Any individual row moving off the preset makes the preset Custom.
func _mark_custom() -> void:
	preset = Preset.CUSTOM


func shadows_enabled() -> bool:
	return shadow_quality != ShadowQuality.OFF


func set_shadow_quality(level: int) -> void:
	shadow_quality = clampi(level, ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality
	apply_shadow_quality()
	_mark_custom()
	save_prefs()


## Push the current tier at the renderer, then at every Light3D already in the
## tree. Lights added later are caught by _on_node_added.
func apply_shadow_quality() -> void:
	var tier: Dictionary = SHADOW_TIERS[shadow_quality]
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
##
## Lights in the "no_shadow" group opt out and never cast. That is for a light
## sealed inside a fixture: the shade is opaque to the shadow map but translucent
## in reality, so shadows absorb the whole output. The bedroom's ceiling-fan globe
## is the case that found this — sat inside its closed glass dome it lit nothing
## at all, and the room was running on its two table lamps alone. Shades that are
## open top and bottom, like those same lamps' drums, still want shadows: the
## blocked middle is exactly what makes their double cone.
func configure_light(light: Light3D) -> void:
	if light == null:
		return
	if light.is_in_group("no_shadow"):
		light.shadow_enabled = false
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


func set_ao_quality(level: int) -> void:
	ao_quality = clampi(level, AOQuality.OFF, AOQuality.HIGH) as AOQuality
	apply_ao_quality()
	_mark_custom()
	save_prefs()


## Layer the AO setting onto the current room's authored Environment. The room
## keeps its own sky, glow and ambient — only the SSAO block is ours.
func apply_ao_quality() -> void:
	if AO_TIERS.has(ao_quality):
		var tier: Dictionary = AO_TIERS[ao_quality]
		RenderingServer.environment_set_ssao_quality(tier["quality"], tier["half_size"],
			0.5, 2, 50.0, 300.0)
	for node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		configure_environment(node as WorldEnvironment)


func configure_environment(world_env: WorldEnvironment) -> void:
	if world_env == null or world_env.environment == null:
		return
	var env := world_env.environment
	env.ssao_enabled = ao_quality != AOQuality.OFF and supports_post_effects()
	if not env.ssao_enabled:
		return
	# Rooms this small want a short radius — a metre-wide sample skirt reads as
	# dirt smeared up the walls rather than contact shading under the furniture.
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.0


func _on_node_added(node: Node) -> void:
	if node is Light3D:
		configure_light(node as Light3D)
	elif node is WorldEnvironment:
		configure_environment(node as WorldEnvironment)


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
	post_aa = clampi(_prefs_int(data, "post_aa", post_aa), PostAA.OFF, PostAA.SMAA) as PostAA
	preset = clampi(_prefs_int(data, "preset", preset), Preset.LOW, Preset.CUSTOM) as Preset
	shadow_quality = clampi(_prefs_int(data, "shadow_quality", shadow_quality),
		ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality
	ao_quality = clampi(_prefs_int(data, "ao_quality", ao_quality),
		AOQuality.OFF, AOQuality.HIGH) as AOQuality
	# Forced to 1.0 where scaling is unsupported, so a value saved on desktop and
	# synced to a headset cannot bring the broken path back with it.
	window_mode = str(data.get("window_mode", window_mode))
	resolution = str(data.get("resolution", resolution))
	render_scale = clampf(_prefs_float(data, "render_scale", render_scale),
		RENDER_SCALE_MIN, RENDER_SCALE_MAX) if supports_render_scale() else 1.0


func save_prefs() -> void:
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("QualityManager: cannot write %s" % PREFS_PATH)
		return
	file.store_string(JSON.stringify({
		"msaa_3d": msaa_3d,
		"post_aa": int(post_aa),
		"preset": int(preset),
		"window_mode": window_mode,
		"resolution": resolution,
		"shadow_quality": int(shadow_quality),
		"ao_quality": int(ao_quality),
		"render_scale": render_scale,
	}))
	file.close()


## JSON numbers arrive as floats and a null would make int() fail outright.
func _prefs_int(data: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return int(value)
	return fallback


func _prefs_float(data: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return fallback
