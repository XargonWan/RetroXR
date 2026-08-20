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

## The generic pad's key in _ROWS. Not a systemid — no console uses it — so
## has() keeps answering false for every real platform while row() and texture()
## still serve it.
const RETROPAD := "__retropad"

const _ROWS: Dictionary = {
	# The generic pad, for scopes that are not one console: the desktop key map on
	# the global Controls page binds RetroPad buttons, not a NES's. Keyed by a
	# systemid no console uses, so has() still answers false for every platform.
	#
	# Art and anchors are GamepadDiagram's, re-keyed from the Xbox PHYSICAL names
	# it uses to the RetroPad targets everything else here speaks. The face four
	# swap on the way: RetroPad B is the BOTTOM button and A is the right one,
	# which is the positional convention GamepadBindings.DEFAULT_BUTTON_MAP is
	# built on. Getting that backwards would put the picture and the core's idea
	# of "A" on opposite buttons.
	RETROPAD: {
		"label": "Controller",
		"art": "res://Textures/Controllers/gamepad_line.svg",
		"layout": "columns",
		"anchors": {
			"l2": Vector2(0.3000, 0.1139),
			"r2": Vector2(0.7000, 0.1139),
			"l": Vector2(0.3000, 0.1778),
			"r": Vector2(0.7000, 0.1778),
			"l3": Vector2(0.2680, 0.3639),
			"r3": Vector2(0.6050, 0.5667),
			"up": Vector2(0.3980, 0.5028),
			"down": Vector2(0.3980, 0.6306),
			"left": Vector2(0.3520, 0.5667),
			"right": Vector2(0.4440, 0.5667),
			"x": Vector2(0.7220, 0.2944),
			"a": Vector2(0.7780, 0.3722),
			"b": Vector2(0.7220, 0.4500),
			"y": Vector2(0.6660, 0.3722),
			"select": Vector2(0.4410, 0.3722),
			"start": Vector2(0.5590, 0.3722),
		},
		# GamepadDiagram's own column orders, which were chosen by counting
		# segment intersections over a sweep of panel sizes. Do not reorder
		# without re-running that count — see the note on its LEFT_ORDER.
		"left": ["l2", "l", "l3", "select", "up", "left", "right", "down"],
		"right": ["r2", "r", "x", "a", "y", "b", "start", "r3"],
	},
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
			"left": Vector2(0.0867, 0.5892),
			"up": Vector2(0.1611, 0.4086),
			"right": Vector2(0.2354, 0.5892),
			"down": Vector2(0.1611, 0.7698),
			"select": Vector2(0.3915, 0.7122),
			"start": Vector2(0.5287, 0.7122),
			"b": Vector2(0.7019, 0.7070),
			"a": Vector2(0.8307, 0.7069),
		},
		# Rows along the top and bottom rather than columns down the sides: this
		# pad is 2.4:1, and a column beside it would put every lead nearly
		# horizontal across the whole picture. Split by anchor height, ordered by
		# anchor x. `down` is on the bottom row despite sharing the cross's x
		# with `up`, because from the top its lead would run through the cross.
		"top": ["left", "up", "right"],
		"bottom": ["down", "select", "start", "b", "a"],
	},
}


## True when this platform has a pad of its own to draw. The generic pad is not
## a platform, so it never answers true here.
static func has(systemid: String) -> bool:
	return not systemid.is_empty() and systemid != RETROPAD and _ROWS.has(systemid)


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
