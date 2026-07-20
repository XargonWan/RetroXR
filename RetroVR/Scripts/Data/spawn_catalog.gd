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
		{"kind": "peripheral", "label": "Dual Shock",  "spawn": "dualshock"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
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
