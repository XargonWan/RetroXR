## HeldHint — a tooltip that floats over a held object, telling the player the
## non-obvious verbs it has.
##
## Two interactions in this project are undiscoverable: the drop combo
## (grip+trigger+stick-click in VR, Shift+click on desktop) and Scroll Lock
## capture on desktop. Both are "you are holding a thing with a hidden verb", so
## they share one popup that can carry several rows rather than one mechanism
## each.
##
## A Node3D rather than a RefCounted like its sibling ScrollLockCapture: the
## popup trails the hand under its own _process, and there is nowhere to put
## per-frame work in the RefCounted-owning-a-Label3D shape.
##
## ScrollLockCapture's own glyph stays. That one means "capture is ON right now";
## a row here means "you may press Scroll Lock". Status versus teaching.
##
##   var hint := HeldHint.attach(self, true)
##   hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
##       ["keyboard_scroll_lock_outline"], "Send keys here")
class_name HeldHint
extends Node3D

const PLATFORM_VR := 1
const PLATFORM_DESKTOP := 2
const PLATFORM_BOTH := 3

## When a row applies. A verb about turning the thing you are holding is noise
## once it is on the floor, and "point at it" is noise while it is in your hand.
## Showing every row at both moments was exactly that bug.
const WHEN_HELD := 1
const WHEN_PLACED := 2
const WHEN_ANY := 3

const GLYPH_DIR := "res://Textures/InputPrompts"

## Marker in a caption where the glyphs belong, for a row that reads as a
## sentence — "Point and press {g} for options" — rather than leading with the
## art. Absent, the glyphs come first, which is what every other row wants.
const GLYPH_TOKEN := "{g}"

## Rows stop appearing once the player has used that verb this many times.
const LEARNED_AFTER := 3

## Seconds fully visible, then seconds spent fading out.
const HOLD_SECONDS := 5.0
const FADE_SECONDS := 0.8

## Easing rate for the trail, in 1/seconds. Used as 1-exp(-RATE*delta) so the
## motion is identical at 72, 90 and 120 Hz — a plain lerp weight is a different
## spring at each, and this app runs all three.
const FOLLOW_RATE := 11.0

## Panel metrics, in viewport pixels.
const GLYPH_PX := 56
const ROW_H := 68
const PAD := 16
const SEP := 8
const CAPTION_PT := 30
## Rough width of the "+" between glyphs, including its own separations.
const PLUS_W := 18
## Metres per viewport pixel. The panel is sized to its content rather than to a
## fixed width, so this — not a width in metres — is what fixes the apparent size.
const M_PER_PX := 0.00042

## The drop row's glyphs. {side} -> left|right, {s} -> l|r: the Kenney set names
## the grip and trigger art one way and the stick art the other.
const VR_DROP_GLYPHS: Array[String] = [
	"quest_grip_{side}_outline",
	"quest_trigger_{side}_outline",
	"quest_stick_{s}_press",
]
const DESKTOP_DROP_GLYPHS: Array[String] = [
	"keyboard_shift_outline",
	"mouse_left_outline",
]

var _host: Node3D = null
## Set by pin_to_host: an offset in the host's own space, used instead of the
## default "straight up, in world space".
var _local_offset := Vector3.ZERO
var _pinned := false
var _height := 0.18
## Whether the host uses the VR drop combo. The DESKTOP drop rule is not declared
## here — it is read off the host, see _needs_desktop_modifier.
var _vr_combo_drop := false

# Declared rows: [id, platform, glyphs, caption].
var _rows: Array = []

var _viewport: SubViewport = null
var _panel: PanelContainer = null
var _rows_box: VBoxContainer = null
var _sprite: Sprite3D = null

var _time_left := 0.0
## Ids already counted during this hold. The VR combo branches re-evaluate every
## frame the combo is held, so an uncounted note_used would burn through
## LEARNED_AFTER in three frames instead of three drops.
var _used_this_hold: Dictionary = {}
## Row ids this popup has actually put on screen. note_used refuses to count a
## verb the player was never taught.
var _ever_shown: Dictionary = {}


static func attach(host: Node3D, vr_combo_drop: bool, height := 0.18) -> HeldHint:
	var hint := HeldHint.new()
	hint.name = "HeldHint"
	hint._host = host
	hint._vr_combo_drop = vr_combo_drop
	hint._height = height
	host.add_child(hint)
	return hint


