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
## Emitted when the user clicks the manual (📖) button for a ROM.
signal spawn_manual_requested(pdf_path: String)
## Emitted when the user changes the turn style. value is "SNAP" or "SMOOTH".
signal turn_style_changed(value: String)

## Shared core info database — populated on _ready, used by Download & Manager tabs.
var core_db: CoreInfoDatabase = null

## Download manager — added as a child so HTTPRequest nodes work correctly.
var download_manager: CoreDownloadManager = null

## Core defaults persistence (core_defaults.json).
var core_defaults: CoreDefaults = null

## Scraper infrastructure
var gamelist_manager: GamelistManager = null
var scraper_client: ScreenscraperClient = null
var scraper_config: ScraperConfig = null

## Web file server (HTTP file manager accessible from a PC browser).
var web_server: WebFileServer = null
var _server_address_label: Label = null

# ── UI state ──────────────────────────────────────────────────────────────────
var _spawn_view:    Control = null
var _cores_view:    Control = null
var _options_view:  Control = null
var _nav_spawn_btn:   Button = null
var _nav_cores_btn:   Button = null
var _nav_options_btn: Button = null
var _nav_buttons: Array[Button] = []

# Cores > Download tab state
var _download_list_vbox:    VBoxContainer = null
var _download_loading_label: Label        = null
var _download_fetched:       bool         = false
# core_name -> { "button": Button, "bar": ProgressBar }
var _download_widgets: Dictionary = {}

# The ScrollContainer currently in view
var _active_scroll:        ScrollContainer = null
var _download_list_scroll: ScrollContainer = null
var _options_scroll:       ScrollContainer = null

# Spawn view tab ScrollContainers (indexed by tab index)
var _spawn_tab_scrolls: Array[ScrollContainer] = []
var _spawn_tabs: TabContainer = null

# Custom scroll indicator (replaces native scrollbar)
var _vscrollbar: VScrollBar = null

# Cores > Manager tab state
var _manager_list_vbox:   VBoxContainer = null
var _manager_empty_label: Label         = null

# Spawn > Systems tab — rebuilt whenever defaults change
var _systems_vbox: VBoxContainer = null
# Spawn > Cartridges tab — rebuilt whenever defaults change or tab opened
var _cartridges_vbox: VBoxContainer = null

# Scrape popup overlay
var _scrape_popup: PanelContainer = null
var _scrape_in_progress: bool = false
# Game detail side panel
var _game_detail_panel: PanelContainer = null
# ROM variants side panel
var _rom_variants_panel: PanelContainer = null
# Callback connected to scraper_client.media_download_completed so the tab
# refreshes when a wheel image or manual PDF finishes downloading.
var _media_dl_refresh_cb: Callable = Callable()


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
	_init_scraper()
	_init_web_server()
	# Always ensure the roms root exists, plus dirs for any already-configured systems
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


func _init_scraper() -> void:
	scraper_config = ScraperConfig.new()
	scraper_config.load_config()
	gamelist_manager = GamelistManager.new()
	scraper_client = ScreenscraperClient.new()
	scraper_client.name = "ScreenscraperClient"
	scraper_client.config = scraper_config
	add_child(scraper_client)


func _init_web_server() -> void:
	if OS.get_name() != "Android":
		return
	web_server = WebFileServer.new()
	web_server.name = "WebFileServer"
	add_child(web_server)
	if scraper_config.web_server_enabled:
		web_server.start()


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
	_nav_spawn_btn   = _make_nav_button("  SPAWN  ")
	_nav_cores_btn   = _make_nav_button("  CORES  ")
	_nav_options_btn = _make_nav_button(" OPTIONS ")
	_nav_spawn_btn.pressed.connect(_show_spawn_view)
	_nav_cores_btn.pressed.connect(_show_cores_view)
	_nav_options_btn.pressed.connect(_show_options_view)
	nav_bar.add_child(_nav_spawn_btn)
	nav_bar.add_child(_nav_cores_btn)
	nav_bar.add_child(_nav_options_btn)
	_nav_buttons = [_nav_spawn_btn, _nav_cores_btn, _nav_options_btn]

	root_vbox.add_child(HSeparator.new())

	# Content area — holds spawn_view, cores_view, and options_view
	var content := Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(content)

	_spawn_view = _build_spawn_view()
	_spawn_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_spawn_view)

	_cores_view = _build_cores_view()
	_cores_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_cores_view)

	_options_view = _build_options_view()
	_options_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_options_view)

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
	_options_view.visible = false
	_update_spawn_active_scroll(_spawn_tabs.current_tab if _spawn_tabs else 0)
	_set_nav_active(_nav_spawn_btn)


