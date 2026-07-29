## Reusable drill-down browser for "lots of systems" lists (cores, ROMs, …).
##
## Home page  : optional filter box + a wrapping grid of big system tiles.
## Detail page: a "◀ Back" header + a scroll area filled on demand by the caller's
##              populator with that one system's rows.
##
## Only one page is visible at a time (VR-friendly: one level, big targets, no
## horizontally-scrolling tab strip). The host wires `active_scroll_changed` into
## its VR trigger-scroll plumbing so the visible page scrolls.
##
## Usage:
##   var b := SystemGridBrowser.new()
##   b.set_detail_populator(func(sid, vbox): ...fill vbox with sid's rows...)
##   b.set_systems([{ "systemid": "nes", "name": "Nintendo (NES)", "badge": "3 cores" }, ...])
class_name SystemGridBrowser
extends VBoxContainer

## Emitted whenever the visible page changes (home ↔ detail); carries the
## ScrollContainer the host should treat as the active scroll target.
signal active_scroll_changed(scroll: ScrollContainer)
## Emitted after a system tile is opened.
signal system_opened(systemid: String)

# Palette — mirrors spawn_menu.gd so the widget matches the surrounding UI.
const COLOR_TITLE      := Color(0.9,  0.9,  1.0)
const COLOR_DESC       := Color(0.55, 0.55, 0.68)
const COLOR_LICENSE    := Color(0.65, 0.65, 0.80)
const COLOR_TILE       := Color(0.14, 0.14, 0.28)
const COLOR_TILE_HOVER := Color(0.24, 0.24, 0.46)

# ── Config (set before the node enters the tree, or any time) ──────────────────
## Show the pointer-first filter box on the home page.
var show_filter: bool = true
## Placeholder shown in the filter box.
var filter_placeholder: String = "Filter systems…"
## Message shown when there are no systems.
var empty_text: String = "Nothing here yet."
## Minimum size of each system tile.
var tile_min_size: Vector2 = Vector2(250, 96)

## Edge of the square the console art is fitted into, inside a tile.
const ICON_PX := 60.0
## Source-badge mark in the tile's bottom-right corner.
const BADGE_MARK_PX := 26.0
## Right margin the name column gives up so it cannot run under that badge.
const BADGE_RESERVE_PX := 52.0

# ── State ──────────────────────────────────────────────────────────────────────
# Each entry: { "systemid": String, "name": String, "badge": String (optional) }
var _systems: Array = []
var _detail_populator: Callable = Callable()
var _current_systemid: String = ""
var _built: bool = false

# ── Nodes ──────────────────────────────────────────────────────────────────────
var _home_page:    VBoxContainer   = null
var _detail_page:  VBoxContainer   = null
var _filter_edit:  LineEdit        = null
var _home_scroll:  ScrollContainer = null
var _tiles_flow:   HFlowContainer  = null
var _home_empty:   Label           = null
var _detail_scroll: ScrollContainer = null
var _detail_vbox:  VBoxContainer   = null
var _detail_title: Label           = null


func _ready() -> void:
	_ensure_built()


# ── Public API ─────────────────────────────────────────────────────────────────

## Replace the system list and rebuild the home grid. Keeps the current page.
func set_systems(systems: Array) -> void:
	_ensure_built()
	_systems = systems.duplicate(true)
	_systems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("name", "") as String).naturalnocasecmp_to(b.get("name", "")) < 0
	)
	_rebuild_tiles()


## Provide the callback that fills a system's detail page:
## `func(systemid: String, vbox: VBoxContainer) -> void`.
func set_detail_populator(cb: Callable) -> void:
	_detail_populator = cb


## Open a system's detail page and (re)run the populator for it.
func open_system(systemid: String) -> void:
	_ensure_built()
	_current_systemid = systemid
	for c in _detail_vbox.get_children():
		c.queue_free()
	var name := systemid
	for s: Dictionary in _systems:
		if s.get("systemid", "") == systemid:
			name = s.get("name", systemid)
			break
	_detail_title.text = name
	if _detail_populator.is_valid():
		_detail_populator.call(systemid, _detail_vbox)
	_home_page.visible = false
	_detail_page.visible = true
	_detail_scroll.scroll_vertical = 0
	system_opened.emit(systemid)
	active_scroll_changed.emit(_detail_scroll)


## Return to the home grid.
func show_home() -> void:
	_ensure_built()
	_current_systemid = ""
	_detail_page.visible = false
	_home_page.visible = true
	active_scroll_changed.emit(_home_scroll)


## Rebuild home tiles; if a detail page is open, re-run its populator.
func refresh() -> void:
	_ensure_built()
	_rebuild_tiles()
	if _detail_page.visible and not _current_systemid.is_empty():
		open_system(_current_systemid)


## The ScrollContainer of the currently-visible page (for _active_scroll wiring).
func get_active_scroll() -> ScrollContainer:
	_ensure_built()
	return _detail_scroll if _detail_page.visible else _home_scroll


# ── Build ──────────────────────────────────────────────────────────────────────

