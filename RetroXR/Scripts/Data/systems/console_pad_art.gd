## ConsolePadArt — line art and anchors for the consoles whose own pad the
## Controls tab can draw, keyed by systemid.
##
## A platform with a row here gets its real controller on its override page,
## with a dropdown on each control the hardware actually has. A platform without
## one falls back to the generic diagrams — the Quest controllers for the XR
## section, the Xbox-layout pad for the physical one — which is what every
## platform used before this table existed.
##
## Control keys are GamepadBindings target strings, so one row serves BOTH
## sections: the physical-pad map is keyed by target already, and the XR map's
## RetroPad bit is that target's index in GamepadBindings.TARGET_ORDER.
##
## Art is drawn, not baked — see Tools/gen_nes_pad_art.py, which emits the SVG
## and prints the anchors and row orders below. Each is deliberately a *layout*
## rather than a specific product: no logo, no inset panel, no trade dress,
## nothing traced from a photo.
class_name ConsolePadArt
extends RefCounted

const _ROWS: Dictionary = {
	"nes": {
		"label": "NES Controller",
		"art": "res://Textures/Controllers/nes_pad_line.svg",
		# Normalized to the SVG viewBox, so the diagram lays out at any size.
		"anchors": {
			"up": Vector2(0.1980, 0.3116),
			"down": Vector2(0.1980, 0.6744),
			"left": Vector2(0.1200, 0.4930),
			"right": Vector2(0.2760, 0.4930),
			"select": Vector2(0.4300, 0.6093),
			"start": Vector2(0.5560, 0.6093),
			"b": Vector2(0.7420, 0.5070),
			"a": Vector2(0.8680, 0.5070),
		},
		# Rows along the top and bottom rather than columns down the sides: this
		# pad is 2.3:1, and a column beside it would put every lead nearly
		# horizontal across the whole picture. Split by anchor height, ordered by
		# anchor x. `down` is on the bottom row despite sharing the d-pad's x
		# with `up`, because from the top its lead would run through the cross.
		"top": ["left", "up", "right"],
		"bottom": ["down", "select", "start", "b", "a"],
	},
}


## True when this platform has a pad of its own to draw.
static func has(systemid: String) -> bool:
	return not systemid.is_empty() and _ROWS.has(systemid)


## The row for a platform, or an empty Dictionary.
static func row(systemid: String) -> Dictionary:
	return _ROWS.get(systemid, {}) as Dictionary


## Every control this platform's pad carries, in row order.
static func controls(systemid: String) -> Array:
	var r := row(systemid)
	if r.is_empty():
		return []
	return (r["top"] as Array) + (r["bottom"] as Array)


## The RetroPad bit a control drives. Control keys are GamepadBindings targets,
## whose order IS the bit order — see the comment on TARGET_ORDER.
static func bit_of(control: String) -> int:
	return GamepadBindings.TARGET_ORDER.find(control)


## The art for a platform, or null.
static func texture(systemid: String) -> Texture2D:
	var r := row(systemid)
	if r.is_empty():
		return null
	return load(String(r["art"])) as Texture2D
