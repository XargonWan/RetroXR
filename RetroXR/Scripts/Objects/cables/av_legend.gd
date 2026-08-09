## The printed legend around a device's composite sockets — the outlined box, the
## words under the jacks, and the AV IN / AV OUT heading naming which way the signal
## flows. What a real back panel silk-screens there, and the only thing on the
## cabinet that says those three chrome rings are what you plug into.
##
## MEASURED off the sockets rather than authored per device, because devices do not
## agree on the row. Seen from outside the panel the decks read R, L, VIDEO while the
## television reads VIDEO, L, R: both author ascending x, and device +X is on the
## viewer's LEFT from behind, so the same numbers come out in opposite orders. A
## legend that reads the sockets it labels cannot print R-AUDIO-L over a row running
## the other way. Nor is the row always on the back — a shell can mould its jacks on
## a flank — so the panel's own frame is derived too, and nothing here assumes -Z.
class_name AvLegend
extends Node3D


## How far back from a port's origin the panel face is. rca_port.tscn seats the zone
## 10 mm proud and pushes the jack back by that much so its flange lands on the
## panel, so backing off by slightly less puts the legend half a millimetre in FRONT
## of the panel — where pc_tower.tscn's silkscreen sits, and clear of z-fighting.
const PANEL_STANDOFF := 0.0095

## Flange radius of the socket being surrounded (gen_rca_jack.gd FLANGE_R). What the
## words have to clear, and the minimum half-width of the plate.
const JACK_RADIUS := 0.0048

## font_size is the size the glyphs are RASTERISED at, not the size they come out.
## Asking for a 5 mm font builds a five-pixel-tall atlas and magnifies a smear, so
## every label here is rastered large and scaled down through pixel_size. Same recipe
## pc_tower.tscn documents for its own back-panel silkscreen.
const RASTER := 48

## Unshaded, all three. These rooms light with a flat ambient and no radiance map, so
## a shaded near-black plate renders at whatever the ambient gives it and the border
## that has to read against a dark deck stops reading. Darkness by MATERIAL is the
## same call gen_rca_jack.gd makes for the socket bore.
const INK := Color(0.90, 0.90, 0.87)
const PLATE := Color(0.055, 0.055, 0.065)
const BORDER := Color(0.72, 0.72, 0.69)

## Worn only when the plate is off, where the cabinet behind the words could be any
## colour — a white monitor back or a black one. Light ink inside a dark outline
## reads on both. On the plate it is the plate that supplies the contrast, and an
## outline there only fuses the glyphs into a blob.
const OUTLINE := Color(0.03, 0.03, 0.04)
const OUTLINE_RASTER := 12

## Stacking order out of the panel. 0.2 mm apart is plenty to keep the border, the
## plate and the text off each other's depth values at arm's length.
const Z_BORDER := 0.0
const Z_PLATE := 0.0002
const Z_TEXT := 0.0006


## Panel face to the row centre. Left exported so a bespoke shell whose jacks are not
## seated on the 10 mm convention can say so.
@export var standoff: float = PANEL_STANDOFF

## Cap line of the words under the jacks, and of the AV IN / AV OUT heading. Both
## generous against the real thing, which prints these at about 2 mm — the point is
## to be read across a room-lit cabinet, not to be to scale.
@export var word_height: float = 0.0045
@export var heading_height: float = 0.007

## Clear space between the outermost thing printed and the edge of the plate.
@export var plate_margin: float = 0.006

## Thickness of the light border drawn round the plate.
@export var border_width: float = 0.0008

## Off for a panel the plate would clip. A moulded CRT back is the case that needs
## it: both cabinet shells in the project taper 16 mm and 46 mm across the plate's
## own footprint, so a flat rectangle either floats off the curve or cuts into it.
## The words survive on their own — they pick up an outline in exchange.
@export var show_plate: bool = true


var _ports: Array[RcaPort] = []


## Build a legend for `ports` and hang it on `device`, which must be the node those
## ports are children of — every offset here is measured in that frame.
##
## Returns null for an empty or dead list rather than an empty node, so a caller can
## hand the result straight to a model hook.
static func attach(device: Node3D, ports: Array) -> AvLegend:
	var live: Array[RcaPort] = []
	for p in ports:
		var port := p as RcaPort
		if port != null and is_instance_valid(port):
			live.append(port)
	if live.is_empty():
		return null
	var legend := AvLegend.new()
	legend.name = "AvLegend"
	legend._ports = live
	device.add_child(legend)
	legend.rebuild()
	return legend