## The hint on `host`, made if it has none. Several things now teach verbs about
## the same object — the object's own script, and the spawner — and they must
## share one popup: two floating over one console would be worse than neither.
static func for_node(host: Node3D, vr_combo_drop := false, height := 0.18) -> HeldHint:
	if not is_instance_valid(host):
		return null
	var existing := host.get_node_or_null("HeldHint") as HeldHint
	if existing != null:
		return existing
	return attach(host, vr_combo_drop, height)


## Declare a hint row. `glyphs` are InputPrompts texture basenames, optionally
## carrying {side}/{s} tokens for per-hand art.
##
## Ignores a repeat of an id already declared, so a caller that cannot know
## whether it is first — the spawner, adding the same row to every object it
## makes — does not have to check.
func add_row(id: StringName, platform: int, glyphs: Array, caption: String,
			 when := WHEN_ANY, once := false) -> void:
	for r: Array in _rows:
		if r[0] == id:
			return
	_rows.append([id, platform, glyphs, caption, when, once])


## Show whatever applies, with no grab behind it: a hint about an object sitting
## in the room, or about the world. on_grabbed reads the platform and the hand
## off the grabber, and here there is nobody holding it — so the platform comes
## from the runtime, and the art defaults to the left hand, which is the one
## both of these verbs are on.
func show_unheld() -> void:
	_used_this_hold.clear()
	var due := _due_rows(PLATFORM_DESKTOP if not _is_vr() else PLATFORM_VR, WHEN_PLACED)
	if due.is_empty():
		hide_now()
		return
	_build(due, false)
	_show()
	_consume_once(due)


static func _is_vr() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


## Lift the popup clear of the host's own geometry.
##
## The 0.18 m default is a hand measurement — it suits a controller or a
## handheld held up in front of you. A TV, a console or a cartridge standing on
## a surface is taller than that about its own origin, so the popup opens inside
## the object and reads as belonging to the hand that spawned it rather than to
## the thing itself.
func fit_above(margin := 0.10) -> void:
	if not is_instance_valid(_host):
		return
	_height = maxf(_visual_top(_host), 0.0) + margin


## Highest point of the host's visible geometry, in host-local metres. Measured
## from the meshes rather than a collision shape: several of these objects carry
## a coarse box collider that is nothing like the silhouette.
static func _visual_top(root: Node3D) -> float:
	var inv := root.global_transform.affine_inverse()
	var top := 0.0
	var found := false
	for node: Node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var ab := mi.get_aabb()
		var to_root := inv * mi.global_transform
		for i in 8:
			var corner := ab.position + ab.size * Vector3(
				float(i & 1), float((i >> 1) & 1), float((i >> 2) & 1))
			var y := (to_root * corner).y
			if not found or y > top:
				top = y
				found = true
	return top if found else 0.0


## The grip+trigger+stick-click drop combo. Lives here so the four hosts that
## test it and the row that advertises it cannot disagree.
static func is_combo_pressed(ctrl: XRController3D) -> bool:
	return is_instance_valid(ctrl) \
		and ctrl.get_float("grip") > 0.5 \
		and ctrl.get_float("trigger") > 0.5 \
		and ctrl.get_float("primary_click") > 0.5


## Show whatever applies, given how the object was picked up. `by` is the grabber
## the pickable reports: a member of "desktop_hand" for a desktop grab, otherwise
## an XRToolsFunctionPickup whose controller names the hand.
func on_grabbed(by: Node3D) -> void:
	_used_this_hold.clear()
	var desktop := is_instance_valid(by) and by.is_in_group("desktop_hand")
	var right := true
	if not desktop and is_instance_valid(by) and by.has_method("get_controller"):
		var ctrl: XRController3D = by.call("get_controller")
		if is_instance_valid(ctrl):
			right = ctrl.tracker != &"left_hand"

	var due := _due_rows(PLATFORM_DESKTOP if desktop else PLATFORM_VR, WHEN_HELD)
	if due.is_empty():
		hide_now()
		return
	_build(due, right)
	_show()
	_consume_once(due)


func on_dropped() -> void:
	hide_now()