func _show_cores_view() -> void:
	_spawn_view.visible = false
	_cores_view.visible = true
	_options_view.visible = false
	_active_scroll = _download_list_scroll
	_set_nav_active(_nav_cores_btn)
	if not _download_fetched:
		_download_fetched = true
		_start_fetch()


func _show_options_view() -> void:
	_spawn_view.visible = false
	_cores_view.visible = false
	_options_view.visible = true
	_active_scroll = _options_scroll
	_set_nav_active(_nav_options_btn)


func _update_spawn_active_scroll(tab_idx: int) -> void:
	if tab_idx >= 0 and tab_idx < _spawn_tab_scrolls.size():
		_active_scroll = _spawn_tab_scrolls[tab_idx]
	else:
		_active_scroll = null


func _set_nav_active(active: Button) -> void:
	for btn: Button in _nav_buttons:
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
	_spawn_tabs = tabs
	_spawn_tab_scrolls.clear()

	# Systems tab — dynamic, driven by CoreDefaults
	var systems_scroll := ScrollContainer.new()
	systems_scroll.name = "Systems"
	tabs.add_child(systems_scroll)
	_spawn_tab_scrolls.append(systems_scroll)
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
	_spawn_tab_scrolls.append(carts_scroll)
	_cartridges_vbox = VBoxContainer.new()
	_cartridges_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cartridges_vbox.add_theme_constant_override("separation", 10)
	carts_scroll.add_child(_cartridges_vbox)
	_populate_cartridges_tab()

	# Refresh on tab switch — picks up files added to disk since last open
	# Also update _active_scroll to the current tab's ScrollContainer
	tabs.tab_changed.connect(func(idx: int):
		if idx == 2:
			_populate_cartridges_tab()
		_update_spawn_active_scroll(idx)
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
			hint.text = "Add ROMs to %s/ to see them here." % RomLibrary.rom_dir_for_system(systemid)
			hint.add_theme_font_size_override("font_size", 18)
			hint.add_theme_color_override("font_color", COLOR_DESC)
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_cartridges_vbox.add_child(hint)
		else:
			# Track which games we've already shown (by game_id)
			var shown_games: Dictionary = {}

			for rom: Dictionary in roms:
				var rom_path: String = rom["path"]
				var game := gamelist_manager.get_game_for_rom(systemid, rom_path)
				var is_scraped := not game.is_empty()

				# If scraped and multi-ROM game, only show once (via preferred ROM)
				if is_scraped:
					var gid: String = game.get("game_id", "")
					if shown_games.has(gid):
						continue
					shown_games[gid] = true

				var row := HBoxContainer.new()
				row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

				# Spawn button — show wheel image if scraped, otherwise text
				var btn := Button.new()
				btn.custom_minimum_size = Vector2(0, 72)
				btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				btn.add_theme_font_size_override("font_size", 22)

				var pref_rom: Dictionary = GamelistManager.get_preferred_rom(game) if is_scraped else {}

				if is_scraped:
					var spawn_path: String = GamelistManager.to_absolute_path(systemid, pref_rom.get("path", rom["path"]))
					var game_name: String = game.get("name", rom["label"])

					# Try to load wheel image
					var wheel_tex := _load_wheel_texture(systemid, pref_rom.get("romname", ""))
					if wheel_tex:
						btn.icon = wheel_tex
						btn.text = ""
						btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
						btn.expand_icon = true
					else:
						btn.text = "  +  " + game_name

					btn.pressed.connect(spawn_cartridge_requested.emit.bind(spawn_path, game_name))
				else:
					btn.text = "  +  " + rom["label"]
					btn.pressed.connect(spawn_cartridge_requested.emit.bind(rom["path"], rom["label"]))

				row.add_child(btn)

				# Game detail button — only for scraped games
				if is_scraped:
					var detail_btn := Button.new()
					detail_btn.text = "🎮"
					detail_btn.custom_minimum_size = Vector2(72, 72)
					detail_btn.tooltip_text = "Game info"
					detail_btn.add_theme_font_size_override("font_size", 26)
					detail_btn.pressed.connect(_show_game_detail_panel.bind(game, systemid))
					row.add_child(detail_btn)

				# Manual button — check both alongside ROM and scraped media
				var has_man := RomLibrary.has_manual(rom["path"])
				if not has_man and is_scraped:
					has_man = _has_scraped_manual(systemid, pref_rom.get("romname", ""))
				if has_man:
					var manual_btn := Button.new()
					manual_btn.text = "📖"
					manual_btn.custom_minimum_size = Vector2(72, 72)
					manual_btn.tooltip_text = "Spawn manual"
					manual_btn.add_theme_font_size_override("font_size", 26)
					var pdf_path: String
					if RomLibrary.has_manual(rom["path"]):
						pdf_path = RomLibrary.manual_path(rom["path"])
					else:
						pdf_path = _scraped_manual_path(systemid, pref_rom.get("romname", ""))
					manual_btn.pressed.connect(spawn_manual_requested.emit.bind(pdf_path))
					row.add_child(manual_btn)

				# Scrape button
				var scrape_btn := Button.new()
				scrape_btn.text = "✂️"
				scrape_btn.custom_minimum_size = Vector2(72, 72)
				scrape_btn.tooltip_text = "Scrape ROM"
				scrape_btn.add_theme_font_size_override("font_size", 26)
				scrape_btn.pressed.connect(_on_scrape_pressed.bind(rom["path"], systemid, scrape_btn))
				row.add_child(scrape_btn)

				_cartridges_vbox.add_child(row)
		_cartridges_vbox.add_child(_spacer(8))


func _add_spawn_tab(tabs: TabContainer, tab_title: String, items: Array) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	tabs.add_child(scroll)
	_spawn_tab_scrolls.append(scroll)
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

	var lib_suffix := "_libretro_android.so" if OS.get_name() == "Android" else "_libretro.dll"
	var core_names: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(lib_suffix):
			core_names.append(fname.trim_suffix(lib_suffix))
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


# ── Options view ──────────────────────────────────────────────────────────────

func _build_options_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_options_scroll = scroll

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)

	vbox.add_child(_spacer(10))

	# Turn Style option
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(row)

	var lbl := Label.new()
	lbl.text = "Turn Style"
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(220, 56)
	opt.add_theme_font_size_override("font_size", 20)
	opt.add_item("SNAP", 0)
	opt.add_item("SMOOTH", 1)
	opt.selected = 0
	opt.item_selected.connect(func(idx: int) -> void:
		turn_style_changed.emit("SNAP" if idx == 0 else "SMOOTH")
	)
	row.add_child(opt)

	vbox.add_child(HSeparator.new())

	# ── File Server (Android / Quest only) ───────────────────────────────────
	if OS.get_name() == "Android":
		var fs_hdr := Label.new()
		fs_hdr.text = "FILE SERVER"
		fs_hdr.add_theme_font_size_override("font_size", 22)
		fs_hdr.add_theme_color_override("font_color", COLOR_TITLE)
		vbox.add_child(fs_hdr)

		var fs_row := HBoxContainer.new()
		fs_row.add_theme_constant_override("separation", 10)
		fs_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(fs_row)

		var fs_lbl := Label.new()
		fs_lbl.text = "Web File Manager"
		fs_lbl.add_theme_font_size_override("font_size", 20)
		fs_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		fs_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fs_row.add_child(fs_lbl)

		var fs_opt := OptionButton.new()
		fs_opt.custom_minimum_size = Vector2(140, 56)
		fs_opt.add_theme_font_size_override("font_size", 20)
		fs_opt.add_item("OFF", 0)
		fs_opt.add_item("ON", 1)
		fs_opt.selected = 1 if scraper_config.web_server_enabled else 0
		fs_row.add_child(fs_opt)

		_server_address_label = Label.new()
		_server_address_label.add_theme_font_size_override("font_size", 16)
		_server_address_label.add_theme_color_override("font_color", COLOR_DESC)
		_server_address_label.text = "http://%s:8080" % WebFileServer.local_ip()
		_server_address_label.visible = scraper_config.web_server_enabled
		vbox.add_child(_server_address_label)

		fs_opt.item_selected.connect(func(idx: int) -> void:
			var enable := idx == 1
			if enable:
				web_server.start()
			else:
				web_server.stop()
			scraper_config.web_server_enabled = enable
			scraper_config.save_config()
			_server_address_label.visible = enable
		)

		vbox.add_child(HSeparator.new())

	# ── Scraper settings ─────────────────────────────────────────────────────
	var scraper_hdr := Label.new()
	scraper_hdr.text = "SCRAPER"
	scraper_hdr.add_theme_font_size_override("font_size", 22)
	scraper_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(scraper_hdr)

	# User credentials
	_add_options_text_field(vbox, "Username (ssid)", scraper_config.ssid, func(text: String):
		scraper_config.ssid = text
		scraper_config.save_config()
	)
	_add_options_text_field(vbox, "Password", scraper_config.sspassword, func(text: String):
		scraper_config.sspassword = text
		scraper_config.save_config()
	, true)

	# Region priorities
	_add_options_text_field(vbox, "Region Priority", ", ".join(scraper_config.region_priorities), func(text: String):
		var parts: Array[String] = []
		for p in text.split(","):
			var trimmed := p.strip_edges().to_lower()
			if not trimmed.is_empty():
				parts.append(trimmed)
		if not parts.is_empty():
			scraper_config.region_priorities = parts
			scraper_config.save_config()
	)

	# Language priorities
	_add_options_text_field(vbox, "Language Priority", ", ".join(scraper_config.language_priorities), func(text: String):
		var parts: Array[String] = []
		for p in text.split(","):
			var trimmed := p.strip_edges().to_lower()
			if not trimmed.is_empty():
				parts.append(trimmed)
		if not parts.is_empty():
			scraper_config.language_priorities = parts
			scraper_config.save_config()
	)

	vbox.add_child(HSeparator.new())

	return scroll


