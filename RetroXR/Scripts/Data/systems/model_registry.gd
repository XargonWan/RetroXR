## SystemModelRegistry — every hardware model RetroXR can wear, in one flat table.
##
## A model is a first-class thing with an id, not a "variant" of another model. Two
## models for the same platform are two rows that know nothing about each other, so
## either can be added or deleted without touching the other. Deleting a model is
## deleting its row and its files.
##
## "Primitive" here is only a NAME for a kind of model. It is not a mode, a flag, or
## a branch: nothing anywhere asks "am I primitive?" to decide what to load.
##
## `requires` and the availability check below have no row to act on today — every
## model ships with the app. They stay because they are the contract a model with
## external assets plugs into, and because `resolve()` leans on them to keep a save
## naming a model this build does not have from ever landing on nothing.
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


## The procedural box, labelled "Primitive System" in the menu. It is the stand-in
## for hardware with no primitive model of its own. Unlike the authored primitives,
## which are ordinary rows under their platform, this box fits any console and so
## belongs to no platform — which is why it is not in _ROWS.
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
	"pc_tower":             {"platform": "scummvm", "label": "PC Tower",
		"scene": _SCENES + "pc_tower.tscn"},

	# --- handhelds ------------------------------------------------------------
	# The "(primitive)" suffix is now redundant — these are the only models their
	# platforms have — but the ids are what saves and peers name, so they stay.
	"game_boy_primitive":   {"platform": "game_boy", "label": "Game Boy", "handheld": true,
		"scene": _SCENES + "game_boy_primitive.tscn"},
	"game_boy_advance_primitive": {"platform": "game_boy_advance", "label": "Game Boy Advance", "handheld": true,
		"scene": _SCENES + "game_boy_advance_primitive.tscn"},
	"game_boy_advance_sp_primitive": {"platform": "game_boy_advance", "label": "Game Boy Advance SP", "handheld": true,
		"scene": _SCENES + "game_boy_advance_sp_primitive.tscn"},
	"nds_primitive":        {"platform": "nds", "label": "DS", "handheld": true,
		"scene": _SCENES + "nds_primitive.tscn"},
	"n3ds_primitive":       {"platform": "3ds", "label": "3DS", "handheld": true,
		"scene": _SCENES + "n3ds_primitive.tscn"},
	"psp_primitive":        {"platform": "playstation_portable", "label": "PSP", "handheld": true,
		"scene": _SCENES + "psp_primitive.tscn"},
	"virtual_boy_primitive": {"platform": "virtual_boy", "label": "Virtual Boy",
		"scene": _SCENES + "virtual_boy_primitive.tscn"},
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
	# An explicit placeholder request is an ANSWER, not a miss. Falling through to
	# the platform's first row here meant asking for the procedural box handed back
	# a platform model instead — which is what the test hallway and the menu's
	# "Primitive System" row were both doing.
	if model_id == PLACEHOLDER_ID:
		return placeholder_row()
	if not model_id.is_empty():
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


## Every model scene we have loaded, kept referenced.
##
## Godot's resource cache holds a WEAK reference, so freeing the last instance of
## a model drops its PackedScene and the next spawn re-reads and re-parses the
## whole thing. Measured on desktop 2026-08-01: loading the baked NES cost 442 ms
## cold and 395 ms again after its instance was freed, against 0.0 ms with a
## reference held. Quest storage is far slower than that, and this is paid on
## EVERY spawn.
##
## The cost of holding them is the scenes themselves — meshes and textures for
## models the player has already spawned once. If that becomes a problem on
## device, bound this rather than removing it.
static var _packed_scenes: Dictionary = {}


static func packed_scene(scene_path: String) -> PackedScene:
	var cached: PackedScene = _packed_scenes.get(scene_path)
	if cached != null:
		return cached
	var packed := load(scene_path) as PackedScene
	if packed != null:
		_packed_scenes[scene_path] = packed
	return packed


static func instantiate(row: Dictionary) -> RetroSystemModel:
	var scene_path: String = row.get("scene", "")
	if not scene_path.is_empty():
		var packed := packed_scene(scene_path)
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
## there is something to fall back to if the asset-backed one is unavailable.
##
## A platform whose only model happens to be plain (atari_lynx, wonderswan, …)
## returns false: nothing is being offered as an alternative to anything.
##
## No row carries external assets today, so this is false everywhere. Kept for the
## same reason `requires` is — it is how such a model would announce that the plain
## one is still there behind it.
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


## A row by id, with "id" filled in. Empty for an unknown id.
static func row_for(model_id: String) -> Dictionary:
	return _row(model_id) if _ROWS.has(model_id) else {}


## The models that carry no external assets — the stand-ins. Every row, now.
##
## Worth naming because they were the cheap half by a wide margin, which is why
## they are the half ModelWarmer warms. Measured on a Quest 3: warming all thirteen
## costs ~1.1 s and almost no texture memory. Warming is the whole registry, and
## it is cheap because untextured primitives are cheap.
static func stand_in_ids() -> Array:
	var out: Array = []
	for id: String in _ROWS:
		if (_ROWS[id].get("requires", []) as Array).is_empty():
			out.append(id)
	return out


static func all_ids() -> Array:
	return _ROWS.keys()


static func _row(model_id: String) -> Dictionary:
	var r: Dictionary = (_ROWS[model_id] as Dictionary).duplicate()
	r["id"] = model_id
	return r