## Count one successful use of a verb, at most once per hold. Past LEARNED_AFTER
## that row stops showing.
func note_used(id: StringName) -> void:
	var key := String(id)
	# Only a row that has actually been shown can be learned. The menu row is the
	# case that forced this: its use was counted on every menu toggle, but you
	# have to open the menu to spawn anything and spawning is what shows the row
	# — so three spawns retired it, quite possibly without it ever being seen.
	if not _ever_shown.has(key):
		return
	if _used_this_hold.has(key):
		return
	_used_this_hold[key] = true
	var uses := int(AppPrefs.hint_uses.get(key, 0))
	if uses >= LEARNED_AFTER:
		return
	AppPrefs.hint_uses[key] = uses + 1
	AppPrefs.save_prefs()


## Count a use against whichever object is holding the hint. Lets code that acts
## on a held object without owning its hint — desktop_pickup, ScrollLockCapture —
## report one without every host having to forward a call.
static func note_on(host: Node, id: StringName) -> void:
	if not is_instance_valid(host):
		return
	var hint := host.get_node_or_null("HeldHint") as HeldHint
	if hint != null:
		hint.note_used(id)


func hide_now() -> void:
	visible = false
	_time_left = 0.0


# ── Row selection ─────────────────────────────────────────────────────────────

## Declared rows that apply on this platform and are not yet learned, plus the
## drop row when this platform actually requires one.
func _due_rows(platform: int, when: int) -> Array:
	var out: Array = []
	if AppPrefs.show_hints:
		# How to let go of it is a held-object verb like any other: it has no
		# business appearing over something already on the floor.
		var drop := _drop_row(platform)
		if not drop.is_empty() and (WHEN_HELD & when) != 0 and _unlearned(drop[0]):
			out.append(drop)
		for row: Array in _rows:
			if (int(row[1]) & platform) != 0 and (int(row[4]) & when) != 0 \
					and _unlearned(row[0]):
				out.append(row)
	return out


## Drop the rows that were only ever meant to be seen once. Called after they
## have been shown, so "the first time you put it down" really is only the first.
func _consume_once(shown: Array) -> void:
	var spent: Array = []
	for row: Array in shown:
		if bool(row[5]):
			spent.append(row[0])
	if spent.is_empty():
		return
	var kept: Array = []
	for row: Array in _rows:
		if not spent.has(row[0]):
			kept.append(row)
	_rows = kept


func _unlearned(id: StringName) -> bool:
	return int(AppPrefs.hint_uses.get(String(id), 0)) < LEARNED_AFTER


## [] when this platform lets the object go on a plain release. The two rules are
## genuinely different: a mouse needs Shift on desktop but drops on a plain grip
## release in VR, and a controller is the other way round.
func _drop_row(platform: int) -> Array:
	if platform == PLATFORM_VR:
		if not _vr_combo_drop:
			return []
		return [&"drop_vr", PLATFORM_VR, VR_DROP_GLYPHS, "Drop", WHEN_HELD, false]
	if not _needs_desktop_modifier():
		return []
	return [&"drop_desktop", PLATFORM_DESKTOP, DESKTOP_DROP_GLYPHS, "Drop",
		WHEN_HELD, false]


## Read from the host, not declared: these are the same two properties
## desktop_pickup.gd tests to decide whether Shift is required, so the hint
## cannot drift from the rule it describes.
func _needs_desktop_modifier() -> bool:
	if not is_instance_valid(_host):
		return false
	# Compared against true rather than coerced: a host that has neither property
	# — every handheld and controller — returns null from get(), and null is not
	# something bool() will take.
	return _host.get("desktop_fps_snap") == true or _host.get("desktop_shift_drop") == true


# ── Presentation ──────────────────────────────────────────────────────────────

