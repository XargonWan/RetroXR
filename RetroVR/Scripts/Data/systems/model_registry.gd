## SystemModelRegistry — every hardware model RetroVR can wear, in one flat table.
##
## A model is a first-class thing with an id, not a "variant" of another model. Two
## models for the same platform — a primitive one and an imported one — are two rows
## that know nothing about each other, so either can be added or deleted without
## touching the other. Deleting a model is deleting its row and its files.
##
## "Primitive" here is only a NAME for a kind of model. It is not a mode, a flag, or
## a branch: nothing anywhere asks "am I primitive?" to decide what to load.
##
## This replaced four dictionaries in system.gd with precedence rules between them
## (`_MODEL_SCENES`, `_MODEL_SCENE_VARIANTS`, `_MODEL_VARIANTS`, `_MODEL_SCRIPTS`),
## keyed by concatenated "systemid:variant" strings, plus two special-case branches
## on a magic "primitive" variant. Notes from unpicking that:
##
##   * `_MODEL_VARIANTS` was entirely dead — all three of its keys were shadowed by
##     `_MODEL_SCENE_VARIANTS`, which was tested first.
##   * `_MODEL_SCRIPTS` contributed exactly one reachable row ("dos"); its "nes" and
##     "nintendo_64" entries were shadowed by `_MODEL_SCENES`.
##
## Lives in Data/systems beside system_icons.gd and system_asset_catalog.gd, which
## are the same species: a static table, an availability check, a graceful fallback.
## Keeping it out of Objects/ also stops SpawnCatalog (Data) reaching up into
## RetroSystem (Objects) to ask which models exist.
class_name SystemModelRegistry
extends RefCounted


## The procedural grey box every platform falls back to. Not in _ROWS — it belongs
## to no platform, and appending it per-platform means it cannot drift out of step.
const PLACEHOLDER_ID := "placeholder"
const PLACEHOLDER_SCRIPT := "res://Scripts/Objects/system_models/default_model.gd"

const _SCENES := "res://Scenes/Objects/system_models/"