func _add_options_text_field(parent: VBoxContainer, label_text: String,
							 initial_value: String, on_changed: Callable,
							 secret: bool = false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var edit := LineEdit.new()
	edit.text = initial_value
	edit.custom_minimum_size = Vector2(260, 48)
	edit.add_theme_font_size_override("font_size", 16)
	edit.secret = secret
	edit.text_submitted.connect(func(text: String): on_changed.call(text))
	edit.focus_exited.connect(func(): on_changed.call(edit.text))
	row.add_child(edit)


# ── Scraper ──────────────────────────────────────────────────────────────────

func _on_scrape_pressed(rom_path: String, systemid: String, btn: Button) -> void:
	if _scrape_in_progress:
		print("[SpawnMenu] Scrape already in progress, ignoring request for: %s" % rom_path.get_file())
		return
	_scrape_in_progress = true
	btn.text = "⏳"
	btn.disabled = true

	# Compute checksums on a background thread to avoid UI freeze.
	# Thread.wait_to_finish() returns the callable's return value directly,
	# avoiding the WorkerThreadPool lambda-environment copy issue where
	# variable reassignment inside add_task() doesn't propagate back.
	var thread := Thread.new()
	thread.start(func() -> Dictionary: return RomHasher.compute_checksums(rom_path))
	while thread.is_alive():
		await get_tree().process_frame
	var checksums: Dictionary = thread.wait_to_finish()
	print("[SpawnMenu] Checksums done: ", checksums)

	if checksums.is_empty():
		_scrape_in_progress = false
		btn.text = "✂️"
		btn.disabled = false
		push_warning("[SpawnMenu] Failed to compute checksums for: %s" % rom_path)
		return

	# Connect one-shot signals for this scrape
	var completed_cb: Callable
	var failed_cb: Callable

	completed_cb = func(result: Dictionary):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = "✂️"
			btn.disabled = false
		print("[SpawnMenu] Scrape completed for: %s" % rom_path.get_file())
		_show_scrape_popup(rom_path, systemid, result)

	failed_cb = func(error: String):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = "✂️"
			btn.disabled = false
		push_warning("[SpawnMenu] Scrape failed: %s" % error)
		_show_scrape_error_popup(error)

	scraper_client.scrape_completed.connect(completed_cb)
	scraper_client.scrape_failed.connect(failed_cb)
	scraper_client.scrape_rom(rom_path, systemid, checksums)


func _show_scrape_popup(rom_path: String, systemid: String, result: Dictionary) -> void:
	_close_scrape_popup()

	_scrape_popup = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.2, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_popup.add_theme_stylebox_override("panel", bg)
	_scrape_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_scrape_popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "SCRAPE RESULT"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# Metadata
	_add_scrape_info_row(vbox, "Game", result.get("name", "Unknown"))
	_add_scrape_info_row(vbox, "Developer", result.get("developer", ""))
	_add_scrape_info_row(vbox, "Publisher", result.get("publisher", ""))
	_add_scrape_info_row(vbox, "Genre", result.get("genre", ""))
	_add_scrape_info_row(vbox, "Region", result.get("rom_region", ""))
	_add_scrape_info_row(vbox, "Release", result.get("releasedate", ""))

	vbox.add_child(HSeparator.new())

	# Media availability
	var media: Dictionary = result.get("media", {})
	var media_lbl := Label.new()
	media_lbl.text = "MEDIA"
	media_lbl.add_theme_font_size_override("font_size", 18)
	media_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(media_lbl)

	for mtype: String in ["wheel", "box", "label", "manual"]:
		var has_it: bool = not (media.get(mtype, "") as String).is_empty()
		var icon := "✅" if has_it else "❌"
		_add_scrape_info_row(vbox, mtype.capitalize(), icon)

	vbox.add_child(HSeparator.new())

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var accept_btn := Button.new()
	accept_btn.text = "  ACCEPT  "
	accept_btn.custom_minimum_size = Vector2(0, 56)
	accept_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept_btn.add_theme_font_size_override("font_size", 20)
	var accept_style := StyleBoxFlat.new()
	accept_style.bg_color = COLOR_BTN_DL
	for k2 in ["corner_radius_top_left","corner_radius_top_right",
			   "corner_radius_bottom_left","corner_radius_bottom_right"]:
		accept_style.set(k2, 5)
	for state in ["normal", "hover", "pressed"]:
		accept_btn.add_theme_stylebox_override(state, accept_style)
	accept_btn.pressed.connect(_on_scrape_accepted.bind(rom_path, systemid, result))
	btn_row.add_child(accept_btn)

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_scrape_popup)
	btn_row.add_child(close_btn)

	# Add popup as sibling of the spawn view content
	_spawn_view.get_parent().add_child(_scrape_popup)


