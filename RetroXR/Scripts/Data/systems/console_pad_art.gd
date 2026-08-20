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
## Art must be redistributable and free of anyone's branding — see the
## ATTRIBUTIONS file beside the SVGs. Anchors are measured from a render rather
## than chosen (Tools/nes_pad_anchors.py), because the drawing is not ours.
class_name ConsolePadArt
extends RefCounted

const _ROWS: Dictionary = {
	"nes": {
		"label": "NES Controller",
		"art": "res://Textures/Controllers/nes_pad_colour.svg",
		# Colour art, so the diagram must NOT tint it — ART_TINT exists to recolour
		# the white-on-alpha line drawings, and over this it would wash the red
		# buttons and the grey shell into one blue.
		"tint": false,
		# Normalized to the SVG viewBox, so the diagram lays out at any size.
		# MEASURED from a Godot render by Tools/nes_pad_anchors.py, not chosen:
		# the buttons are somebody else's drawing, so the dots have to be found
		# in it. Re-run that tool if the art is ever replaced.
		"anchors": {
			"left": Vector2(0.0813, 0.5056),
			"up": Vector2(0.1606, 0.3302),
			"right": Vector2(0.2399, 0.5056),
			"down": Vector2(0.1606, 0.6811),
			"select": Vector2(0.3699, 0.6398),
			"start": Vector2(0.4914, 0.6397),
			"b": Vector2(0.6436, 0.6186),
			"a": Vector2(0.7623, 0.6187),
		},
		# Rows along the top and bottom rather than columns down the sides: this
		# pad is 2.2:1, and a column beside it would put every lead nearly
		# horizontal across the whole picture. Split by anchor height, ordered by
		# anchor x. `down` is on the bottom row despite sharing the cross's x
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


## True when the diagram should recolour this art to follow the panel theme.
## Line art is white-on-alpha and wants it; a colour illustration does not.
static func tints(systemid: String) -> bool:
	var r := row(systemid)
	return bool(r.get("tint", true)) if not r.is_empty() else true


## The art for a platform, or null.
static func texture(systemid: String) -> Texture2D:
	var r := row(systemid)
	if r.is_empty():
		return null
	return load(String(r["art"])) as Texture2D