## Row fields:
##   platform  systemid this model is hardware for. Does NOT replace
##             RetroSystem.systemid — core lookup, MediaDimensions, SystemInfo,
##             SystemIcons and ROM filtering all key off that. The row sits UNDER
##             the platform.
##   label     spawn-menu row text.
##   scene     XOR script. Neither would mean the placeholder.
##   handheld  played in the hand; the menu labels those differently.
##   requires  assets that must be present for this row to be usable. Empty means
##             always available. Declared now, enforced in a later phase.
##
## Order matters: the FIRST row for a platform is that platform's default, which is
## what an empty model_id resolves to.
const _ROWS: Dictionary = {
	# --- consoles -------------------------------------------------------------
	"nes":                  {"platform": "nes", "label": "NES",
		"scene": _SCENES + "nes.tscn",
		"requires": ["res://imported-assets/nes_system.glb"]},
	"famicom":              {"platform": "nes", "label": "Famicom",
		"scene": _SCENES + "famicom.tscn",
		"requires": ["res://imported-assets/famicom.glb"]},
	"atari_2600":           {"platform": "atari_2600", "label": "Atari 2600",
		"scene": _SCENES + "atari_2600.tscn",
		"requires": ["res://imported-assets/atari_2600.glb"]},
	"atari_5200":           {"platform": "atari_5200", "label": "Atari 5200",
		"scene": _SCENES + "atari_5200.tscn",
		"requires": ["res://imported-assets/atari_5200.glb"]},
	"genesis":              {"platform": "mega_drive", "label": "Genesis",
		"scene": _SCENES + "genesis.tscn",
		"requires": ["res://imported-assets/sega_genesis.glb"]},
	"megadrive":            {"platform": "mega_drive", "label": "Mega Drive",
		"scene": _SCENES + "megadrive.tscn",
		"requires": ["res://imported-assets/sega_megadrive.glb"]},
	"sega_saturn":          {"platform": "sega_saturn", "label": "Saturn",
		"scene": _SCENES + "sega_saturn.tscn",
		"requires": ["res://imported-assets/sega_saturn.glb"]},
	"dreamcast":            {"platform": "dreamcast", "label": "Dreamcast",
		"scene": _SCENES + "dreamcast.tscn",
		"requires": ["res://imported-assets/dreamcast_console.glb"]},
	"playstation_one":      {"platform": "playstation", "label": "PSone",
		"scene": _SCENES + "playstation_one.tscn",
		"requires": ["res://imported-assets/playstation_one.glb"]},
	"playstation_original": {"platform": "playstation", "label": "PlayStation",
		"scene": _SCENES + "playstation_original.tscn",
		"requires": ["res://imported-assets/playstation_original.glb"]},
	"ps2":                  {"platform": "playstation2", "label": "PlayStation 2 Slim",
		"scene": _SCENES + "ps2.tscn",
		"requires": ["res://imported-assets/ps2_slim.glb"]},
	"ps2_silver":           {"platform": "playstation2", "label": "PlayStation 2 Slim (Silver)",
		"scene": _SCENES + "ps2_silver.tscn",
		"requires": ["res://imported-assets/ps2_slim_silver.glb"]},
	"n64":                  {"platform": "nintendo_64", "label": "Nintendo 64",
		"scene": _SCENES + "n64.tscn",
		"requires": ["res://imported-assets/N64 imported.glb"]},
	# Mesh baked into the scene; only its maps are external.
	"gamecube":             {"platform": "gamecube", "label": "GameCube",
		"scene": _SCENES + "gamecube.tscn",
		"requires": ["res://imported-assets/gamecube_gamecube_console_color.png"]},
	"pc_tower":             {"platform": "scummvm", "label": "PC Tower",
		"scene": _SCENES + "pc_tower.tscn"},
	# The one script-only row. Its geometry is built procedurally around a GLB.
	"desktop_tower":        {"platform": "dos", "label": "PC Tower",
		"script": "res://Scripts/Objects/system_models/desktop_tower_model.gd",
		"requires": ["res://imported-assets/desktop_tower.glb"]},

	# --- handhelds ------------------------------------------------------------
	"game_boy":             {"platform": "game_boy", "label": "Game Boy", "handheld": true,
		"scene": _SCENES + "game_boy.tscn",
		"requires": ["res://imported-assets/game_boy_dmg.glb"]},
	"game_boy_primitive":   {"platform": "game_boy", "label": "Game Boy (primitive)", "handheld": true,
		"scene": _SCENES + "game_boy_primitive.tscn"},
	"game_boy_advance":     {"platform": "game_boy_advance", "label": "Game Boy Advance", "handheld": true,
		"scene": _SCENES + "game_boy_advance.tscn",
		"requires": ["res://imported-assets/game_boy_advance.glb"]},
	"game_boy_advance_sp":  {"platform": "game_boy_advance", "label": "Game Boy Advance SP", "handheld": true,
		"scene": _SCENES + "game_boy_advance_sp.tscn",
		"requires": ["res://imported-assets/game_boy_advance_sp_GameboyAdvanceSP_OFF_BaseColor.png"]},
	"game_boy_advance_primitive": {"platform": "game_boy_advance", "label": "Game Boy Advance (primitive)", "handheld": true,
		"scene": _SCENES + "game_boy_advance_primitive.tscn"},
	"nds":                  {"platform": "nds", "label": "DS Phat", "handheld": true,
		"scene": _SCENES + "nds.tscn",
		"requires": ["res://imported-assets/ds_phat_nds_diffuse.png"]},
	"nds_lite":             {"platform": "nds", "label": "DS Lite", "handheld": true,
		"scene": _SCENES + "nds_lite.tscn",
		"requires": ["res://imported-assets/ds_lite.glb"]},
	"nds_primitive":        {"platform": "nds", "label": "DS (primitive)", "handheld": true,
		"scene": _SCENES + "nds_primitive.tscn"},
	"n3ds":                 {"platform": "3ds", "label": "New 3DS XL", "handheld": true,
		"scene": _SCENES + "n3ds.tscn",
		"requires": ["res://imported-assets/new_3ds_xl_n_new_3ds_xl.png"]},
	"n3ds_primitive":       {"platform": "3ds", "label": "3DS (primitive)", "handheld": true,
		"scene": _SCENES + "n3ds_primitive.tscn"},
	"psp":                  {"platform": "playstation_portable", "label": "PSP-1000", "handheld": true,
		"scene": _SCENES + "psp.tscn",
		"requires": ["res://imported-assets/psp_1000_psp_1.png"]},
	"psp_primitive":        {"platform": "playstation_portable", "label": "PSP (primitive)", "handheld": true,
		"scene": _SCENES + "psp_primitive.tscn"},
	"virtual_boy":          {"platform": "virtual_boy", "label": "Virtual Boy",
		"scene": _SCENES + "virtual_boy.tscn",
		"requires": ["res://imported-assets/virtual_boy.glb"]},
	"virtual_boy_primitive": {"platform": "virtual_boy", "label": "Virtual Boy (primitive)",
		"scene": _SCENES + "virtual_boy_primitive.tscn"},
	# Primitive models that are the only model for their platform — nothing imported.
	"atari_lynx":           {"platform": "atari_lynx", "label": "Atari Lynx", "handheld": true,
		"scene": _SCENES + "atari_lynx.tscn"},
	"wonderswan":           {"platform": "wonderswan", "label": "WonderSwan", "handheld": true,
		"scene": _SCENES + "wonderswan.tscn"},
	"neo_geo_pocket":       {"platform": "neo_geo_pocket", "label": "Neo Geo Pocket", "handheld": true,
		"scene": _SCENES + "neo_geo_pocket.tscn"},
	"pokemon_mini":         {"platform": "pokemon_mini", "label": "Pokemon Mini", "handheld": true,
		"scene": _SCENES + "pokemon_mini.tscn"},
	"supervision":          {"platform": "supervision", "label": "Supervision", "handheld": true,
		"scene": _SCENES + "supervision.tscn"},
}