func _show_scrape_error_popup(error: String) -> void:
	_close_scrape_popup()

	_scrape_popup = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.08, 0.08, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_popup.add_theme_stylebox_override("panel", bg)
	_scrape_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_scrape_popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "SCRAPE FAILED"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	vbox.add_child(title)

	var err_lbl := Label.new()
	err_lbl.text = error
	err_lbl.add_theme_font_size_override("font_size", 18)
	err_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(err_lbl)

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_scrape_popup)
	vbox.add_child(close_btn)

	_spawn_view.get_parent().add_child(_scrape_popup)


func _close_scrape_popup() -> void:
	if _scrape_popup and is_instance_valid(_scrape_popup):
		_scrape_popup.queue_free()
	_scrape_popup = null


func _on_scrape_accepted(rom_path: String, systemid: String, result: Dictionary) -> void:
	_close_scrape_popup()

	var game_data := {
		"game_id": result.get("game_id", ""),
		"name": result.get("name", ""),
		"desc": result.get("desc", ""),
		"developer": result.get("developer", ""),
		"publisher": result.get("publisher", ""),
		"genre": result.get("genre", ""),
	}
	var rom_data := {
		"path": "./" + rom_path.get_file(),
		"romname": rom_path.get_file(),
		"releasedate": result.get("releasedate", ""),
		"region": result.get("rom_region", ""),
	}

	gamelist_manager.add_or_merge_rom(systemid, game_data, rom_data)
	gamelist_manager.save_gamelist(systemid)

	# Disconnect any stale media refresh callback from a previous accept
	if _media_dl_refresh_cb.is_valid() and \
			scraper_client.media_download_completed.is_connected(_media_dl_refresh_cb):
		scraper_client.media_download_completed.disconnect(_media_dl_refresh_cb)

	# Re-populate when wheel or manual finishes downloading so the list
	# updates without requiring a manual tab switch.
	_media_dl_refresh_cb = func(mtype: String, _path: String) -> void:
		if mtype == "wheel" or mtype == "manual":
			print("[SpawnMenu] Media downloaded (%s), refreshing cartridges tab." % mtype)
			_populate_cartridges_tab()
	scraper_client.media_download_completed.connect(_media_dl_refresh_cb)

	# Download media files asynchronously
	var rom_basename := rom_path.get_file().get_basename()
	scraper_client.download_all_media(result, systemid, rom_basename)

	# Refresh immediately so the game name / metadata shows right away
	_populate_cartridges_tab()


