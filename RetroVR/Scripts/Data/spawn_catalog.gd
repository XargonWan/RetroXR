## SpawnCatalog — the per-system list of things the spawn menu can spawn.
##
## The Systems tab shows a title card per system; opening a card lists that
## system's spawnable ITEMS — its console model(s) plus the controllers /
## peripherals that go with it (e.g. PlayStation → Console + Controller +
## Memory Card, and later a distinct PS1 model, a DualShock, …).
##
## Each item is a Dictionary:
##   kind    : "system"     → a RetroSystem console (system.tscn)
##             "peripheral" → an existing pickable scene spawned by name
##   label   : row text shown in the detail page ("Console", "Controller", …)
##   variant : (kind=="system")     the RetroSystem.model_variant to spawn with
##                                   ("" = the system's default model)
##   spawn   : (kind=="peripheral")  an EXISTING spawn string that
##                                   SpawnMenuController._on_spawn_requested already
##                                   handles ("retro_controller", "memory_card", …)
##
## Only systems that have variants / peripherals need a _CATALOG entry; every
## other system falls back to a single "Console" item, so no per-system authoring
## is required for the ~60 systems that just spawn their one model.
class_name SpawnCatalog
extends RefCounted


## systemid → Array of item Dictionaries. Author only systems with extra items.
const _CATALOG: Dictionary = {
	"playstation": [
		{"kind": "system",     "label": "Console",     "variant": ""},
		{"kind": "system",     "label": "Console (Original)", "variant": "original"},
		{"kind": "peripheral", "label": "Controller",  "spawn": "psx_controller"},
		{"kind": "peripheral", "label": "Dual Shock",  "spawn": "dualshock"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"playstation2": [
		{"kind": "system",     "label": "Console",         "variant": ""},
		{"kind": "system",     "label": "Console (Silver)", "variant": "silver"},
		{"kind": "peripheral", "label": "Dual Shock 2",    "spawn": "dualshock2"},
		{"kind": "peripheral", "label": "Memory Card",     "spawn": "memory_card"},
	],
	"gamecube": [
		{"kind": "system",     "label": "Console",     "variant": ""},
		{"kind": "peripheral", "label": "Controller",  "spawn": "gamecube_controller"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"dreamcast": [
		{"kind": "system",     "label": "Console",    "variant": ""},
		{"kind": "peripheral", "label": "Controller", "spawn": "dreamcast_controller"},
	],
	"mega_drive": [
		{"kind": "system", "label": "Genesis (US)",   "variant": ""},
		{"kind": "system", "label": "Mega Drive",     "variant": "megadrive"},
	],
	"nes": [
		{"kind": "system",     "label": "Console",    "variant": ""},
		{"kind": "system",     "label": "Famicom",    "variant": "famicom"},
		{"kind": "peripheral", "label": "Controller", "spawn": "nes_controller"},
	],
	"nintendo_64": [
		{"kind": "system",     "label": "Console",    "variant": ""},
		{"kind": "peripheral", "label": "Controller", "spawn": "n64_controller"},
	],
	"nds": [
		{"kind": "system", "label": "Nintendo DS", "variant": ""},
		{"kind": "system", "label": "DS Lite",     "variant": "lite"},
	],
	"super_nes": [
		{"kind": "system",     "label": "Console",    "variant": ""},
		{"kind": "peripheral", "label": "Controller", "spawn": "snes_controller"},
	],
}


## The spawnable items for a system. Falls back to a single default "Console"
## item when the system has no explicit catalog entry.
static func items_for(systemid: String) -> Array:
	if _CATALOG.has(systemid):
		return _CATALOG[systemid]
	return [{"kind": "system", "label": "Console", "variant": ""}]


## The single place that turns a catalog item into the string emitted on
## SpawnMenu2D.spawn_requested. Keeping this here means SpawnMenuController stays
## the one and only spawn authority.
##   system,  variant "" → bare systemid          (hits the systemid default branch)
##   system,  variant X  → "system:<systemid>:<X>"
##   peripheral          → the item's existing spawn string, verbatim
static func spawn_token(systemid: String, item: Dictionary) -> String:
	var kind: String = item.get("kind", "system")
	if kind == "peripheral":
		return item.get("spawn", "")
	var variant: String = item.get("variant", "")
	if variant.is_empty():
		return systemid
	return "system:%s:%s" % [systemid, variant]
