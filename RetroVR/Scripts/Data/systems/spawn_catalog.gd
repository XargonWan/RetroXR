## SpawnCatalog — the per-system list of things the spawn menu can spawn.
##
## The Systems tab shows a title card per system; opening a card lists that
## system's spawnable ITEMS — its hardware model(s) plus the controllers /
## peripherals that go with it (e.g. PlayStation → PSone + PlayStation +
## Controller + Dual Shock + Memory Card).
##
## Each item is a Dictionary:
##   kind    : "system"     → a RetroSystem console (system.tscn)
##             "peripheral" → an existing pickable scene spawned by name
##   label   : row text — the HARDWARE's name, not a category ("DS Lite",
##             "PSP-1000"), so the row says what it actually spawns
##   variant : (kind=="system")     the RetroSystem.model_variant to spawn with
##                                   ("" = the system's default model)
##   spawn   : (kind=="peripheral")  an EXISTING spawn string that
##                                   SpawnMenuController._on_spawn_requested already
##                                   handles ("retro_controller", "memory_card", …)
##
## _CATALOG lists only the REAL hardware rows and bespoke peripherals. The
## stand-in rows ("Primitive System" / "Primitive Handheld" / "Primitive
## Controller") are appended by items_for(), so they cannot drift out of step
## with which systems actually have a stand-in to spawn.
class_name SpawnCatalog
extends RefCounted

## Hardware played in the hand. Labelling only: its stand-in row reads "Primitive
## Handheld" rather than "Primitive System", and it gets no controller row — a
## handheld's controls are its own buttons (get_controller_port_count() == 0).
## Kept here rather than derived because is_handheld() is an instance method and
## the menu has to label a row without spawning anything to ask.
const _HANDHELDS: PackedStringArray = [
	"game_boy", "game_boy_advance", "atari_lynx", "wonderswan",
	"neo_geo_pocket", "pokemon_mini", "supervision",
	"playstation_portable", "nds", "3ds",
]

## The stand-in pad — also the "Primitive Controller" row's spawn token.
const PRIMITIVE_CONTROLLER := "retro_controller"


## systemid → Array of REAL hardware/peripheral items. Author only systems with
## more than one model or with bespoke peripherals; everything else gets a single
## row named after the system, built in items_for().
const _CATALOG: Dictionary = {
	"playstation": [
		{"kind": "system",     "label": "PSone",       "variant": ""},
		{"kind": "system",     "label": "PlayStation", "variant": "original"},
		{"kind": "peripheral", "label": "Controller",  "spawn": "psx_controller"},
		{"kind": "peripheral", "label": "Dual Shock",  "spawn": "dualshock"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"playstation2": [
		{"kind": "system",     "label": "PlayStation 2 Slim",          "variant": ""},
		{"kind": "system",     "label": "PlayStation 2 Slim (Silver)", "variant": "silver"},
		{"kind": "peripheral", "label": "Dual Shock 2",                "spawn": "dualshock2"},
		{"kind": "peripheral", "label": "Memory Card",                 "spawn": "memory_card"},
	],
	"gamecube": [
		{"kind": "system",     "label": "GameCube",    "variant": ""},
		{"kind": "peripheral", "label": "Controller",  "spawn": "gamecube_controller"},
		{"kind": "peripheral", "label": "Memory Card", "spawn": "gamecube_memory_card"},
	],
	"dreamcast": [
		{"kind": "system",     "label": "Dreamcast",  "variant": ""},
		{"kind": "peripheral", "label": "Controller", "spawn": "dreamcast_controller"},
	],
	"mega_drive": [
		{"kind": "system",     "label": "Genesis",        "variant": ""},
		{"kind": "system",     "label": "Mega Drive",     "variant": "megadrive"},
		{"kind": "peripheral", "label": "Genesis Pad",    "spawn": "genesis_controller"},
		{"kind": "peripheral", "label": "Mega Drive Pad", "spawn": "megadrive_controller"},
	],
	"sega_saturn": [
		{"kind": "system",     "label": "Saturn",     "variant": ""},
		{"kind": "peripheral", "label": "Controller", "spawn": "saturn_controller"},
	],
	"nes": [
		{"kind": "system",     "label": "NES",        "variant": ""},
		{"kind": "system",     "label": "Famicom",    "variant": "famicom"},
		{"kind": "peripheral", "label": "Controller", "spawn": "nes_controller"},
	],
	"nintendo_64": [
		{"kind": "system",     "label": "Nintendo 64", "variant": ""},
		{"kind": "peripheral", "label": "Controller",  "spawn": "n64_controller"},
	],
	"nds": [
		{"kind": "system", "label": "DS Phat", "variant": ""},
		{"kind": "system", "label": "DS Lite", "variant": "lite"},
	],
	"3ds": [
		{"kind": "system", "label": "New 3DS XL", "variant": ""},
	],
	"playstation_portable": [
		{"kind": "system", "label": "PSP-1000", "variant": ""},
	],
	"game_boy": [
		{"kind": "system", "label": "Game Boy", "variant": ""},
	],
	"game_boy_advance": [
		{"kind": "system", "label": "Game Boy Advance",    "variant": ""},
		{"kind": "system", "label": "Game Boy Advance SP", "variant": "sp"},
	],
	"virtual_boy": [
		{"kind": "system",     "label": "Virtual Boy", "variant": ""},
		{"kind": "peripheral", "label": "Controller",  "spawn": "vb_controller"},
	],
	"atari_2600": [
		{"kind": "system",     "label": "Atari 2600", "variant": ""},
		{"kind": "peripheral", "label": "Joystick",   "spawn": "atari_joystick"},
	],
	# No bespoke SNES shell yet, so it has no real hardware row — items_for()
	# supplies the stand-in one, which is what variant "" would have spawned.
	"super_nes": [
		{"kind": "peripheral", "label": "Controller", "spawn": "snes_controller"},
	],
}


## The spawnable items for a system: its real hardware row(s), then the stand-in
## rows. `system_name` labels the hardware row for the ~60 systems with no
## _CATALOG entry — the menu already knows it, so a row reads "Game Gear" rather
## than a bare "Console".
static func items_for(systemid: String, system_name: String = "") -> Array:
	var items: Array = []
	if _CATALOG.has(systemid):
		items = (_CATALOG[systemid] as Array).duplicate(true)
	elif RetroSystem.has_bespoke_model(systemid):
		items.append({"kind": "system", "variant": "",
			"label": system_name if not system_name.is_empty() else "Console"})
	# Systems with no bespoke model get no real hardware row: variant "" already
	# spawns the procedural placeholder, so the stand-in row below IS their
	# hardware row and listing both would offer the same thing twice.

	var handheld: bool = _HANDHELDS.has(systemid)
	# A stand-in row only appears when there is something sensible behind it — an
	# authored stand-in scene, or (for anything not played in the hand) the
	# procedural placeholder. A handheld without its own stand-in would otherwise
	# offer a console box shaped nothing like the device.
	if RetroSystem.has_primitive_model(systemid) or not handheld:
		items.append({"kind": "system",
			"label": "Primitive Handheld" if handheld else "Primitive System",
			"variant": RetroSystemModel.PRIMITIVE_VARIANT})
	if not handheld:
		items.append({"kind": "peripheral", "label": "Primitive Controller",
			"spawn": PRIMITIVE_CONTROLLER})
	return items


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