func _add_scrape_info_row(parent: VBoxContainer, key: String, value: String) -> void:
	if value.is_empty():
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var k_lbl := Label.new()
	k_lbl.text = key + ":"
	k_lbl.add_theme_font_size_override("font_size", 17)
	k_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	k_lbl.custom_minimum_size = Vector2(110, 0)
	row.add_child(k_lbl)

	var v_lbl := Label.new()
	v_lbl.text = value
	v_lbl.add_theme_font_size_override("font_size", 17)
	v_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	v_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(v_lbl)


func _show_game_detail_panel(game: Dictionary, systemid: String) -> void:
	_close_game_detail_panel()

	_game_detail_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.2, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_game_detail_panel.add_theme_stylebox_override("panel", bg)
	_game_detail_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_game_detail_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = game.get("name", "Unknown")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# Metadata
	_add_scrape_info_row(vbox, "Developer", game.get("developer", ""))
	_add_scrape_info_row(vbox, "Publisher", game.get("publisher", ""))
	_add_scrape_info_row(vbox, "Genre", game.get("genre", ""))

	vbox.add_child(HSeparator.new())

	# Description
	var desc: String = game.get("desc", "")
	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.add_theme_font_size_override("font_size", 16)
		desc_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(desc_lbl)
		vbox.add_child(HSeparator.new())

	# ROM variants button (if game has more than 1 ROM)
	var roms: Array = game.get("roms", [])
	if roms.size() > 1:
		var variants_btn := Button.new()
		variants_btn.text = "  ROM Variants (%d)  " % roms.size()
		variants_btn.custom_minimum_size = Vector2(0, 56)
		variants_btn.add_theme_font_size_override("font_size", 20)
		variants_btn.pressed.connect(_show_rom_variants_panel.bind(game, systemid))
		vbox.add_child(variants_btn)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_game_detail_panel)
	vbox.add_child(close_btn)

	_spawn_view.get_parent().add_child(_game_detail_panel)


