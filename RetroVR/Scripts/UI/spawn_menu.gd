## SpawnMenu2D — 2D Control rendered inside a SubViewport on the VR spawn panel.
## Builds its own UI programmatically so no extra tscn layout work is needed.
## Emits spawn_requested(type) when a spawn button is pressed,
## and close_requested when the ✕ button is pressed.
class_name SpawnMenu2D
extends Control

signal spawn_requested(type: String)
signal close_requested
## Emitted when the user changes a default core in the Manager tab.
signal default_core_changed(systemid: String, core_name: String)
## Emitted when the user clicks a ROM in the Cartridges tab.
signal spawn_cartridge_requested(rom_path: String, game_label: String)

## Shared core info database — populated on _ready, used by Download & Manager tabs.
var core_db: CoreInfoDatabase = null

## Download manager — added as a child so HTTPRequest nodes work correctly.
var download_manager: CoreDownloadManager = null

## Core defaults persistence (core_defaults.json).
var core_defaults: CoreDefaults = null

# ── UI state ──────────────────────────────────────────────────────────────────
var _spawn_view:    Control = null
var _cores_view:    Control = null
var _nav_spawn_btn: Button  = null
var _nav_cores_btn: Button  = null

# Cores > Download tab state
var _download_list_vbox:    VBoxContainer = null
var _download_loading_label: Label        = null
var _download_fetched:       bool         = false
# core_name -> { "button": Button, "bar": ProgressBar }
var _download_widgets: Dictionary = {}

# The ScrollContainer currently in view (nil when spawn view active)
var _active_scroll:        ScrollContainer = null
var _download_list_scroll: ScrollContainer = null

# Custom scroll indicator (replaces native scrollbar)
var _vscrollbar: VScrollBar = null

# Cores > Manager tab state
var _manager_list_vbox:   VBoxContainer = null
var _manager_empty_label: Label         = null

# Spawn > Systems tab — rebuilt whenever defaults change
var _systems_vbox: VBoxContainer = null
# Spawn > Cartridges tab — rebuilt whenever defaults change or tab opened
var _cartridges_vbox: VBoxContainer = null


# ── Palette ───────────────────────────────────────────────────────────────────
const COLOR_BG           := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_NAV_ACTIVE   := Color(0.25, 0.25, 0.55)
const COLOR_NAV_INACTIVE := Color(0.12, 0.12, 0.25)
const COLOR_TITLE        := Color(0.9,  0.9,  1.0)
const COLOR_LICENSE      := Color(0.65, 0.65, 0.80)
const COLOR_DESC         := Color(0.55, 0.55, 0.68)
const COLOR_BTN_DL       := Color(0.15, 0.45, 0.15)
const COLOR_BTN_UPD      := Color(0.45, 0.30, 0.10)
const COLOR_BTN_REUP     := Color(0.18, 0.18, 0.35)
const COLOR_BTN_BUSY     := Color(0.25, 0.20, 0.10)


func _ready() -> void:
	_init_core_db()
	_init_core_defaults()
	_init_download_manager()
	# Always ensure the roms root exists, plus dirs for any already-configured systems
	print("[SpawnMenu] USERPROFILE=", OS.get_environment("USERPROFILE"))
	print("[SpawnMenu] roms root=", RomLibrary.default_roms_root())
	RomLibrary.ensure_roms_root()
	for sid: String in core_defaults.all_defaults():
		RomLibrary.ensure_rom_dir(sid)
	_build_ui()


func _init_core_db() -> void:
	core_db = CoreInfoDatabase.new()
	core_db.load_from_project()


func _init_core_defaults() -> void:
	core_defaults = CoreDefaults.new()
	core_defaults.setup(CoreDefaults.default_path())


func _init_download_manager() -> void:
	download_manager = CoreDownloadManager.new()
	download_manager.name = "CoreDownloadManager"
	add_child(download_manager)