func _ensure_built() -> void:
	if _built:
		return
	_built = true

	# Home page ---------------------------------------------------------------
	_home_page = VBoxContainer.new()
	_home_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_home_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_page.add_theme_constant_override("separation", 8)
	add_child(_home_page)

	if show_filter:
		_filter_edit = LineEdit.new()
		_filter_edit.placeholder_text = filter_placeholder
		_filter_edit.clear_button_enabled = true
		_filter_edit.custom_minimum_size = Vector2(0, 52)
		_filter_edit.add_theme_font_size_override("font_size", 20)
		# Do NOT grab_focus() programmatically — Android EditText desync
		# (Godot #72969). Tap-to-focus opens the overlay keyboard naturally.
		_filter_edit.text_changed.connect(_on_filter_changed)
		_home_page.add_child(_filter_edit)

	_home_scroll = ScrollContainer.new()
	_home_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_home_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_home_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_home_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	_home_page.add_child(_home_scroll)

	_tiles_flow = HFlowContainer.new()
	_tiles_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tiles_flow.add_theme_constant_override("h_separation", 10)
	_tiles_flow.add_theme_constant_override("v_separation", 10)
	_home_scroll.add_child(_tiles_flow)

	_home_empty = Label.new()
	_home_empty.text = empty_text
	_home_empty.add_theme_font_size_override("font_size", 18)
	_home_empty.add_theme_color_override("font_color", COLOR_LICENSE)
	_home_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_home_empty.visible = false
	_home_page.add_child(_home_empty)

	# Detail page -------------------------------------------------------------
	_detail_page = VBoxContainer.new()
	_detail_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_page.add_theme_constant_override("separation", 8)
	_detail_page.visible = false
	add_child(_detail_page)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_detail_page.add_child(header)

	var back := Button.new()
	back.text = "◀  Back"
	back.custom_minimum_size = Vector2(150, 52)
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(show_home)
	header.add_child(back)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 24)
	_detail_title.add_theme_color_override("font_color", COLOR_TITLE)
	_detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_title.clip_text = true
	header.add_child(_detail_title)

	_detail_page.add_child(HSeparator.new())

	_detail_scroll = ScrollContainer.new()
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_detail_scroll.add_theme_constant_override("scrollbar_v_width", 40)
	_detail_page.add_child(_detail_scroll)

	_detail_vbox = VBoxContainer.new()
	_detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_vbox.add_theme_constant_override("separation", 6)
	_detail_scroll.add_child(_detail_vbox)


func _rebuild_tiles() -> void:
	for c in _tiles_flow.get_children():
		c.queue_free()
	_home_empty.visible = _systems.is_empty()
	_home_scroll.visible = not _systems.is_empty()
	for s: Dictionary in _systems:
		_tiles_flow.add_child(_make_tile(s))
	if _filter_edit and not _filter_edit.text.is_empty():
		_on_filter_changed(_filter_edit.text)


func _make_tile(s: Dictionary) -> Button:
	var sid: String   = s.get("systemid", "")
	var name: String  = s.get("name", sid)
	var badge: String = s.get("badge", "")

	var btn := Button.new()
	btn.custom_minimum_size = tile_min_size
	btn.set_meta("filter_name", name.to_lower())

	# Console art on the left, name (and badge) on the right. Laid out as child
	# controls rather than Button.icon + Button.text: Button draws its icon at
	# the texture's own size, and these SVGs import ~165 px on the long edge.
	var mark: Texture2D = s.get("badge_icon")
	var mark_count := int(s.get("badge_count", 0))
	var has_mark := mark != null and mark_count > 0

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	# Keep the name clear of the corner badge, which is an overlay and so does
	# not take part in this layout.
	row.offset_right = -BADGE_RESERVE_PX if has_mark else -12
	row.add_theme_constant_override("separation", 10)
	btn.add_child(row)

	var art := SystemIcons.for_system(sid)
	if art:
		var ico := TextureRect.new()
		ico.texture = art
		ico.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ico)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = name
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# "Super Nintendo Entertainment System" is three lines in the space left
	# beside the art — cap it and ellipsize so a long name can't push the badge
	# out of the tile. The detail page header shows the name in full.
	name_lbl.max_lines_visible = 2
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_lbl)

	if not badge.is_empty():
		var badge_lbl := Label.new()
		badge_lbl.text = badge
		badge_lbl.add_theme_font_size_override("font_size", 16)
		badge_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		badge_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(badge_lbl)

	# Source badge, pinned to the bottom-right corner: a small mark plus a count,
	# outside the name column so a long name cannot push it around.
	if has_mark:
		var corner := VBoxContainer.new()
		corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		corner.alignment = BoxContainer.ALIGNMENT_CENTER
		corner.add_theme_constant_override("separation", 0)
		corner.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		corner.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		corner.grow_vertical = Control.GROW_DIRECTION_BEGIN
		corner.offset_right = -8
		corner.offset_bottom = -6
		btn.add_child(corner)

		var mark_rect := TextureRect.new()
		mark_rect.texture = mark
		mark_rect.custom_minimum_size = Vector2(BADGE_MARK_PX, BADGE_MARK_PX)
		mark_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		corner.add_child(mark_rect)

		var count_lbl := Label.new()
		count_lbl.text = _compact_count(mark_count)
		count_lbl.add_theme_font_size_override("font_size", 14)
		count_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		count_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		corner.add_child(count_lbl)

	var base := StyleBoxFlat.new()
	base.bg_color = COLOR_TILE
	var hover := StyleBoxFlat.new()
	hover.bg_color = COLOR_TILE_HOVER
	for st: StyleBoxFlat in [base, hover]:
		for k in ["corner_radius_top_left", "corner_radius_top_right",
				  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
			st.set(k, 8)
		for m in ["content_margin_left", "content_margin_right"]:
			st.set(m, 12)
	btn.add_theme_stylebox_override("normal",  base)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", hover)

	btn.pressed.connect(open_system.bind(sid))
	return btn


## 78911 in a 26 px corner is unreadable — 78.9k is not.
static func _compact_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 10000:
		return "%dk" % int(round(float(n) / 1000.0))
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)


func _on_filter_changed(text: String) -> void:
	var needle := text.strip_edges().to_lower()
	for tile: Node in _tiles_flow.get_children():
		if tile is Button:
			var hay: String = tile.get_meta("filter_name", "")
			tile.visible = needle.is_empty() or hay.contains(needle)
