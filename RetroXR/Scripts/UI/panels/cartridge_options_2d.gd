## CartridgeOptions2D — 2D UI for a cartridge's battery-save management.
## Loaded into CartridgeOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
##
## Lists every .srm that exists for this game (save recovery — files are never
## deleted) plus "New blank save". Selecting an entry re-binds this cartridge's
## save_id; nothing on disk is touched until the console next flushes.
##
## Saves the RomM server holds but this device does not are listed separately
## and can be pulled down; a local save can be toggled to keep syncing.
##
## Emits:
##   save_selected(save_id) — user picked an existing save ("" = new blank)
##   sync_toggled(save_id, on)
##   server_save_requested(slot) — pull a save that only exists on the server
##   new_synced_save_requested   — start a fresh save already set to sync
##   close_requested        — user pressed ✕
class_name CartridgeOptions2D
extends Control

signal save_selected(save_id: String)
signal sync_toggled(save_id: String, on: bool)
signal server_save_requested(slot: String)
signal new_synced_save_requested
signal close_requested

const COLOR_BG      := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE   := Color(0.9,  0.9,  1.0)
const COLOR_ROW     := Color(0.65, 0.65, 0.80)
const COLOR_CURRENT := Color(0.35, 0.85, 0.45)
const COLOR_MUTED   := Color(0.45, 0.45, 0.58)
const COLOR_SYNC    := Color(0.45, 0.70, 1.00)
const COLOR_WARN    := Color(1.00, 0.72, 0.20)

# Same Nerd Font glyphs the spawn menu uses, so a cloud means the same thing in
# both places. Names are the font's own, read from its post table — a codepoint
# being present in the cmap does not make it the glyph you meant.
const _ICON_CLOUD    := 0xF0ED    # fa-cloud_download    — on the server, not here
const _ICON_SYNC_ON  := 0xF063F   # md-cloud_sync        — kept in step
const _ICON_SYNC_OFF := 0xF0164   # md-cloud_off_outline — local only
const _ICON_BUSY     := 0xF019    # fa-download
const _ICON_WARN     := 0xF071    # fa-warning
const _SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"

## One shared FontVariation — the list is rebuilt on every populate(), and a
## resource per row would churn on each rebuild.
var _symbol_font: FontVariation = null

var _title_lbl: Label = null
## The ROM's path on disk, under the game's name. Small and muted: it is there to
## tell two dumps of the same game apart, not to be read at a glance.
var _path_lbl: Label = null
var _rows_box: VBoxContainer = null
var _active_scroll: ScrollContainer = null

## Ribbons. The saves list was the whole panel until achievements arrived; both
## are properties of the game in your hand, so both belong here rather than in
## the app's settings.
var _tabs: TabContainer = null
var _saves_scroll: ScrollContainer = null
var _ach_scroll: ScrollContainer = null
var _ach_box: VBoxContainer = null
var _ach_summary: Label = null


## Set BEFORE the node enters the tree to drop the panel background and the ✕ —
## what only makes sense when this is a window of its own. The core options panel
## hosts one of these inside its Cartridge tab, where it has both from the panel
## around it. The game's name and path are kept either way: the host's title is
## the console, so nothing else there says which cartridge is in the slot.
var embedded := false

## Can a save be made the current one from here? True whenever there is a
## cartridge to bind it to. The spawn menu's library shows the same saves for a
## ROM with no cartridge in the room: they can be synced and downloaded, but there
## is nothing to make one "current", so the rows are read as a list rather than
## offered as a choice that would quietly do nothing.
var selectable := true


static func create_embedded() -> CartridgeOptions2D:
	var ui := CartridgeOptions2D.new()
	ui.embedded = true
	ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return ui


