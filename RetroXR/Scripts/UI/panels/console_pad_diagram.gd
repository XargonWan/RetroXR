## ConsolePadDiagram — the per-platform remap view: a picture of the console's
## OWN controller with a leader line from every control to its own dropdown.
##
## The third of the family, after ControllerDiagram (XR) and GamepadDiagram
## (physical pads), and the only one that is not tied to one piece of hardware:
## the art, anchors and row orders arrive from ConsolePadArt, keyed by systemid.
##
## Direction is the inverse of the other two. Those anchor on the thing in your
## hands and ask "what does this input do?"; this anchors on the console's pad
## and asks "what drives this button?" — which is the question a platform
## override is actually about, and the reason the list of choices is sources
## rather than RetroPad targets. It also means only the controls the hardware has
## are offered: a NES page has no L3 to bind, so it shows none.
##
## Rows run along the top and bottom rather than down the sides. Console pads are
## wide and short, so a column beside one would put every lead nearly horizontal
## across the picture.
class_name ConsolePadDiagram
extends Control

## Emitted when the player picks a new source for `control`.
## `control` is a GamepadBindings target string; `id` is an entry from the
## options array the owner supplied, or "" for unbound.
signal binding_changed(control: String, id: Variant)

## Applied only to line art. A colour illustration is shown as drawn — see
## ConsolePadArt.tints().
const ART_TINT := Color(0.74, 0.78, 0.87)
const LEAD_COLOR := Color(1.0, 0.69, 0.29)
const DOT_COLOR := Color(1.0, 0.80, 0.47)
const LEAD_WIDTH := 2.0
const DOT_RADIUS := 5.0

## Mirrored in Tools/gen_nes_pad_art.py, which verifies that no two leads cross
## at any panel size. Changing one without the other invalidates that check.
const MAX_W := 1520.0
const SLOT_W := 250.0
const ROW_H := 50.0
const ROW_PAD := 14.0
const STUB := 18.0

## Gutter between adjacent slots. SLOT_W is the spacing the layout reserves; a
## dropdown is drawn narrower than that so two pushed hard against each other
## still read as two rows and not one.
const SLOT_GAP := 18.0


var _systemid := ""
var _row: Dictionary = {}
var _drops: Dictionary = {}
var _anchor_px: Dictionary = {}

# The art is DRAWN rather than parented as a TextureRect. A Control renders its
# own _draw() behind its children, so a child would have covered the leader
# lines and the anchor dots — invisible with line art, whose body is nearly
# transparent, and total with a colour illustration.
var _art_tex: Texture2D = null
var _art_rect := Rect2()
var _tint := true


## `options` is the VRDropdown options array of sources to choose from;
## `current` maps control -> the id currently driving it.
func setup(systemid: String, options: Array, current: Dictionary) -> void:
	for c in get_children():
		c.queue_free()
		remove_child(c)
	_drops.clear()

	_systemid = systemid
	_row = ConsolePadArt.row(systemid)
	if _row.is_empty():
		return

	_art_tex = ConsolePadArt.texture(systemid)
	_tint = ConsolePadArt.tints(systemid)

	# Dropdowns are children, so they draw over the art either way.
	for control: String in _controls():
		var label: String = GamepadBindings.TARGET_LABELS.get(control, control)
		var drop := VRDropdown.create(label, options, current.get(control, ""),
			3, Vector2(150, ROW_H - 8), 15)
		drop.tooltip_text = "What drives %s on this system" % label
		drop.float_panel = true
		var captured := control
		drop.item_selected.connect(func(id: Variant) -> void:
			binding_changed.emit(captured, id))
		add_child(drop)
		_drops[control] = drop

	_relayout()


func _controls() -> Array:
	if _row.is_empty():
		return []
	return (_row["top"] as Array) + (_row["bottom"] as Array)


## The VRDropdown driving `control`, so the owning panel can register it.
func get_dropdown(control: String) -> VRDropdown:
	return _drops.get(control) as VRDropdown


## Push a selection into the UI without emitting binding_changed.
func set_binding(control: String, id: Variant) -> void:
	var drop := _drops.get(control) as VRDropdown
	if drop:
		drop.select_id(id)