func _close_game_detail_panel() -> void:
	_close_rom_variants_panel()
	if _game_detail_panel and is_instance_valid(_game_detail_panel):
		_game_detail_panel.queue_free()
	_game_detail_panel = null


func _show_rom_variants_panel(game: Dictionary, systemid: String) -> void:
	_close_rom_variants_panel()

	_rom_variants_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.12, 0.22, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_rom_variants_panel.add_theme_stylebox_override("panel", bg)
	_rom_variants_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_rom_variants_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	var title := Label.new()
	title.text = "ROM VARIANTS"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	var game_id: String = game.get("game_id", "")
	var roms: Array = game.get("roms", [])

	for rom: Dictionary in roms:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 64)

		# Star (preferred) button
		var is_preferred: bool = rom.get("preferred", false)
		var star_btn := Button.new()
		star_btn.text = "⭐" if is_preferred else "☆"
		star_btn.custom_minimum_size = Vector2(56, 56)
		star_btn.add_theme_font_size_override("font_size", 22)
		var rom_path_rel: String = rom.get("path", "")
		star_btn.pressed.connect(func():
			gamelist_manager.set_preferred_rom(systemid, game_id, rom_path_rel)
			gamelist_manager.save_gamelist(systemid)
			gamelist_manager.invalidate(systemid)
			var updated_game := _find_game_by_id(systemid, game_id)
			if not updated_game.is_empty():
				_show_rom_variants_panel(updated_game, systemid)
			_populate_cartridges_tab()
		)
		row.add_child(star_btn)

		# ROM name / wheel
		var rom_btn := Button.new()
		rom_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rom_btn.custom_minimum_size = Vector2(0, 56)
		rom_btn.add_theme_font_size_override("font_size", 18)

		var romname: String = rom.get("romname", "")
		var wheel_tex := _load_wheel_texture(systemid, romname)
		if wheel_tex:
			rom_btn.icon = wheel_tex
			rom_btn.text = ""
			rom_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rom_btn.expand_icon = true
		else:
			rom_btn.text = romname.get_basename()

		var abs_path := GamelistManager.to_absolute_path(systemid, rom.get("path", ""))
		rom_btn.pressed.connect(spawn_cartridge_requested.emit.bind(abs_path, romname.get_basename()))
		row.add_child(rom_btn)

		# Region label
		var region_str: String = rom.get("region", "")
		if not region_str.is_empty():
			var region_lbl := Label.new()
			region_lbl.text = region_str
			region_lbl.add_theme_font_size_override("font_size", 14)
			region_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
			region_lbl.custom_minimum_size = Vector2(50, 0)
			row.add_child(region_lbl)

		# Manual button
		if _has_scraped_manual(systemid, romname):
			var manual_btn := Button.new()
			manual_btn.text = "📖"
			manual_btn.custom_minimum_size = Vector2(56, 56)
			manual_btn.add_theme_font_size_override("font_size", 22)
			var pdf_path := _scraped_manual_path(systemid, romname)
			manual_btn.pressed.connect(spawn_manual_requested.emit.bind(pdf_path))
			row.add_child(manual_btn)

		vbox.add_child(row)

	vbox.add_child(HSeparator.new())

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_rom_variants_panel)
	vbox.add_child(close_btn)

	_spawn_view.get_parent().add_child(_rom_variants_panel)


func _close_rom_variants_panel() -> void:
	if _rom_variants_panel and is_instance_valid(_rom_variants_panel):
		_rom_variants_panel.queue_free()
	_rom_variants_panel = null


func _load_wheel_texture(systemid: String, romname: String) -> Texture2D:
	if romname.is_empty():
		return null
	var base := romname.get_basename()
	var media_dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/wheel")
	# Try common image extensions
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path := media_dir.path_join(base + ext)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				return ImageTexture.create_from_image(img)
	return null


func _has_scraped_manual(systemid: String, romname: String) -> bool:
	if romname.is_empty():
		return false
	return FileAccess.file_exists(_scraped_manual_path(systemid, romname))


func _scraped_manual_path(systemid: String, romname: String) -> String:
	var base := romname.get_basename()
	return RomLibrary.rom_dir_for_system(systemid).path_join("media/manual").path_join(base + ".pdf")


func _find_game_by_id(systemid: String, game_id: String) -> Dictionary:
	var gamelist := gamelist_manager.load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		if g.get("game_id", "") == game_id:
			return g
	return {}


# ── Helpers ───────────────────────────────────────────────────────────────────

func _sync_vscrollbar() -> void:
	pass # no longer used


func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c