# ── Top-level UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	anchor_right  = 1.0
	anchor_bottom = 1.0

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = COLOR_BG
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 10)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	panel.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 8)
	margin.add_child(root_vbox)

	# Title row
	var title_row := HBoxContainer.new()
	root_vbox.add_child(title_row)
	var title := Label.new()
	title.text = "RETROVR MENU"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close_btn := Button.new()
	close_btn.text = "  ✕  "
	close_btn.add_theme_font_size_override("font_size", 24)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)

	root_vbox.add_child(HSeparator.new())

	# Top nav bar
	var nav_bar := HBoxContainer.new()
	nav_bar.add_theme_constant_override("separation", 6)
	root_vbox.add_child(nav_bar)
	_nav_spawn_btn = _make_nav_button("  SPAWN  ")
	_nav_cores_btn = _make_nav_button("  CORES  ")
	_nav_spawn_btn.pressed.connect(_show_spawn_view)
	_nav_cores_btn.pressed.connect(_show_cores_view)
	nav_bar.add_child(_nav_spawn_btn)
	nav_bar.add_child(_nav_cores_btn)

	root_vbox.add_child(HSeparator.new())

	# Content area — holds spawn_view and cores_view, only one visible at a time
	var content := Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(content)

	_spawn_view = _build_spawn_view()
	_spawn_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_spawn_view)

	_cores_view = _build_cores_view()
	_cores_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_cores_view)

	_show_spawn_view()


func _make_nav_button(lbl: String) -> Button:
	var btn := Button.new()
	btn.text = lbl
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _show_spawn_view() -> void:
	_spawn_view.visible = true
	_cores_view.visible = false
	_active_scroll = null
	_set_nav_active(_nav_spawn_btn, _nav_cores_btn)


func _show_cores_view() -> void:
	_spawn_view.visible = false
	_cores_view.visible = true
	_active_scroll = _download_list_scroll
	_set_nav_active(_nav_cores_btn, _nav_spawn_btn)
	if not _download_fetched:
		_download_fetched = true
		_start_fetch()


func _set_nav_active(active: Button, inactive: Button) -> void:
	for btn: Button in [active, inactive]:
		var is_active := (btn == active)
		var s := StyleBoxFlat.new()
		s.bg_color = COLOR_NAV_ACTIVE if is_active else COLOR_NAV_INACTIVE
		for k in ["corner_radius_top_left","corner_radius_top_right",
				  "corner_radius_bottom_left","corner_radius_bottom_right"]:
			s.set(k, 6)
		for state in ["normal", "hover", "pressed"]:
			btn.add_theme_stylebox_override(state, s)


## Called by SpawnMenuController each frame while trigger is held.
## pixels > 0 scrolls down, < 0 scrolls up.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)


# ── Spawn view ────────────────────────────────────────────────────────────────

func _build_spawn_view() -> Control:
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Systems tab — dynamic, driven by CoreDefaults
	var systems_scroll := ScrollContainer.new()
	systems_scroll.name = "Systems"
	tabs.add_child(systems_scroll)
	_systems_vbox = VBoxContainer.new()
	_systems_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_systems_vbox.add_theme_constant_override("separation", 14)
	systems_scroll.add_child(_systems_vbox)
	_populate_systems_tab()

	# Rebuild systems/cartridges lists whenever the user sets/changes a default
	default_core_changed.connect(func(_sid: String, _cn: String): _populate_systems_tab())
	default_core_changed.connect(func(_sid: String, _cn: String): _populate_cartridges_tab())

	_add_spawn_tab(tabs, "TVs", [["TV", "tv"]])

	# Cartridges tab — dynamic, one ribbon per system with default core set
	var carts_scroll := ScrollContainer.new()
	carts_scroll.name = "Cartridges"
	tabs.add_child(carts_scroll)
	_cartridges_vbox = VBoxContainer.new()
	_cartridges_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cartridges_vbox.add_theme_constant_override("separation", 10)
	carts_scroll.add_child(_cartridges_vbox)
	_populate_cartridges_tab()

	# Refresh on tab switch — picks up files added to disk since last open
	tabs.tab_changed.connect(func(idx: int):
		if idx == 2:
			_populate_cartridges_tab()
	)

	return tabs


func _populate_systems_tab() -> void:
	if not _systems_vbox:
		return
	for child in _systems_vbox.get_children():
		child.queue_free()
	_systems_vbox.add_child(_spacer(10))
	var defaults := core_defaults.all_defaults()
	if defaults.is_empty():
		var lbl := Label.new()
		lbl.text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_systems_vbox.add_child(lbl)
		return
	for systemid: String in defaults:
		var display_name := systemid
		var entries := core_db.get_by_systemid(systemid)
		if not entries.is_empty():
			var e: Dictionary = entries[0]
			if e.has("systemname"):
				display_name = e["systemname"]
		var btn := Button.new()
		btn.text = "  +  " + display_name
		btn.custom_minimum_size = Vector2(0, 80)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(spawn_requested.emit.bind(systemid))
		_systems_vbox.add_child(btn)