func _ready() -> void:
	if not embedded:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)

	if embedded:
		root_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(root_vbox)
		# The host panel's title says "System Settings" and its tab says
		# "Cartridge", so nothing here named the game actually in the slot.
		_build_embedded_header(root_vbox)
	else:
		var panel := PanelContainer.new()
		panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var bg := StyleBoxFlat.new()
		bg.bg_color = COLOR_BG
		for corner in ["corner_radius_top_left", "corner_radius_top_right",
				"corner_radius_bottom_left", "corner_radius_bottom_right"]:
			bg.set(corner, 10)
		panel.add_theme_stylebox_override("panel", bg)
		add_child(panel)

		var margin := MarginContainer.new()
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			margin.add_theme_constant_override(side, 12)
		panel.add_child(margin)
		margin.add_child(root_vbox)

		_build_title(root_vbox)
		_path_lbl = _make_path_label()
		root_vbox.add_child(_path_lbl)
		root_vbox.add_child(HSeparator.new())

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_saves_scroll = _ribbon("Saves")
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 4)
	_saves_scroll.add_child(_rows_box)

	_ach_scroll = _ribbon("Achievements")
	# The fat VR scrollbar is 40 px and overlays the content, so the points column
	# needs to end before it — without this margin the score sits under the bar.
	var ach_margin := MarginContainer.new()
	ach_margin.add_theme_constant_override("margin_right", 48)
	ach_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ach_scroll.add_child(ach_margin)

	var ach_vbox := VBoxContainer.new()
	ach_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ach_vbox.add_theme_constant_override("separation", 4)
	ach_margin.add_child(ach_vbox)

	_ach_summary = Label.new()
	_ach_summary.add_theme_font_size_override("font_size", 16)
	_ach_summary.add_theme_color_override("font_color", COLOR_MUTED)
	_ach_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ach_vbox.add_child(_ach_summary)

	_ach_box = VBoxContainer.new()
	_ach_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ach_box.add_theme_constant_override("separation", 4)
	ach_vbox.add_child(_ach_box)

	# The thumbstick drives whichever ribbon is showing, the way the spawn menu's
	# active_scroll() does — a stale reference scrolls the hidden page.
	_tabs.tab_changed.connect(func(_i: int) -> void: _sync_active_scroll())
	_active_scroll = _saves_scroll

	root_vbox.add_child(TabStrip.wrap(_tabs))


func _build_title(root_vbox: VBoxContainer) -> void:
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)

	_title_lbl = Label.new()
	# Not "Battery Save" any more — the saves list is one ribbon of several, and
	# the panel as a whole is about the cartridge.
	_title_lbl.text = "Cartridge"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.add_theme_font_size_override("font_size", 24)
	_title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(_title_lbl)

	var close_btn := Button.new()
	close_btn.text = "  ✕  "
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)


## Name and path for the embedded copy, which has no title row of its own. Sits
## above the ribbons so it heads the whole tab rather than one page of it.
func _build_embedded_header(root_vbox: VBoxContainer) -> void:
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 0)
	root_vbox.add_child(head)

	_title_lbl = Label.new()
	_title_lbl.add_theme_font_size_override("font_size", 20)
	_title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	_title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	head.add_child(_title_lbl)

	_path_lbl = _make_path_label()
	head.add_child(_path_lbl)


## Wrapped rather than trimmed: the filename is the end of a path and the part
## worth reading, so an ellipsis would eat exactly what the line is for. Two
## lines is the ceiling — a third would push the ribbons down the panel.
func _make_path_label() -> Label:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", COLOR_MUTED)
	lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	lbl.max_lines_visible = 2
	lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	lbl.visible = false
	return lbl