## Set by tests to prove a stripped build still resolves every platform to
## something spawnable. Never set at runtime.
static var simulate_missing_assets: bool = false


## The row for `model_id`, or the best available stand-in. Never returns empty.
##
## Four rules, none of them special cases:
##   1. known and available            -> that row
##   2. known but unavailable          -> platform's best available row
##   3. unknown (a deleted model named by an old save or a peer)  -> same
##   4. empty                          -> platform's first available row
## Rules 2 and 3 are what make deleting a model safe across old saves and peers on
## a different build.
static func resolve(model_id: String, platform: String) -> Dictionary:
	if not model_id.is_empty() and model_id != PLACEHOLDER_ID:
		if _ROWS.has(model_id):
			if is_available(model_id):
				return _row(model_id)
			push_warning("[models] '%s' is not available in this build; falling back" % model_id)
		else:
			push_warning("[models] unknown model '%s' (deleted?); falling back" % model_id)
	var avail := rows_for(platform)
	if not avail.is_empty():
		return avail[0]
	return placeholder_row()


static func instantiate(row: Dictionary) -> RetroSystemModel:
	var scene_path: String = row.get("scene", "")
	if not scene_path.is_empty():
		var packed := load(scene_path) as PackedScene
		if packed == null:
			push_warning("[models] failed to load scene: " + scene_path)
			return null
		return packed.instantiate() as RetroSystemModel
	var script_path: String = row.get("script", PLACEHOLDER_SCRIPT)
	var script := load(script_path) as GDScript
	if script == null:
		push_warning("[models] failed to load script: " + script_path)
		return null
	return script.new() as RetroSystemModel


## False only for the procedural placeholder. The cabinet keeps its own body box and
## builds a procedural disc tray/slit only when no real model brought its own.
static func is_bespoke(row: Dictionary) -> bool:
	return row.get("id", PLACEHOLDER_ID) != PLACEHOLDER_ID


static func placeholder_row() -> Dictionary:
	return {"id": PLACEHOLDER_ID, "platform": "", "label": "Primitive System",
		"script": PLACEHOLDER_SCRIPT, "requires": []}


## Every available row for a platform, in author order. The first is its default.
static func rows_for(platform: String) -> Array:
	var out: Array = []
	for id: String in _ROWS:
		if _ROWS[id].get("platform", "") == platform and is_available(id):
			out.append(_row(id))
	return out


static func is_available(model_id: String) -> bool:
	if not _ROWS.has(model_id):
		return false
	var req: Array = _ROWS[model_id].get("requires", [])
	if req.is_empty():
		return true
	if simulate_missing_assets:
		return false
	for path: String in req:
		if not ResourceLoader.exists(path):
			return false
	return true


static func platform_of(model_id: String) -> String:
	return _ROWS[model_id].get("platform", "") if _ROWS.has(model_id) else ""


static func platform_is_handheld(platform: String) -> bool:
	for id: String in _ROWS:
		var r: Dictionary = _ROWS[id]
		if r.get("platform", "") == platform and bool(r.get("handheld", false)):
			return true
	return false


static func has_any_model(platform: String) -> bool:
	for id: String in _ROWS:
		if _ROWS[id].get("platform", "") == platform:
			return true
	return false


## True when this platform offers a plain model ALONGSIDE an asset-backed one, i.e.
## there is something to fall back to if the imported model is dropped.
##
## A platform whose only model happens to be plain (atari_lynx, wonderswan, …)
## returns false: nothing is being offered as an alternative to anything.
static func has_plain_alternative(platform: String) -> bool:
	var total := 0
	var plain := 0
	for id: String in _ROWS:
		if _ROWS[id].get("platform", "") != platform:
			continue
		total += 1
		if (_ROWS[id].get("requires", []) as Array).is_empty():
			plain += 1
	return total > 1 and plain > 0


## The row for this platform that needs no imported assets, or the placeholder.
## Survives deletion of the imported rows by construction.
static func store_safe_id(platform: String) -> String:
	for id: String in _ROWS:
		var r: Dictionary = _ROWS[id]
		if r.get("platform", "") == platform and (r.get("requires", []) as Array).is_empty():
			return id
	return PLACEHOLDER_ID


static func all_ids() -> Array:
	return _ROWS.keys()

static func _default_id_for(platform: String) -> String:
	for id: String in _ROWS:
		if _ROWS[id].get("platform", "") == platform:
			return id
	return ""


static func _row(model_id: String) -> Dictionary:
	var r: Dictionary = (_ROWS[model_id] as Dictionary).duplicate()
	r["id"] = model_id
	return r