## Lay the legend out from scratch. Call it after changing any of the exports above;
## attach() has already called it once.
func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	if _ports.is_empty():
		return
	transform = _panel_frame()

	# Port offsets in the legend's own frame: x runs left-to-right as seen from
	# outside the panel, y up, z out. Sorting on x is what makes the printed order
	# the order a player actually sees.
	var inv := transform.affine_inverse()
	var row: Array[RcaPort] = _ports.duplicate()
	row.sort_custom(func(a: RcaPort, b: RcaPort) -> bool:
		return (inv * a.position).x < (inv * b.position).x)
	var xs := PackedFloat32Array()
	for p in row:
		xs.append((inv * p.position).x)

	var word_text := PackedStringArray()
	var word_x := PackedFloat32Array()
	_lay_out_words(row, xs, word_text, word_x)
	var heading := "AV IN" if _ports[0].direction == RcaPort.Direction.IN else "AV OUT"

	var word_y := -(JACK_RADIUS + word_height * 0.9)
	var head_y := word_y - word_height * 0.6 - heading_height * 0.8

	# The plate is symmetric about the row centre, which is where the heading is
	# centred; every printed thing has to fit inside it.
	var half := _text_width(heading, heading_height) * 0.5
	for i in word_text.size():
		half = maxf(half, absf(word_x[i]) + _text_width(word_text[i], word_height) * 0.5)
	for x in xs:
		half = maxf(half, absf(x) + JACK_RADIUS)
	half += plate_margin
	var top := JACK_RADIUS + plate_margin
	var bottom := head_y - heading_height * 0.8 - plate_margin

	if show_plate:
		var size := Vector2(half * 2.0, top - bottom)
		var mid := (top + bottom) * 0.5
		_add_quad(size + Vector2(border_width, border_width) * 2.0, mid, Z_BORDER, BORDER)
		_add_quad(size, mid, Z_PLATE, PLATE)

	for i in word_text.size():
		_add_label(word_text[i], word_x[i], word_y, word_height)
	_add_label(heading, 0.0, head_y, heading_height)


## The words under the jacks. An adjacent L/R pair is bracketed by ONE string spanning
## both — "R-AUDIO-L" the way the hardware prints it — which is also what keeps the
## line inside 18 mm centres, since "AUDIO R" alone is wider than the pitch. A console
## with a single audio jack (mono hardware) gets the bare word.
func _lay_out_words(row: Array[RcaPort], xs: PackedFloat32Array,
		out_text: PackedStringArray, out_x: PackedFloat32Array) -> void:
	var audio: PackedInt32Array = []
	for i in row.size():
		if row[i].channel == RcaPort.Channel.VIDEO:
			out_text.append("VIDEO")
			out_x.append(xs[i])
		else:
			audio.append(i)
	if audio.size() == 2 and absi(audio[0] - audio[1]) == 1:
		var a := audio[0]
		var b := audio[1]
		out_text.append("%s-AUDIO-%s" % [row[a].channel_name(), row[b].channel_name()])
		out_x.append((xs[a] + xs[b]) * 0.5)
		return
	for i in audio:
		out_text.append("AUDIO" if audio.size() == 1 else "AUDIO " + row[i].channel_name())
		out_x.append(xs[i])


## The panel the sockets are mounted in, as a transform in the device's frame.
##
##   n  the direction a plug arrives from, which is the panel's outward normal
##   u  the device's own up, flattened into the panel — not the world's, so a legend
##      stays printed the same way up however the cabinet is carried or tipped
##   r  u x n, the panel's right; on a rear panel this works out to Ry(180), which is
##      exactly what pc_tower.tscn hand-authors so its words read from behind
func _panel_frame() -> Transform3D:
	var n := _ports[0].transform.basis.z.normalized()
	var u := Vector3.UP - n * Vector3.UP.dot(n)
	if u.length_squared() < 1e-6:
		# A socket in a face that IS the top or the bottom: nothing to flatten, so
		# take the port's own up instead.
		var own := _ports[0].transform.basis.y
		u = own - n * own.dot(n)
	u = u.normalized()
	var centre := Vector3.ZERO
	for p in _ports:
		centre += p.position
	centre /= float(_ports.size())
	return Transform3D(Basis(u.cross(n), u, n), centre - n * standoff)


func _add_label(text: String, x: float, y: float, height: float) -> void:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = RASTER
	lbl.pixel_size = height / float(RASTER)
	lbl.outline_size = 0 if show_plate else OUTLINE_RASTER
	lbl.outline_modulate = OUTLINE
	lbl.modulate = INK
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	# Depth test STAYS on: a legend that draws through the cabinet would be readable
	# from the front of the device, where there is no panel.
	lbl.no_depth_test = false
	lbl.position = Vector3(x, y, Z_TEXT)
	add_child(lbl)


func _add_quad(size: Vector2, y: float, z: float, colour: Color) -> void:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0.0, y, z)
	add_child(mi)


## Width a label will come out, in metres. Measured off the font rather than off the
## built Label3D's AABB, which is not there until the node has drawn — the reason
## RetroSystem has to defer _place_name_label.
static func _text_width(text: String, height: float) -> float:
	var f: Font = ThemeDB.fallback_font
	if f == null:
		return 0.0
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, RASTER).x
	return w * height / float(RASTER)
