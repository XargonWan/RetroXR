## SpawnCatalog — the per-system list of things the spawn menu can spawn.
##
## The Systems tab shows a title card per system; opening a card lists that
## system's spawnable ITEMS — its hardware model(s) plus the peripherals that go
## with it (e.g. PlayStation → Primitive System + Memory Card + Primitive
## Controller).
##
## Hardware rows are NOT authored here. Every model is a row in
## SystemModelRegistry that already knows its own label and which platform it sits
## under, so this file asks for them and only hand-authors the peripherals. That is
## what makes adding or deleting a model a one-row edit: the menu follows.
##
## Each item is a Dictionary:
##   kind     : "system"     → a RetroSystem console (system.tscn)
##              "peripheral" → an existing pickable scene spawned by name
##   label    : row text — the HARDWARE's name, not a category ("DS Lite",
##              "PSP-1000"), so the row says what it actually spawns
##   model_id : (kind=="system")     the SystemModelRegistry row to spawn
##   spawn    : (kind=="peripheral") an EXISTING spawn string that
##                                   SpawnMenuController._on_spawn_requested already
##                                   handles ("retro_controller", "memory_card", …)
class_name SpawnCatalog
extends RefCounted

## The stand-in pad — also the "Primitive Controller" row's spawn token.
const PRIMITIVE_CONTROLLER := "retro_controller"


## systemid → the peripherals that belong to that hardware. Systems with no entry
## just have none; their hardware rows still come from the registry.
##
## What is listed is the hardware retroXR models itself: the memory card, and the
## Virtual Boy pad — that one is here rather than dropped to the generic row
## because it carries the console's POWER switch, so the platform is unplayable
## without it.
##
## Every non-handheld gets the "Primitive Controller" row appended by items_for
## below, so a platform losing its entry here loses a name, not a way to play.
const _PERIPHERALS: Dictionary = {
	"playstation": [
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"playstation2": [
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"gamecube": [
		{"kind": "peripheral", "label": "Memory Card", "spawn": "memory_card"},
	],
	"virtual_boy": [
		{"kind": "peripheral", "label": "Controller", "spawn": "vb_controller"},
	],
	# The NES pad is named here rather than left to the generic row because the
	# console moulds its own connector and the pad wears it (plug_mesh_path), so
	# the two only look right together. No cartridge row: a cart comes from the
	# Games tab, which already spawns one per ROM keyed on systemid.
	"nes": [
		{"kind": "peripheral", "label": "Controller", "spawn": "nes_controller"},
	],
}


## Platforms that model their own console AND their own pad, so the generic
## stand-ins are only clutter on their card. Everything else keeps them: for a
## platform with no hardware of its own they are the whole way to play it.
const _NO_STANDINS: Array[String] = ["nes"]


## The spawnable items for a system: its stand-in hardware, then the models that
## need imported assets, then its peripherals.
##
## The stand-ins lead the list — the platform's authored primitive models where it
## has any, then the Primitive System box, which is the only stand-in a platform
## without one has.
##
## `system_name` is unused now — a hardware row is labelled by its registry row
## rather than by the system's name, so a platform with two models says which is
## which. Kept in the signature because the menu passes it.
static func items_for(systemid: String, _system_name: String = "") -> Array:
	var primitive: Array = []
	var imported: Array = []
	for row: Dictionary in SystemModelRegistry.rows_for(systemid):
		var item := {"kind": "system", "model_id": row.get("id", ""),
			"label": row.get("label", "Console")}
		if (row.get("requires", []) as Array).is_empty():
			primitive.append(item)
		else:
			imported.append(item)

	# Anything not played in the hand can also take the primitive box and the
	# primitive pad. A handheld gets neither: a console box is shaped nothing like
	# the device, and its controls are its own buttons. Nor does a platform in
	# _NO_STANDINS, which brings both of its own.
	var handheld := SystemModelRegistry.platform_is_handheld(systemid)
	var standins := not handheld and not _NO_STANDINS.has(systemid)

	var items: Array = []
	items.append_array(primitive)
	if standins:
		items.append({"kind": "system", "label": "Primitive System",
			"model_id": SystemModelRegistry.PLACEHOLDER_ID})
	items.append_array(imported)
	items.append_array((_PERIPHERALS.get(systemid, []) as Array).duplicate(true))
	if standins:
		items.append({"kind": "peripheral", "label": "Primitive Controller",
			"spawn": PRIMITIVE_CONTROLLER})
	return items


## The single place that turns a catalog item into the string emitted on
## SpawnMenu2D.spawn_requested. Keeping this here means SpawnMenuController stays
## the one and only spawn authority.
##   system     → "model:<systemid>:<model_id>"
##   peripheral → the item's existing spawn string, verbatim
##
## The systemid rides along because the placeholder row belongs to no platform, so
## its id alone cannot say which core to load.
static func spawn_token(systemid: String, item: Dictionary) -> String:
	if item.get("kind", "system") == "peripheral":
		return item.get("spawn", "")
	return "model:%s:%s" % [systemid, item.get("model_id", "")]