func _ribbon(title: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	MenuStyle.fat_vscroll_bar(scroll)
	_tabs.add_child(scroll)
	return scroll


func _sync_active_scroll() -> void:
	_active_scroll = _ach_scroll if _tabs.current_tab == 1 else _saves_scroll


func _symbols() -> FontVariation:
	if _symbol_font != null:
		return _symbol_font
	_symbol_font = FontVariation.new()
	_symbol_font.base_font = ThemeDB.fallback_font
	var symbols: Font = load(_SYMBOL_FONT_PATH)
	if symbols != null:
		_symbol_font.fallbacks = [symbols]
	return _symbol_font


## Rebuild the list.
##   rom_path    : the ROM on disk, shown under the name ("" hides the line)
##   saves       : SramPaths.list_saves() entries
##   current_id  : the cartridge's bound save_id
##   sync_states : save_id -> "off" | "on" | "busy" | "conflict"
##   server_only : [{slot, size, updated_at}] the server has and this device
##                 does not
func populate(game_label: String, rom_path: String, saves: Array, current_id: String,
			  core_known: bool, sync_states: Dictionary = {}, server_only: Array = [],
			  romm_available: bool = false) -> void:
	_title_lbl.text = game_label if not game_label.is_empty() else "Cartridge"
	_path_lbl.text = rom_path
	_path_lbl.visible = not rom_path.is_empty()
	for child in _rows_box.get_children():
		child.queue_free()

	if not core_known:
		var note := Label.new()
		note.text = "Insert this cartridge into a console once\nto discover its saves."
		note.add_theme_font_size_override("font_size", 18)
		note.add_theme_color_override("font_color", COLOR_ROW)
		_rows_box.add_child(note)
		return

	if selectable:
		_add_new_row(current_id.is_empty() or not _has_id(saves, current_id), romm_available)
	else:
		# Starting a save needs something to start it on. Say so once, above the
		# list, rather than leaving rows that look pressable and are not.
		var note := Label.new()
		note.text = "Spawn this cartridge to choose which save it uses."
		note.add_theme_font_size_override("font_size", 16)
		note.add_theme_color_override("font_color", COLOR_MUTED)
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_rows_box.add_child(note)
		if saves.is_empty() and server_only.is_empty():
			var empty := Label.new()
			empty.text = "No saves for this game yet."
			empty.add_theme_font_size_override("font_size", 18)
			empty.add_theme_color_override("font_color", COLOR_ROW)
			_rows_box.add_child(empty)

	for s: Variant in saves:
		var d := s as Dictionary
		var save_id := str(d.get("save_id", ""))
		var when := Time.get_datetime_string_from_unix_time(int(d.get("mtime", 0))).replace("T", "  ")
		var text := "%s    %s    %.1f KB" % [save_id.left(8), when, int(d.get("size", 0)) / 1024.0]
		_add_row(text, save_id, save_id == current_id,
			str(sync_states.get(save_id, "off")), romm_available)

	if server_only.is_empty():
		return

	var head := Label.new()
	head.text = "  On RomM"
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", COLOR_MUTED)
	_rows_box.add_child(head)

	for e: Variant in server_only:
		_add_server_row(e as Dictionary)


## Starting a fresh save. The synced variant mints the same kind of identity
## and turns sync on before anything is written, so the first flush uploads
## rather than the user having to remember to come back and toggle it.
func _add_new_row(is_current: bool, romm_available: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	var blank := Button.new()
	blank.custom_minimum_size = Vector2(0, 52)
	blank.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blank.add_theme_font_size_override("font_size", 18)
	blank.alignment = HORIZONTAL_ALIGNMENT_LEFT
	blank.text = ("●  " if is_current else "    ") + "＋  New blank save"
	if is_current:
		blank.add_theme_color_override("font_color", COLOR_CURRENT)
	blank.pressed.connect(func(): save_selected.emit(""))
	row.add_child(blank)

	if not romm_available:
		return

	var synced := Button.new()
	synced.custom_minimum_size = Vector2(0, 52)
	synced.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	synced.add_theme_font_size_override("font_size", 18)
	synced.alignment = HORIZONTAL_ALIGNMENT_LEFT
	synced.add_theme_font_override("font", _symbols())
	synced.text = "  %s  New synced save" % String.chr(_ICON_SYNC_ON)
	synced.add_theme_color_override("font_color", COLOR_SYNC)
	synced.tooltip_text = "Start a save that is kept on RomM from the first write"
	synced.pressed.connect(func(): new_synced_save_requested.emit())
	row.add_child(synced)


func _has_id(saves: Array, id: String) -> bool:
	for s: Variant in saves:
		if str((s as Dictionary).get("save_id", "")) == id:
			return true
	return false


func _add_row(text: String, save_id: String, is_current: bool,
			  sync_state: String = "", romm_available: bool = false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	if selectable:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(0, 52)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 18)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.text = ("●  " if is_current else "    ") + text
		if is_current:
			btn.add_theme_color_override("font_color", COLOR_CURRENT)
		btn.pressed.connect(func(): save_selected.emit(save_id))
		row.add_child(btn)
	else:
		# A label, not a disabled button: nothing here is waiting to be pressed,
		# and the sync toggle beside it still is.
		var lbl := Label.new()
		lbl.custom_minimum_size = Vector2(0, 52)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", COLOR_ROW)
		lbl.text = "    " + text
		row.add_child(lbl)

	# "New blank save" has no file yet, so nothing to sync until it exists.
	if save_id.is_empty() or not romm_available:
		return

	var toggle := Button.new()
	toggle.custom_minimum_size = Vector2(64, 52)
	toggle.add_theme_font_override("font", _symbols())
	toggle.add_theme_font_size_override("font_size", 22)
	match sync_state:
		"on":
			toggle.text = String.chr(_ICON_SYNC_ON)
			toggle.add_theme_color_override("font_color", COLOR_SYNC)
			toggle.tooltip_text = "Synced with RomM — press to stop"
		"busy":
			toggle.text = String.chr(_ICON_BUSY)
			toggle.add_theme_color_override("font_color", COLOR_WARN)
			toggle.tooltip_text = "Syncing…"
		"conflict":
			toggle.text = String.chr(_ICON_WARN)
			toggle.add_theme_color_override("font_color", COLOR_WARN)
			toggle.tooltip_text = "Both copies changed — the server's was kept as a separate save"
		_:
			toggle.text = String.chr(_ICON_SYNC_OFF)
			toggle.add_theme_color_override("font_color", COLOR_MUTED)
			toggle.tooltip_text = "Not synced — press to keep this save on RomM"
	var want_on := sync_state != "on"
	toggle.pressed.connect(func(): sync_toggled.emit(save_id, want_on))
	row.add_child(toggle)


## A save that exists only on the server. Pressing it downloads a copy and
## binds this cartridge to it.
func _add_server_row(e: Dictionary) -> void:
	var slot := str(e.get("slot", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_rows_box.add_child(row)

	var when := str(e.get("updated_at", "")).replace("T", "  ").left(19)
	var lbl := Button.new()
	lbl.custom_minimum_size = Vector2(0, 52)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.alignment = HORIZONTAL_ALIGNMENT_LEFT
	lbl.add_theme_color_override("font_color", COLOR_ROW)
	lbl.text = "    %s    %s    %.1f KB" % [slot.left(8), when, int(e.get("size", 0)) / 1024.0]
	lbl.pressed.connect(func(): server_save_requested.emit(slot))
	row.add_child(lbl)

	var get_btn := Button.new()
	get_btn.custom_minimum_size = Vector2(64, 52)
	get_btn.add_theme_font_override("font", _symbols())
	get_btn.add_theme_font_size_override("font_size", 22)
	get_btn.text = String.chr(_ICON_CLOUD)
	get_btn.add_theme_color_override("font_color", COLOR_SYNC)
	get_btn.tooltip_text = "Download this save and bind the cartridge to it"
	get_btn.pressed.connect(func(): server_save_requested.emit(slot))
	row.add_child(get_btn)


## Fill the Achievements ribbon.
##   entries : RA.achievements() rows, already in bucket order (locked first)
##   summary : RA.game_info(), or {} when this cartridge is not the live session
##   state   : a sentence for the empty case — why there is nothing to show
func populate_achievements(entries: Array, summary: Dictionary, state: String) -> void:
	for child in _ach_box.get_children():
		child.queue_free()

	if entries.is_empty():
		_ach_summary.text = state
		return

	# Counted from the rows actually listed, not from get_user_game_summary. That
	# summary covers the primary set only, while the list includes bonus subsets —
	# Super Mario Bros. reports 76 there and returns 111 here, and a header that
	# disagrees with the list beneath it reads as a bug whichever number is right.
	var num_unlocked := 0
	var points_total := 0
	var points_unlocked := 0
	for e: Variant in entries:
		var row: Dictionary = e
		var pts := int(row.get("points", 0))
		points_total += pts
		if bool(row.get("unlocked", false)):
			num_unlocked += 1
			points_unlocked += pts

	_ach_summary.text = "%s — %d of %d unlocked, %d of %d points" % [
		str(summary.get("title", "")),
		num_unlocked, entries.size(), points_unlocked, points_total,
	]

	for entry_variant: Variant in entries:
		var entry: Dictionary = entry_variant
		var unlocked := bool(entry.get("unlocked", false))

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.custom_minimum_size = Vector2(0, 52)
		_ach_box.add_child(row)

		# The badge arrives late — RA caches it to disk on first sight, so the row
		# is built without one and filled in when the fetch lands.
		var icon := TextureRect.new()
		icon.custom_minimum_size = Vector2(44, 44)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		var url := str(entry.get("badge_url" if unlocked else "badge_locked_url", ""))
		RA.fetch_badge(url, func(badge: Texture2D) -> void:
			if is_instance_valid(icon) and badge != null:
				icon.texture = badge)

		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 0)
		row.add_child(text)

		var title := Label.new()
		title.text = str(entry.get("title", ""))
		title.add_theme_font_size_override("font_size", 17)
		title.add_theme_color_override("font_color",
			COLOR_CURRENT if unlocked else COLOR_ROW)
		text.add_child(title)

		var desc := Label.new()
		desc.text = str(entry.get("description", ""))
		desc.add_theme_font_size_override("font_size", 13)
		desc.add_theme_color_override("font_color", COLOR_MUTED)
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.add_child(desc)

		# Progress towards a measured achievement ("12/40"), when there is any.
		var measured := str(entry.get("measured_progress", ""))
		if not unlocked and not measured.is_empty():
			var progress := Label.new()
			progress.text = measured
			progress.add_theme_font_size_override("font_size", 13)
			progress.add_theme_color_override("font_color", COLOR_SYNC)
			text.add_child(progress)

		var points := Label.new()
		points.text = "%d" % int(entry.get("points", 0))
		points.add_theme_font_size_override("font_size", 17)
		points.add_theme_color_override("font_color",
			COLOR_CURRENT if unlocked else COLOR_MUTED)
		points.custom_minimum_size = Vector2(40, 0)
		points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		points.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(points)


## Drive the active scroll container from an external stick input.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