func _build(rows: Array, right_hand: bool) -> void:
	_ensure_nodes()
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()

	var font: Font = ThemeDB.fallback_font
	var widest := 0
	for row: Array in rows:
		_ever_shown[String(row[0])] = true
		var line := HBoxContainer.new()
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", SEP)
		var glyphs: Array = row[2]
		# A caption may put the glyphs inside the sentence with {g} — "Point and
		# press {g} for options" — rather than leading with them. Without the
		# token the glyphs come first, which is what every existing row expects.
		var text := String(row[3])
		var before := ""
		var after := text
		if text.contains(GLYPH_TOKEN):
			var parts := text.split(GLYPH_TOKEN, true, 1)
			before = parts[0].strip_edges()
			after = parts[1].strip_edges() if parts.size() > 1 else ""

		if not before.is_empty():
			line.add_child(_caption(before))
		for i in glyphs.size():
			if i > 0:
				line.add_child(_plus())
			line.add_child(_glyph(String(glyphs[i]), right_hand))
		if not after.is_empty():
			line.add_child(_caption(after))
		_rows_box.add_child(line)

		# Measured rather than left to a fixed panel width: a one-glyph row in a
		# box sized for a three-glyph one is mostly empty border.
		var n := glyphs.size()
		var w := n * GLYPH_PX + (n - 1) * PLUS_W + (2 * n) * SEP
		for part: String in [before, after]:
			if not part.is_empty():
				w += int(font.get_string_size(
					part, HORIZONTAL_ALIGNMENT_LEFT, -1, CAPTION_PT).x) + SEP
		widest = maxi(widest, w)

	_viewport.size = Vector2i(widest + PAD * 2, PAD * 2 + ROW_H * rows.size())
	_sprite.pixel_size = M_PER_PX
	# UPDATE_ONCE, never UPDATE_ALWAYS: an always-updating SubViewport hangs a
	# headless run, and this content only changes when the rows do.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", CAPTION_PT)
	label.add_theme_color_override("font_color", Color(0.93, 0.94, 1.0))
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _glyph(pattern: String, right_hand: bool) -> TextureRect:
	var file := pattern \
		.replace("{side}", "right" if right_hand else "left") \
		.replace("{s}", "r" if right_hand else "l")
	var rect := TextureRect.new()
	var path := "%s/%s.png" % [GLYPH_DIR, file]
	if ResourceLoader.exists(path):
		rect.texture = ResourceLoader.load(path) as Texture2D
	else:
		push_warning("HeldHint: no glyph %s" % path)
	rect.custom_minimum_size = Vector2(GLYPH_PX, GLYPH_PX)
	# The Quest art is 128 px and the keyboard art 64 px. Without this the
	# texture's own size becomes the minimum and the two rows disagree.
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return rect


func _plus() -> Label:
	var lbl := Label.new()
	lbl.text = "+"
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color(0.70, 0.73, 0.85))
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


func _ensure_nodes() -> void:
	if _viewport != null:
		return

	top_level = true

	_viewport = SubViewport.new()
	_viewport.name = "HintViewport"
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.12, 0.88)
	style.border_color = Color(1.0, 0.82, 0.28, 0.85)
	style.set_border_width_all(3)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(PAD)
	_panel.add_theme_stylebox_override("panel", style)
	_viewport.add_child(_panel)

	_rows_box = VBoxContainer.new()
	_rows_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_rows_box.add_theme_constant_override("separation", 6)
	_panel.add_child(_rows_box)

	_sprite = Sprite3D.new()
	_sprite.name = "HintSprite"
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true
	# Above ScrollLockCapture's glyph, which uses 2.
	_sprite.render_priority = 3
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.texture = _viewport.get_texture()
	add_child(_sprite)


func _show() -> void:
	_time_left = HOLD_SECONDS + FADE_SECONDS
	if _sprite:
		_sprite.modulate = Color.WHITE
	global_position = _anchor()
	visible = true
	# The project runs with physics interpolation on, and a top_level node holds
	# the world origin until its first sync — without this the popup streaks in
	# from the origin for a frame or two on its first show.
	reset_physics_interpolation()


# ── Trailing ──────────────────────────────────────────────────────────────────

## Ride the host's own orientation at `offset` instead of hovering above it.
##
## For a hint that belongs to the player rather than to a thing: pinned by the
## left hand, or parked in the corner of the view. Those hosts turn with you and
## the popup has to turn with them, which the default cannot do — it is
## deliberately world-up so a controller rolling in the hand does not send the
## popup orbiting.
func pin_to_host(offset: Vector3) -> void:
	_local_offset = offset
	_pinned = true


func _anchor() -> Vector3:
	if not is_instance_valid(_host):
		return global_position
	if _pinned:
		return _host.global_transform * _local_offset
	# World up, not host-local: a controller rolls around in the hand and the
	# popup should stay above it rather than orbit it.
	return _host.global_position + Vector3.UP * _height


func _process(delta: float) -> void:
	if not visible:
		return
	if not is_instance_valid(_host):
		hide_now()
		return

	global_position = global_position.lerp(_anchor(), 1.0 - exp(-FOLLOW_RATE * delta))

	_time_left -= delta
	if _time_left <= 0.0:
		hide_now()
	elif _sprite and _time_left < FADE_SECONDS:
		_sprite.modulate = Color(1.0, 1.0, 1.0, _time_left / FADE_SECONDS)