func _populate_cartridges_tab() -> void:
	if not _cartridges_vbox:
		return
	for child in _cartridges_vbox.get_children():
		child.queue_free()
	_cartridges_vbox.add_child(_spacer(10))
	var defaults := core_defaults.all_defaults()
	if defaults.is_empty():
		var lbl := Label.new()
		lbl.text = "No default cores set.\nGo to Cores \u25b8 Manager to configure systems."
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_cartridges_vbox.add_child(lbl)
		return
	for systemid: String in defaults:
		RomLibrary.ensure_rom_dir(systemid)
		# Collect all supported extensions for this system across all its cores
		var exts: Array[String] = []
		for entry: Dictionary in core_db.get_by_systemid(systemid):
			for ext: String in entry.get("supported_extensions", "").split("|"):
				var e := ext.strip_edges().to_lower()
				if not e.is_empty() and e not in exts:
					exts.append(e)
		# System ribbon header
		var system_name := core_db.get_systemname_for_id(systemid)
		var hdr := Label.new()
		hdr.text = system_name
		hdr.add_theme_font_size_override("font_size", 22)
		hdr.add_theme_color_override("font_color", COLOR_TITLE)
		_cartridges_vbox.add_child(hdr)
		_cartridges_vbox.add_child(HSeparator.new())
		# ROM list
		var roms := RomLibrary.scan_roms(systemid, exts)
		if roms.is_empty():
			var hint := Label.new()
			hint.text = "Add ROMs to roms/%s/ to see them here." % systemid
			hint.add_theme_font_size_override("font_size", 18)
			hint.add_theme_color_override("font_color", COLOR_DESC)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_cartridges_vbox.add_child(hint)
		else:
			for rom: Dictionary in roms:
				var btn := Button.new()
				btn.text = "  +  " + rom["label"]
				btn.custom_minimum_size = Vector2(0, 72)
				btn.add_theme_font_size_override("font_size", 22)
				btn.pressed.connect(spawn_cartridge_requested.emit.bind(rom["path"], rom["label"]))
				_cartridges_vbox.add_child(btn)
		_cartridges_vbox.add_child(_spacer(8))


func _add_spawn_tab(tabs: TabContainer, tab_title: String, items: Array) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	tabs.add_child(scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)
	vbox.add_child(_spacer(10))
	for item: Array in items:
		var btn := Button.new()
		btn.text = "  +  " + item[0]
		btn.custom_minimum_size = Vector2(0, 80)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(spawn_requested.emit.bind(item[1]))
		vbox.add_child(btn)


# ── Cores view ────────────────────────────────────────────────────────────────

func _build_cores_view() -> Control:
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var dl_container := _build_download_tab()
	dl_container.name = "Download"
	tabs.add_child(dl_container)

	var mgr_container := _build_manager_tab()
	mgr_container.name = "Manager"
	tabs.add_child(mgr_container)

	# Refresh Manager list each time the user switches to it
	tabs.tab_changed.connect(func(idx: int):
		if idx == 1:
			_populate_manager_tab()
	)

	return tabs


# ── Manager tab ───────────────────────────────────────────────────────────────────

func _build_manager_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	var hdr := Label.new()
	hdr.text = "Set the default core for each system that has downloaded cores."
	hdr.add_theme_font_size_override("font_size", 15)
	hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(hdr)

	outer.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical  = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	scroll.add_theme_constant_override("scrollbar_v_width", 40)
	outer.add_child(scroll)

	_manager_list_vbox = VBoxContainer.new()
	_manager_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_manager_list_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(_manager_list_vbox)

	_manager_empty_label = Label.new()
	_manager_empty_label.text = "No cores downloaded yet.\nUse the Download tab to install cores."
	_manager_empty_label.add_theme_font_size_override("font_size", 18)
	_manager_empty_label.add_theme_color_override("font_color", COLOR_LICENSE)
	_manager_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_manager_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_manager_list_vbox.add_child(_manager_empty_label)

	return outer