## Push every selection at once — what a reset needs.
func refresh(current: Dictionary) -> void:
	for control: String in _drops:
		set_binding(control, current.get(control, ""))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_relayout()


## Slot centres for one row.
##
## Each slot starts directly under (or over) its own anchor, so its lead is as
## short and as vertical as it can be; only where two would overlap are they
## pushed apart, order preserved. The forward pass can only push right, so it can
## run off the edge — hence the walk back.
func _slot_xs(order: Array, art: Rect2) -> Array:
	var anchors: Dictionary = _row["anchors"]
	var xs: Array = []
	for control: String in order:
		var uv: Vector2 = anchors[control]
		xs.append(art.position.x + uv.x * art.size.x)

	for i in range(1, xs.size()):
		if float(xs[i]) - float(xs[i - 1]) < SLOT_W:
			xs[i] = float(xs[i - 1]) + SLOT_W

	var over := float(xs[xs.size() - 1]) - (size.x - SLOT_W * 0.5)
	if over > 0.0:
		for i in xs.size():
			xs[i] = float(xs[i]) - over
		for i in range(xs.size() - 2, -1, -1):
			if float(xs[i + 1]) - float(xs[i]) < SLOT_W:
				xs[i] = float(xs[i + 1]) - SLOT_W

	var lo := SLOT_W * 0.5
	if float(xs[0]) < lo:
		var shift := lo - float(xs[0])
		for i in xs.size():
			xs[i] = float(xs[i]) + shift
	return xs


func _relayout() -> void:
	if _art_tex == null or _row.is_empty():
		return

	var band_w := minf(size.x, MAX_W)
	var art_h := size.y - 2.0 * (ROW_H + ROW_PAD)
	if art_h <= 0.0:
		return
	var aspect := float(_art_tex.get_width()) / float(_art_tex.get_height())
	var art_w := art_h * aspect
	if art_w > band_w:
		art_w = band_w
		art_h = art_w / aspect

	var r := Rect2(Vector2((size.x - art_w) * 0.5, (size.y - art_h) * 0.5),
		Vector2(art_w, art_h))
	_art_rect = r

	for top in [true, false]:
		var order: Array = _row["top"] if top else _row["bottom"]
		var xs := _slot_xs(order, r)
		var row_y := 0.0 if top else size.y - ROW_H
		for i in order.size():
			var drop := _drops.get(order[i]) as VRDropdown
			if drop == null:
				continue
			drop.position = Vector2(float(xs[i]) - (SLOT_W - SLOT_GAP) * 0.5, row_y)
			drop.size = Vector2(SLOT_W - SLOT_GAP, ROW_H)
			# Keep the floating option list inside this control's band.
			drop.float_max_bottom = global_position.y + size.y

	_anchor_px.clear()
	var anchors: Dictionary = _row["anchors"]
	for control: String in anchors:
		var uv: Vector2 = anchors[control]
		_anchor_px[control] = r.position + uv * r.size

	queue_redraw()


func _draw() -> void:
	if _row.is_empty():
		return
	if _art_tex != null and _art_rect.size.x > 0.0:
		draw_texture_rect(_art_tex, _art_rect, false,
			ART_TINT if _tint else Color.WHITE)
	for top in [true, false]:
		var order: Array = _row["top"] if top else _row["bottom"]
		for control: String in order:
			var drop := _drops.get(control) as VRDropdown
			if drop == null or not _anchor_px.has(control):
				continue

			var anchor: Vector2 = _anchor_px[control]
			# Meet the row, not the expanded panel: the toggle is the top row.
			var cx := drop.position.x + SLOT_W * 0.5
			var edge := Vector2(cx, drop.position.y + (ROW_H if top else 0.0))
			var stub := Vector2(cx, edge.y + (STUB if top else -STUB))
			draw_line(edge, stub, LEAD_COLOR, LEAD_WIDTH, true)
			draw_line(stub, anchor, LEAD_COLOR, LEAD_WIDTH, true)
			draw_circle(anchor, DOT_RADIUS, DOT_COLOR, true)