func _populate_manager_tab() -> void:
	if not _manager_list_vbox:
		return
	for c in _manager_list_vbox.get_children():
		c.queue_free()

	# Scan cores dir for installed DLLs
	var cores_dir := CoreDownloadManager.default_cores_dir()
	var dir := DirAccess.open(cores_dir)
	if not dir:
		_manager_list_vbox.add_child(_manager_empty_label)
		return

	var core_names: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with("_libretro.dll"):
			core_names.append(fname.trim_suffix("_libretro.dll"))
		fname = dir.get_next()
	dir.list_dir_end()

	if core_names.is_empty():
		_manager_list_vbox.add_child(_manager_empty_label)
		return

	# Group by systemid
	# systemid -> Array[{core_name, display_name}]
	var by_system: Dictionary = {}
	var system_labels: Dictionary = {}   # systemid -> human label

	for cn: String in core_names:
		var info: Dictionary = core_db.get_by_core_name(cn)
		var sid: String  = info.get("systemid",   "unknown") if not info.is_empty() else "unknown"
		var sname: String = info.get("systemname", cn)       if not info.is_empty() else cn
		if not by_system.has(sid):
			by_system[sid]      = []
			system_labels[sid]  = sname
		(by_system[sid] as Array).append({"core_name": cn,
			"display_name": info.get("corename", cn) if not info.is_empty() else cn})

	# Sort systems alphabetically by label
	var sids: Array = by_system.keys()
	sids.sort_custom(func(a: String, b: String) -> bool:
		return (system_labels[a] as String) < (system_labels[b] as String)
	)

	for sid: String in sids:
		var cores_list: Array = by_system[sid] as Array
		_manager_list_vbox.add_child(
			_build_manager_row(sid, system_labels[sid] as String, cores_list)
		)
		_manager_list_vbox.add_child(HSeparator.new())


## Builds one row: systemname label + OptionButton of available cores.
func _build_manager_row(systemid: String, systemname: String, cores: Array) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 68)

	var lbl := Label.new()
	lbl.text = systemname
	lbl.add_theme_font_size_override("font_size", 19)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(260, 56)
	opt.add_theme_font_size_override("font_size", 17)

	var current_default: String = core_defaults.get_default_core(systemid)
	var selected_idx := 0
	for i: int in cores.size():
		var entry: Dictionary = cores[i] as Dictionary
		opt.add_item(entry["display_name"] as String, i)
		if entry["core_name"] == current_default:
			selected_idx = i

	opt.selected = selected_idx
	# If no default was saved yet, persist the auto-selected first entry
	if current_default.is_empty() and not cores.is_empty():
		var auto_cn: String = (cores[0] as Dictionary)["core_name"] as String
		core_defaults.set_default_core(systemid, auto_cn)
		core_defaults.save()
		RomLibrary.ensure_rom_dir(systemid)
		default_core_changed.emit(systemid, auto_cn)

	opt.item_selected.connect(func(idx: int) -> void:
		var cn: String = (cores[idx] as Dictionary)["core_name"] as String
		core_defaults.set_default_core(systemid, cn)
		core_defaults.save()
		RomLibrary.ensure_rom_dir(systemid)
		default_core_changed.emit(systemid, cn)
	)
	row.add_child(opt)

	return row


# ── Download tab ──────────────────────────────────────────────────────────────

func _build_download_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	# Cores directory path display
	var path_row := HBoxContainer.new()
	outer.add_child(path_row)
	var path_prefix := Label.new()
	path_prefix.text = "Cores dir:  "
	path_prefix.add_theme_font_size_override("font_size", 14)
	path_prefix.add_theme_color_override("font_color", COLOR_LICENSE)
	path_row.add_child(path_prefix)
	var path_val := Label.new()
	path_val.text = CoreDownloadManager.default_cores_dir()
	path_val.add_theme_font_size_override("font_size", 14)
	path_val.add_theme_color_override("font_color", COLOR_DESC)
	path_val.clip_contents = true
	path_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(path_val)

	outer.add_child(HSeparator.new())

	# Loading indicator
	_download_loading_label = Label.new()
	_download_loading_label.text = "Fetching core list from buildbot..."
	_download_loading_label.add_theme_font_size_override("font_size", 18)
	_download_loading_label.add_theme_color_override("font_color", COLOR_LICENSE)
	_download_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(_download_loading_label)

	# Scrollable core list — native scrollbar made wide for VR pointer
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_download_list_scroll = scroll
	outer.add_child(scroll)

	_download_list_vbox = VBoxContainer.new()
	_download_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_download_list_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_download_list_vbox)

	# Make the native scroll bar wide enough to grab with a VR pointer,
	# using the theme constant so ScrollContainer properly reserves the space.
	scroll.add_theme_constant_override("scrollbar_v_width", 40)

	return outer


func _start_fetch() -> void:
	_download_loading_label.text = "Fetching core list from buildbot..."
	_download_loading_label.visible = true
	for child in _download_list_vbox.get_children():
		child.queue_free()
	_download_widgets.clear()
	download_manager.fetch_available_cores(_on_cores_fetched)


func _on_cores_fetched(cores: Array) -> void:
	_download_loading_label.visible = false
	if cores.is_empty():
		_download_loading_label.text = "Failed to fetch core list. Check your connection."
		_download_loading_label.visible = true
		return
	for entry: Dictionary in cores:
		var core_name: String  = entry["core_name"]
		var remote_date: String = entry["remote_date"]
		var info: Dictionary   = core_db.get_by_core_name(core_name)
		_download_list_vbox.add_child(_build_core_entry(core_name, remote_date, info))
	_download_list_vbox.add_child(_spacer(20))


func _build_core_entry(core_name: String, remote_date: String, info: Dictionary) -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 0)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 76)
	wrap.add_child(row)

	# Left: display name, license, description
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 2)
	row.add_child(left)

	var display_name: String = info.get("display_name", core_name + "  [CORE UNKNOWN]")
	var name_lbl := Label.new()
	name_lbl.text = display_name
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	name_lbl.clip_contents = true
	left.add_child(name_lbl)

	if not info.is_empty():
		var lic_lbl := Label.new()
		lic_lbl.text = info.get("license", "")
		lic_lbl.add_theme_font_size_override("font_size", 13)
		lic_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		left.add_child(lic_lbl)

		var desc: String = info.get("description", "")
		if desc != "":
			var desc_lbl := Label.new()
			desc_lbl.text = desc
			desc_lbl.add_theme_font_size_override("font_size", 12)
			desc_lbl.add_theme_color_override("font_color", COLOR_DESC)
			desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			desc_lbl.max_lines_visible = 2
			left.add_child(desc_lbl)

	# Right: action button + progress bar
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(148, 0)
	right.add_theme_constant_override("separation", 4)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(right)

	var state: String = download_manager.get_core_state(core_name, remote_date)
	var dl_btn := Button.new()
	dl_btn.text = state
	dl_btn.custom_minimum_size = Vector2(140, 46)
	dl_btn.add_theme_font_size_override("font_size", 16)
	_style_dl_button(dl_btn, state)
	dl_btn.pressed.connect(_on_download_pressed.bind(core_name, remote_date))
	right.add_child(dl_btn)

	var prog_bar := ProgressBar.new()
	prog_bar.custom_minimum_size = Vector2(140, 12)
	prog_bar.min_value = 0.0
	prog_bar.max_value = 1.0
	prog_bar.value    = 0.0
	prog_bar.visible  = false
	right.add_child(prog_bar)

	_download_widgets[core_name] = {"button": dl_btn, "bar": prog_bar}

	wrap.add_child(HSeparator.new())
	return wrap


func _style_dl_button(btn: Button, state: String) -> void:
	var color: Color
	match state:
		"Download":    color = COLOR_BTN_DL
		"UPDATE":      color = COLOR_BTN_UPD
		"Re-Download": color = COLOR_BTN_REUP
		_:             color = COLOR_BTN_BUSY   # BUSY or unknown
	var s := StyleBoxFlat.new()
	s.bg_color = color
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		s.set(k, 5)
	for state_key in ["normal", "hover", "pressed"]:
		btn.add_theme_stylebox_override(state_key, s)
	btn.disabled = (state == "BUSY")


func _on_download_pressed(core_name: String, remote_date: String) -> void:
	var widgets: Dictionary = _download_widgets.get(core_name, {})
	if widgets.is_empty():
		return
	var btn: Button      = widgets["button"]
	var bar: ProgressBar = widgets["bar"]

	btn.text = "BUSY"
	_style_dl_button(btn, "BUSY")
	bar.value   = 0.0
	bar.visible = true

	download_manager.download_core(
		core_name,
		remote_date,
		func(fraction: float): bar.value = fraction,
		func(success: bool, err_msg: String):
			bar.visible = false
			var new_state := "Re-Download" if success else "Download"
			if not success:
				push_warning("CoreDownload '%s' failed: %s" % [core_name, err_msg])
			else:
				call_deferred("_populate_manager_tab")
				var dl_entry := core_db.get_by_core_name(core_name)
				var dl_sid: String = dl_entry.get("systemid", "")
				if not dl_sid.is_empty():
					RomLibrary.ensure_rom_dir(dl_sid)
				call_deferred("_populate_cartridges_tab")
			btn.text = new_state
			_style_dl_button(btn, new_state)
	)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _sync_vscrollbar() -> void:
	pass # no longer used


func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
