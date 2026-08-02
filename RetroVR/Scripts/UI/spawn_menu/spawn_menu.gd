## SpawnMenu2D — 2D Control rendered inside a SubViewport on the VR spawn panel.
## Builds its own UI programmatically so no extra tscn layout work is needed.
## Emits spawn_requested(type) when a spawn button is pressed,
## and close_requested when the ✕ button is pressed.
class_name SpawnMenu2D
extends Control

## Scale factor applied to the entire UI.  Increase this when viewport_size
## is higher than the logical design resolution so content stays the same
## apparent physical size in VR.  Default 2.0 matches viewport_size 2200×1500
## against the 1100×750 design resolution.
@export var ui_scale: float = 2.0

signal spawn_requested(type: String)
signal close_requested
## Emitted when the user changes a default core in the Manager tab.
signal default_core_changed(systemid: String, core_name: String)
## Emitted when the user clicks a ROM in the Cartridges tab.
signal spawn_cartridge_requested(rom_path: String, game_label: String, systemid: String)
## Emitted when the user clicks the manual (📖) button for a ROM.
signal spawn_manual_requested(pdf_path: String)
## Emitted when the user clicks a video (📼) in the Videos tab.
signal spawn_video_requested(video_path: String)

signal spawn_dvd_requested(dvd_path: String)
## Emitted when the user clicks an album (💿) in the CDs tab.
signal spawn_cd_requested(album_path: String)
## Emitted when the user clicks an album (🎵) in the Tapes tab.
signal spawn_cassette_requested(album_path: String)
## Emitted when the user changes the turn style. value is "SNAP" or "SMOOTH".
signal turn_style_changed(value: String)
## Emitted when the user clicks a room card that maps directly to a scene (e.g. passthrough).
signal scene_change_requested(scene_id: String)
## Emitted when the user clicks Load on a state card.
signal scene_slot_load_requested(slot_id: String)
## Emitted when the user clicks Save on a state card (overwrite).
signal scene_slot_save_requested(slot_id: String)
## Emitted when the user clicks Delete on a state card.
signal scene_slot_delete_requested(slot_id: String)
## Emitted when the user clicks "Save New".
signal scene_slot_create_requested
## Emitted when the user confirms a rename via the inline LineEdit.
signal scene_slot_rename_requested(slot_id: String, new_name: String)
## Emitted when the user toggles auto-save on scene switch.
signal auto_save_changed(enabled: bool)
## Emitted when the user toggles the FPS counter.
signal show_fps_changed(enabled: bool)
## Emitted when the user toggles the ray gun aim crosshair.
signal aim_crosshair_changed(enabled: bool)
## Emitted when the user toggles the wrap-around hands drawn on held controllers.
signal controller_hands_changed(enabled: bool)
## Emitted when the user changes the snap turn angle.
signal snap_angle_changed(degrees: float)
## Emitted when the user adjusts the player height offset.
signal height_offset_changed(offset: float)
## Emitted when the user changes the desktop camera FOV.
signal fov_changed(degrees: float)
## Emitted when the user changes the world scale (below 1.0 = feel smaller /
## everything bigger). Applies to VR (XRServer.world_scale) and desktop (eye height).
signal world_scale_changed(scale: float)
## Emitted when the user saves controller bindings (global or per-system).
signal controller_bindings_changed
## Emitted when the user clicks a desktop rebind button. spawn_menu_controller
## captures the next key/mouse press and calls back on_rebind_complete().
signal rebind_started(action_name: String)
## Emitted when the user clicks a GAME CONTROLLER rebind button.
## spawn_menu_controller captures the next joypad press and calls back
## on_pad_rebind_complete().
signal pad_rebind_started(target: String)

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

## RomM server integration (remote ROM library + cover art).
var romm_config: RommConfig = null
var romm_client: RommClient = null
var romm_catalog: RommCatalog = null
var romm_downloader: RommDownloader = null
var romm_cache: RommCacheManifest = null
var romm_art: RommArtCache = null
var romm_firmware: RommFirmware = null
## systemid -> platform dict from /api/platforms (with "systemid" added).
var _romm_platforms: Dictionary = {}
var _romm_unmapped: Array = []
## Slug signature of the last unmapped set announced, so it is reported once.
var _romm_unmapped_announced: String = ""
## Terminal outcomes that happened while the menu was closed, flushed on open.
var _romm_pending_notices: Array[Dictionary] = []
var _romm_status_label: Label = null
## Merged local+server row model for the open Cartridges detail page.
## Each entry: {source: "local"|"server"|"both", entry: Dictionary, path, label}
var _romm_rows: Array[Dictionary] = []
var _romm_detail_systemid: String = ""
var _romm_detail_exts: Array[String] = []
var _romm_filter: String = ""
## "all" | "downloaded" | "server" | "local", and a region name or "" for any.
var _romm_source_filter: String = "all"
var _romm_region_filter: String = ""
var _romm_region_drop: VRDropdown = null
var _romm_region_options: Array[String] = []
var _romm_list: VirtualRowList = null
var _romm_empty_label: Label = null
## rom_id -> percent, so a recycled row can show live progress when it scrolls
## back into view mid-download.
var _romm_progress_pct: Dictionary = {}
## Row index of the in-flight download, resolved once when it starts.
var _romm_dl_row_index: int = -1
## local_path -> {game, manual_path, has_manual}; binding hits the disk otherwise.
var _romm_meta_cache: Dictionary = {}
## Row index whose delete button is armed for its second confirming tap.
var _romm_delete_armed: int = -1
## Remaining systemids for an explicit "Sync all now".
var _romm_sync_queue: Array[String] = []
## "<systemid>/<filename>" -> Texture2D or null.
const MAX_WHEEL_TEXTURES := 200
## Wheel logos are scaled into this box so they cannot inflate the row height.
const WHEEL_BOX := Vector2i(300, 76)
var _wheel_cache: Dictionary = {}
var _wheel_cache_order: Array[String] = []

# ── UI state ──────────────────────────────────────────────────────────────────
var _spawn_view:    Control = null
var _cores_view:    Control = null
var _controls_view: Control = null
var _options_view:  Control = null
# Extracted into their own files — see Scripts/UI/spawn_menu/views/. Each owns
# its widgets and its state; this class only shows and hides them.
var _graphics_view: SpawnMenuGraphicsView = null
var _scene_view:    SpawnMenuSceneView = null
var _net_view:      SpawnMenuNetView = null
var _about_view:    Control = null
var _nav_net_btn:      Button = null
var _nav_spawn_btn:    Button = null
var _nav_cores_btn:    Button = null
var _nav_controls_btn: Button = null
var _nav_options_btn:  Button = null
var _nav_graphics_btn: Button = null
var _nav_scene_btn:    Button = null
var _nav_about_btn:    Button = null
var _nav_buttons: Array[Button] = []

# Cores > Download tab state
var _download_loading_label: Label        = null
var _download_fetched:       bool         = false
# core_name -> { "button": Button, "bar": ProgressBar }
var _download_widgets: Dictionary = {}
# Drill-down browser + fetched cores grouped by systemid ("__other__" = unknown):
#   sid -> Array[{ "core_name", "remote_date", "info" }]
var _download_browser: SystemGridBrowser = null
var _download_cores_by_system: Dictionary = {}
# Outer Download/Manager TabContainer of the Cores view.
var _cores_tabs: TabContainer = null

# The ScrollContainer currently in view
var _active_scroll:        ScrollContainer = null
var _controls_scroll:      ScrollContainer = null
var _options_scroll:       ScrollContainer = null
var _about_scroll:         ScrollContainer = null

# Spawn view tab ScrollContainers (indexed by tab index)
var _spawn_tab_scrolls: Array[ScrollContainer] = []
var _spawn_tabs: TabContainer = null

# Cores > Manager tab state — drill-down browser + installed cores grouped by
# systemid: sid -> Array[{ "core_name", "display_name" }]
var _manager_browser: SystemGridBrowser = null

## BIOS / Extras tab. `_bios_row_cache` is per-rebuild: the home grid and the
## detail page both need a system's resolved rows, and re-deriving them means
## re-stat'ing (and possibly re-hashing) every declared file.
var _bios_browser: SystemGridBrowser = null
var _bios_cores_by_system: Dictionary = {}
var _bios_row_cache: Dictionary = {}
var _firmware_installer: FirmwareInstaller = null
## job key -> the Button that started it, so progress can be shown in place.
## Rebuilt pages drop their buttons, so entries are validity-checked on use.
var _bios_job_buttons: Dictionary = {}
var _bios_refreshing := false

## Typing is bursty; one rebuild after the keys stop instead of one per key.
const SEARCH_DEBOUNCE_SEC := 0.18
var _romm_search_timer: Timer = null
## systemid -> {lowercase basename: rom}. A directory listing, so it is cached
## and dropped whenever something writes to a ROM dir.
var _local_scan_cache: Dictionary = {}
var _manager_cores_by_system: Dictionary = {}

# Spawn > Systems tab — drill-down browser, one title card per system
var _systems_browser: SystemGridBrowser = null
# Spawn > Cartridges tab — drill-down browser, one tile per system
var _cartridges_browser: SystemGridBrowser = null
# Spawn > Books tab — rebuilt each time the tab is opened
var _books_vbox: VBoxContainer = null
# Spawn > Videos tab — rebuilt each time the tab is opened
var _videos_vbox: VBoxContainer = null
var _dvds_vbox: VBoxContainer = null
var _cds_vbox: VBoxContainer = null
var _tapes_vbox: VBoxContainer = null

# Scrape popup overlay
var _scrape_popup: PanelContainer = null
var _scrape_in_progress: bool = false
# Scrape status bar (shows hashing / request / retry state below the menu)
var _scrape_status_bar: PanelContainer = null
var _scrape_status_label: Label = null
# Stacking media-download toasts (screenscraper box/manual/wheel/label).
# media_type -> { "bar": PanelContainer, "label": Label, "icon": Label }
var _media_toasts: Dictionary = {}
var _media_toast_stack: VBoxContainer = null
## The quad the stack floats on, once adopted. Null in a plain 2D scene.
var _toast_panel: ToastPanel = null
## The toast stack is anchored 300 px tall, so it holds ~5 bars before spilling
## off the panel. Beyond this many, the oldest collapse into a "+N more" bar.
const MAX_VISIBLE_TOASTS := 4
var _toast_overflow_bar: PanelContainer = null
var _toast_overflow_label: Label = null
# Game detail side panel
var _game_detail_panel: PanelContainer = null
# ROM variants side panel
var _rom_variants_panel: PanelContainer = null
# Callback connected to scraper_client.media_download_completed so the tab
# refreshes when a wheel image or manual PDF finishes downloading.
var _media_dl_refresh_cb: Callable = Callable()

# Working copies of controller bindings being edited in the Controls section.
var _edit_button_map:  Dictionary = {}
var _edit_stick_map:   Dictionary = {}
var _edit_lightgun_map: Dictionary = {}

# Desktop rebinding state: action currently waiting for a key press, and a
# map from action_name → Button node so on_rebind_complete() can update labels.
var _rebinding_action: String = ""
var _rebind_buttons: Dictionary = {}
# Inline dropdowns in the Controls section (source_key → VRDropdown).
# Mutual exclusion (only one expanded at a time) is owned by VRDropdown itself.
var _controls_opts: Dictionary = {}

# Working copies of physical-gamepad bindings edited in the GAME CONTROLLER section.
var _edit_pad_button_map: Dictionary = {}
var _pad_diagram: GamepadDiagram = null
var _pad_list_box: VBoxContainer = null
var _edit_pad_stick_map:  Dictionary = {}
# Gamepad rebinding state: target waiting for a joypad press, target → Button node.
var _pad_rebinding_target: String = ""
var _pad_rebind_buttons: Dictionary = {}
# Live "connected pads" status label in the GAME CONTROLLER section.
var _pad_status_label: Label = null


# ── Palette ───────────────────────────────────────────────────────────────────
## The colours themselves live in MenuStyle, so an extracted view uses the same
## ones. Aliased rather than replaced at ~250 call sites, which would be a large
## diff for no behavioural gain.
const COLOR_BG           := MenuStyle.COLOR_BG
const COLOR_NAV_ACTIVE   := MenuStyle.COLOR_NAV_ACTIVE
const COLOR_NAV_INACTIVE := MenuStyle.COLOR_NAV_INACTIVE
const COLOR_TITLE        := MenuStyle.COLOR_TITLE
const COLOR_LICENSE      := MenuStyle.COLOR_LICENSE
const COLOR_DESC         := MenuStyle.COLOR_DESC
const COLOR_BTN_DL       := MenuStyle.COLOR_BTN_DL
## Lighter than COLOR_BTN_DL, which is a button fill and unreadable as text here.
const COLOR_RECOMMENDED  := MenuStyle.COLOR_RECOMMENDED
const COLOR_BTN_UPD      := MenuStyle.COLOR_BTN_UPD
const COLOR_BTN_REUP     := MenuStyle.COLOR_BTN_REUP
const COLOR_BTN_BUSY     := MenuStyle.COLOR_BTN_BUSY


func _ready() -> void:
	SpawnMenuGraphicsView.restore_window_state()
	_init_core_db()
	_init_core_defaults()
	_init_download_manager()
	_init_scraper()
	_init_web_server()
	_init_romm()
	# Always ensure the roms root exists, plus dirs for any already-configured systems
	print("[SpawnMenu] roms root=", RomLibrary.default_roms_root())
	RomLibrary.ensure_roms_root()
	for sid: String in core_defaults.all_defaults():
		RomLibrary.ensure_rom_dir(sid)
	RomLibrary.ensure_books_root()
	RomLibrary.ensure_videos_root()
	RomLibrary.ensure_dvd_root()
	RomLibrary.ensure_music_root()
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
	scraper_client.scrape_status.connect(_update_scrape_status)
	scraper_client.media_download_started.connect(_on_media_download_started)
	scraper_client.media_download_completed.connect(_on_media_download_notice)
	scraper_client.media_download_failed.connect(_on_media_download_notice_failed)


## RomM: config + client + catalog + downloader + art cache, all wired to the
## toast stack. Nothing here touches the network at startup — the heaviest thing
## that ever runs on launch is one /api/stats ping, and only once the user opens
## the menu with a configured server.
func _init_romm() -> void:
	romm_config = RommConfig.new()
	romm_config.load_config()

	romm_client = RommClient.new()
	romm_client.name = "RommClient"
	romm_client.setup(romm_config)
	add_child(romm_client)
	romm_client.auth_failed.connect(_on_romm_auth_failed)
	romm_client.reachability_changed.connect(_on_romm_reachability_changed)

	romm_cache = RommCacheManifest.new()
	romm_cache.load_manifest()
	romm_cache.changed.connect(_on_romm_cache_changed)

	romm_catalog = RommCatalog.new()
	romm_catalog.name = "RommCatalog"
	romm_catalog.setup(romm_config)
	add_child(romm_catalog)
	romm_catalog.sync_started.connect(_on_romm_sync_started)
	romm_catalog.sync_progress.connect(_on_romm_sync_progress)
	romm_catalog.sync_finished.connect(_on_romm_sync_finished)

	romm_downloader = RommDownloader.new()
	romm_downloader.name = "RommDownloader"
	romm_downloader.setup(romm_config, romm_cache)
	add_child(romm_downloader)
	romm_downloader.download_started.connect(_on_romm_dl_started)
	romm_downloader.download_progress.connect(_on_romm_dl_progress)
	romm_downloader.download_retrying.connect(_on_romm_dl_retrying)
	romm_downloader.download_finished.connect(_on_romm_dl_finished)
	romm_downloader.download_cancelled.connect(_on_romm_dl_cancelled)
	romm_downloader.cache_evicted.connect(_on_romm_cache_evicted)

	# Show last run's platforms immediately; the refresh below only corrects it.
	for sid: String in romm_config.cached_platforms:
		var p: Variant = romm_config.cached_platforms[sid]
		if p is Dictionary:
			_romm_platforms[sid] = p

	romm_art = RommArtCache.new()
	romm_art.name = "RommArtCache"
	romm_art.setup(romm_config.base_url)
	add_child(romm_art)
	romm_art.art_ready.connect(_on_romm_art_ready)

	romm_firmware = RommFirmware.new()
	romm_firmware.name = "RommFirmware"
	romm_firmware.setup(romm_config)
	add_child(romm_firmware)
	# Redraw once the list lands: rows built before it arrives carry no cloud
	# button, and the tab should not block on a request to show what is on disk.
	romm_firmware.listed.connect(func(ok: bool, _n: int) -> void:
		if ok and _cores_tabs != null and _cores_tabs.current_tab == 2:
			_refresh_bios_view()
	)


func _init_web_server() -> void:
	if OS.get_name() != "Android":
		return
	web_server = WebFileServer.new()
	web_server.name = "WebFileServer"
	web_server.pin = scraper_config.ensure_web_server_pin()
	add_child(web_server)
	if scraper_config.web_server_enabled:
		web_server.start()


# ── Top-level UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Scale the entire UI so it fills the same apparent physical area regardless
	# of viewport_size.  pivot_offset keeps scaling centred on the panel.
	scale = Vector2(ui_scale, ui_scale)
	anchor_right  = 1.0 / ui_scale
	anchor_bottom = 1.0 / ui_scale

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
	_nav_spawn_btn    = _make_nav_button("SPAWN")
	_nav_cores_btn    = _make_nav_button("CORES")
	_nav_controls_btn = _make_nav_button("CONTROLS")
	_nav_options_btn  = _make_nav_button("OPTIONS")
	_nav_graphics_btn = _make_nav_button("GRAPHICS")
	_nav_scene_btn    = _make_nav_button("SCENE")
	_nav_net_btn      = _make_nav_button("NET")
	_nav_about_btn    = _make_nav_button("ABOUT")
	_nav_spawn_btn.pressed.connect(_show_spawn_view)
	_nav_cores_btn.pressed.connect(_show_cores_view)
	_nav_controls_btn.pressed.connect(_show_controls_view)
	_nav_options_btn.pressed.connect(_show_options_view)
	_nav_graphics_btn.pressed.connect(_show_graphics_view)
	_nav_scene_btn.pressed.connect(_show_scene_view)
	_nav_net_btn.pressed.connect(_show_net_view)
	_nav_about_btn.pressed.connect(_show_about_view)
	_nav_buttons = [_nav_spawn_btn, _nav_cores_btn, _nav_controls_btn, _nav_options_btn,
		_nav_graphics_btn, _nav_scene_btn, _nav_net_btn, _nav_about_btn]
	for btn in _nav_buttons:
		nav_bar.add_child(btn)

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

	_controls_view = _build_controls_view()
	_controls_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_controls_view)

	_options_view = _build_options_view()
	_options_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_options_view)

	_graphics_view = SpawnMenuGraphicsView.create(_is_vr_mode())
	_graphics_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_graphics_view)

	_scene_view = SpawnMenuSceneView.create()
	_scene_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Relayed rather than re-declared, so the controller's wiring is unchanged.
	_scene_view.scene_change_requested.connect(
		func(id: String) -> void: scene_change_requested.emit(id))
	_scene_view.slot_load_requested.connect(
		func(id: String) -> void: scene_slot_load_requested.emit(id))
	_scene_view.slot_save_requested.connect(
		func(id: String) -> void: scene_slot_save_requested.emit(id))
	_scene_view.slot_delete_requested.connect(
		func(id: String) -> void: scene_slot_delete_requested.emit(id))
	_scene_view.slot_create_requested.connect(
		func() -> void: scene_slot_create_requested.emit())
	_scene_view.slot_rename_requested.connect(
		func(id: String, n: String) -> void: scene_slot_rename_requested.emit(id, n))
	_scene_view.scroll_changed.connect(func(s: ScrollContainer) -> void:
		if _scene_view.visible:
			_active_scroll = s)
	content.add_child(_scene_view)

	_net_view = SpawnMenuNetView.create()
	_net_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_net_view)

	_about_view = _build_about_view()
	_about_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_about_view)

	_show_spawn_view()


func _is_vr_mode() -> bool:
	return MenuStyle.is_vr_mode()


## Shared iOS-style switch (see VRToggle) so every toggle in the UI matches.
func _make_toggle(initial_on: bool, on_toggled: Callable) -> Button:
	return VRToggle.create(initial_on, on_toggled)


func _make_nav_button(lbl: String) -> Button:
	var btn := Button.new()
	btn.text = lbl
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _show_view(view: Control, scroll: ScrollContainer, nav_btn: Button) -> void:
	for v: Control in [_spawn_view, _cores_view, _controls_view, _options_view, _graphics_view, _scene_view, _net_view, _about_view]:
		v.visible = v == view
	_active_scroll = scroll
	_set_nav_active(nav_btn)


func _show_spawn_view() -> void:
	_show_view(_spawn_view, null, _nav_spawn_btn)
	_update_spawn_active_scroll(_spawn_tabs.current_tab if _spawn_tabs else 0)


func _show_cores_view() -> void:
	_show_view(_cores_view, null, _nav_cores_btn)
	_update_cores_active_scroll()
	if not _download_fetched:
		_download_fetched = true
		_start_fetch()


## Point _active_scroll at the visible browser's current page.
func _update_cores_active_scroll() -> void:
	var idx := _cores_tabs.current_tab if _cores_tabs else 0
	if idx == 1 and _manager_browser:
		_active_scroll = _manager_browser.get_active_scroll()
	elif idx == 2 and _bios_browser:
		_active_scroll = _bios_browser.get_active_scroll()
	elif _download_browser:
		_active_scroll = _download_browser.get_active_scroll()
	else:
		_active_scroll = null


## Connected to both cores browsers; updates _active_scroll on page switches.
func _on_cores_browser_scroll_changed(s: ScrollContainer) -> void:
	if _cores_view and _cores_view.visible:
		_active_scroll = s


func _show_controls_view() -> void:
	_show_view(_controls_view, _controls_scroll, _nav_controls_btn)


func _show_options_view() -> void:
	_show_view(_options_view, _options_scroll, _nav_options_btn)


func _show_graphics_view() -> void:
	_show_view(_graphics_view, _graphics_view, _nav_graphics_btn)


func _show_scene_view() -> void:
	_show_view(_scene_view, null, _nav_scene_btn)
	# The view owns which of its two panels is up, and reports the scroll back
	# through scroll_changed — including when its own Back button switches them.
	_scene_view.show_rooms()


func _show_about_view() -> void:
	_show_view(_about_view, _about_scroll, _nav_about_btn)


func _show_net_view() -> void:
	_show_view(_net_view, _net_view, _nav_net_btn)
	_net_view.refresh()


## The arcade's save slots, repainted after the controller has actually saved,
## loaded or deleted one. Public because that lands on SceneManager rather than
## in the menu, so nothing here knows it happened.
func rebuild_states_grid() -> void:
	if _scene_view:
		_scene_view.rebuild_states_grid()


## Systems and Cartridges are SystemGridBrowsers that own their own scroll, and
## their slot in _spawn_tab_scrolls is null; every other tab is a plain
## ScrollContainer at the matching index. Keyed on title rather than position for
## the same reason the populate dispatch is.
func _update_spawn_active_scroll(tab_idx: int) -> void:
	var title := _spawn_tabs.get_tab_title(tab_idx) if _spawn_tabs != null \
		and tab_idx >= 0 and tab_idx < _spawn_tabs.get_tab_count() else ""
	if title == "Systems":
		_update_systems_inner_scroll()
	elif title == "Cartridges":
		_update_cartridges_inner_scroll()
	elif tab_idx >= 0 and tab_idx < _spawn_tab_scrolls.size():
		_active_scroll = _spawn_tab_scrolls[tab_idx]
	else:
		_active_scroll = null


func _update_systems_inner_scroll() -> void:
	if _systems_browser:
		_active_scroll = _systems_browser.get_active_scroll()
	else:
		_active_scroll = null


func _update_cartridges_inner_scroll() -> void:
	if _cartridges_browser:
		_active_scroll = _cartridges_browser.get_active_scroll()
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

	# Systems tab — drill-down browser, one title card per system (like Cores).
	# Opening a system lists its spawnable items (console model(s) + peripherals).
	_systems_browser = SystemGridBrowser.new()
	_systems_browser.name = "Systems"
	_systems_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_systems_browser.empty_text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
	_systems_browser.set_detail_populator(_populate_systems_detail)
	_systems_browser.active_scroll_changed.connect(func(_s: ScrollContainer):
		_update_systems_inner_scroll()
	)
	tabs.add_child(_systems_browser)
	_spawn_tab_scrolls.append(null)  # index 0 handled via _update_systems_inner_scroll
	_populate_systems_tab()

	# Rebuild systems/cartridges lists whenever the user sets/changes a default
	default_core_changed.connect(func(_sid: String, _cn: String): _populate_systems_tab())
	default_core_changed.connect(func(_sid: String, _cn: String): _populate_cartridges_tab())

	# Cartridges tab — drill-down browser, one tile per system
	_cartridges_browser = SystemGridBrowser.new()
	_cartridges_browser.name = "Cartridges"
	_cartridges_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# These tiles stand for the media, not the machine, so show the cartridge.
	_cartridges_browser.use_content_art = true
	_cartridges_browser.empty_text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
	_cartridges_browser.set_detail_populator(_populate_cartridges_detail)
	_cartridges_browser.active_scroll_changed.connect(func(_s: ScrollContainer):
		_update_cartridges_inner_scroll()
	)
	tabs.add_child(_cartridges_browser)
	# Its own browser owns the scroll, so this slot stays empty — see
	# _update_spawn_active_scroll.
	_spawn_tab_scrolls.append(null)
	_populate_cartridges_tab()

	_add_spawn_tab(tabs, "TVs", [["TV", "tv"]])

	# Books tab — lists PDFs from the books root directory
	var books_scroll := ScrollContainer.new()
	books_scroll.name = "Books"
	tabs.add_child(books_scroll)
	_spawn_tab_scrolls.append(books_scroll)
	_books_vbox = VBoxContainer.new()
	_books_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_books_vbox.add_theme_constant_override("separation", 10)
	books_scroll.add_child(_books_vbox)
	_populate_books_tab()

	# Videos tab — lists video files from the videos root directory
	var videos_scroll := ScrollContainer.new()
	videos_scroll.name = "Videos"
	tabs.add_child(videos_scroll)
	_spawn_tab_scrolls.append(videos_scroll)
	_videos_vbox = VBoxContainer.new()
	_videos_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_videos_vbox.add_theme_constant_override("separation", 10)
	videos_scroll.add_child(_videos_vbox)
	_populate_videos_tab()

	# DVDs tab — lists DVD images (VIDEO_TS folders / .iso / .img) from the dvd root
	var dvds_scroll := ScrollContainer.new()
	dvds_scroll.name = "DVDs"
	tabs.add_child(dvds_scroll)
	_spawn_tab_scrolls.append(dvds_scroll)
	_dvds_vbox = VBoxContainer.new()
	_dvds_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dvds_vbox.add_theme_constant_override("separation", 10)
	dvds_scroll.add_child(_dvds_vbox)
	_populate_dvds_tab()

	# CDs tab — lists music albums (folders of audio files / loose files) from the
	# music root; each spawns an AudioDisc for the CD player.
	var cds_scroll := ScrollContainer.new()
	cds_scroll.name = "CDs"
	tabs.add_child(cds_scroll)
	_spawn_tab_scrolls.append(cds_scroll)
	_cds_vbox = VBoxContainer.new()
	_cds_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cds_vbox.add_theme_constant_override("separation", 10)
	cds_scroll.add_child(_cds_vbox)
	_populate_cds_tab()

	# Tapes tab — same music library, each spawns an AudioCassette for the deck.
	var tapes_scroll := ScrollContainer.new()
	tapes_scroll.name = "Tapes"
	tabs.add_child(tapes_scroll)
	_spawn_tab_scrolls.append(tapes_scroll)
	_tapes_vbox = VBoxContainer.new()
	_tapes_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tapes_vbox.add_theme_constant_override("separation", 10)
	tapes_scroll.add_child(_tapes_vbox)
	_populate_tapes_tab()

	_add_spawn_tab(tabs, "Objects", [
		["Trash Can",       "trash_can"],
		["VCR",             "vcr_player"],
		["DVD Player",      "dvd_player"],
		["CD Player",       "cd_player"],
		["Cassette Player", "cassette_player"],
		["TV Remote",       "tv_remote"],
		["Memory Card",     "memory_card"],
	])

	_add_spawn_tab(tabs, "Controllers", [
		["Primitive Controller", "retro_controller"],
		["Ray Gun",            "ray_gun"],
		["Mouse",              "retro_mouse"],
		["Keyboard",           "retro_keyboard"],
	])

	# Refresh on tab switch — picks up files added to disk since last open
	# Also update _active_scroll to the current tab's ScrollContainer
	# Dispatched on the tab's title, not its index. These were index compares, and
	# reordering two tabs then meant finding every hardcoded position — four of
	# them, spread over three functions — with nothing to catch a miss but the
	# wrong list quietly refreshing.
	tabs.tab_changed.connect(func(idx: int):
		match tabs.get_tab_title(idx):
			"Cartridges": _populate_cartridges_tab()
			"Books": _populate_books_tab()
			"Videos": _populate_videos_tab()
			"DVDs": _populate_dvds_tab()
			"CDs": _populate_cds_tab()
			"Tapes": _populate_tapes_tab()
		_update_spawn_active_scroll(idx)
	)

	return TabStrip.wrap(tabs)


func _clear_vbox(vbox: VBoxContainer) -> void:
	for child in vbox.get_children():
		child.queue_free()
	vbox.add_child(_spacer(10))


## Rebuild the Systems home grid: one tile per system that has a default core.
## Spawnable items are listed lazily, only when a system tile is opened.
func _populate_systems_tab() -> void:
	if not _systems_browser:
		return
	var systems: Array = []
	for systemid: String in core_defaults.all_defaults():
		var sysname: String = core_db.get_systemname_for_id(systemid)
		var entry := {"systemid": systemid, "name": sysname}
		var n := SpawnCatalog.items_for(systemid, sysname).size()
		if n > 1:
			entry["badge"] = "%d items" % n
		systems.append(entry)
	_systems_browser.set_systems(systems)
	# If a system detail is open, re-run it so catalog changes appear.
	_systems_browser.refresh()


## Detail page for one system: each spawnable item — the console model(s) plus
## that system's controllers/peripherals. Tap to spawn; the menu stays open so
## several items can be spawned in a row.
func _populate_systems_detail(systemid: String, vbox: VBoxContainer) -> void:
	vbox.add_child(_spacer(4))
	for item: Dictionary in SpawnCatalog.items_for(systemid, core_db.get_systemname_for_id(systemid)):
		var btn := Button.new()
		btn.text = "  +  " + str(item.get("label", "Console"))
		btn.custom_minimum_size = Vector2(0, 80)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(spawn_requested.emit.bind(SpawnCatalog.spawn_token(systemid, item)))
		vbox.add_child(btn)
	vbox.add_child(_spacer(8))


## Rebuild the Cartridges home grid: one tile per system that has a default core
## OR a mapped RomM platform. ROMs are scanned/synced lazily, only when a system
## tile is opened — a full library sync at launch would be minutes of transfer
## before the user could do anything.
func _populate_cartridges_tab() -> void:
	if not _cartridges_browser:
		return

	var seen: Dictionary = {}
	var systems: Array = []
	for systemid: String in core_defaults.all_defaults():
		seen[systemid] = true
		systems.append({"systemid": systemid, "name": core_db.get_systemname_for_id(systemid)})

	for systemid: String in _romm_platforms:
		if not seen.has(systemid):
			systems.append({"systemid": systemid, "name": _system_label(systemid)})

	# Mark tiles backed by the server with the RomM isotipo and its ROM count.
	var mark: Texture2D = _romm_mark()
	for s: Dictionary in systems:
		var sid: String = s["systemid"]
		var remote := 0
		if _romm_platforms.has(sid):
			remote = int((_romm_platforms[sid] as Dictionary).get("rom_count", 0))
		if remote > 0 and mark != null:
			s["badge_icon"] = mark
			s["badge_count"] = remote

	_cartridges_browser.set_systems(systems)
	# If a system detail is open, re-run it so newly-added ROMs appear.
	_cartridges_browser.refresh()

	# Pull the largest synced platforms' sidecars into the file cache while the
	# user is still looking at the grid. Opening one is disk-bound the first
	# time — 25-37 ms on desktop, considerably worse on Quest storage — and this
	# spends that on a worker thread before the tap rather than during it.
	_prewarm_top_platforms(systems)


const _ROMM_MARK_PATH := "res://Textures/RomM/romm_logo.svg"
var _romm_mark_tex: Texture2D = null


func _romm_mark() -> Texture2D:
	if _romm_mark_tex == null and ResourceLoader.exists(_ROMM_MARK_PATH):
		_romm_mark_tex = load(_ROMM_MARK_PATH)
	return _romm_mark_tex


## One /api/platforms call, cached. Local systems are already on screen by the
## time this returns — server platforms just merge in.
func _romm_fetch_platforms() -> void:
	if romm_config == null or not romm_config.is_configured():
		return
	romm_client.platforms(func(ok: bool, platforms: Array) -> void:
		if not ok:
			return
		var part := RommPlatforms.partition(platforms, romm_config.platform_overrides)
		_romm_platforms.clear()
		for p: Dictionary in part["mapped"]:
			_romm_platforms[str(p["systemid"])] = p
		_romm_unmapped = part["unmapped"]

		# Only announce when the set actually changes. Most unmapped platforms
		# stay unmapped forever (no systemid or 3D model exists for them), so
		# re-reporting the same list on every menu open is pure noise.
		var signature := ""
		for p: Dictionary in _romm_unmapped:
			signature += str(p.get("slug", "")) + ","
		if not _romm_unmapped.is_empty() and signature != _romm_unmapped_announced:
			notify("romm:map", "⚠", "%d RomM platform%s unmapped — see OPTIONS"
				% [_romm_unmapped.size(), "" if _romm_unmapped.size() == 1 else "s"],
				-1.0, 4.0)
		_romm_unmapped_announced = signature

		# Rebuilding the tab means re-deriving every tile. The platform set
		# almost never changes between launches — it is already persisted and
		# used to draw the grid at startup — so only rebuild when it actually
		# moved. This ran on the same frame as a 70 KB JSON parse, which is
		# what made opening the menu hitch.
		var changed := _romm_platforms.size() != romm_config.cached_platforms.size()
		if not changed:
			for sid: String in _romm_platforms:
				if not romm_config.cached_platforms.has(sid):
					changed = true
					break
				var was: Dictionary = romm_config.cached_platforms[sid]
				if int(was.get("rom_count", -1)) != int((_romm_platforms[sid] as Dictionary).get("rom_count", -2)):
					changed = true
					break

		if changed:
			romm_config.cached_platforms = _romm_platforms.duplicate()
			romm_config.save_config()
			_populate_cartridges_tab()
		_update_romm_status_label()
	)


## Detail page for one system: local ROMs and the RomM library, merged.
##
## Local files render immediately; the server list appears when its index is
## ready (syncing that platform in the background if it has never been synced).
## The rows go into a VirtualRowList, so a 100k-entry platform costs the same as
## a 12-entry one.
func _populate_cartridges_detail(systemid: String, vbox: VBoxContainer) -> void:
	RomLibrary.ensure_rom_dir(systemid)
	_romm_detail_systemid = systemid
	_romm_rows.clear()
	_romm_filter = ""
	# Opening a platform must see the disk as it is now, not as it was.
	_invalidate_local_scan(systemid)

	# Collect all supported extensions for this system across all its cores.
	var exts: Array[String] = []
	for entry: Dictionary in core_db.get_by_systemid(systemid):
		for ext: String in entry.get("supported_extensions", "").split("|"):
			var e := ext.strip_edges().to_lower()
			if not e.is_empty() and e not in exts:
				exts.append(e)
	_romm_detail_exts = exts

	# Search and filters live in the browser's pinned toolbar, not in the scroll
	# area — they must stay reachable however far down the list you are.
	var toolbar := _cartridges_browser.detail_toolbar()
	toolbar.visible = true

	# Local filter over the cached names: instant at 100k rows, works offline.
	var search := LineEdit.new()
	search.placeholder_text = "Search %s…" % _system_label(systemid)
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(0, 52)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.add_theme_font_size_override("font_size", 20)
	search.text_changed.connect(_on_romm_search_changed)
	toolbar.add_child(search)

	var sep := VSeparator.new()
	sep.add_theme_constant_override("separation", 16)
	toolbar.add_child(sep)

	_romm_source_filter = "all"
	_romm_region_filter = ""

	var source_drop := VRDropdown.create("", [
		["All", "all"],
		["Downloaded", "downloaded"],
		["Not downloaded", "server"],
		["Local only", "local"],
	], "all", 1, Vector2(210, 52), 18)
	source_drop.size_flags_horizontal = Control.SIZE_SHRINK_END
	source_drop.float_panel = true
	source_drop.set_toggle_glyph(_ICON_FILTER, _symbols())
	source_drop.item_selected.connect(func(id: Variant) -> void:
		_romm_source_filter = str(id)
		_rebuild_romm_rows()
	)
	toolbar.add_child(source_drop)

	_romm_region_drop = VRDropdown.create("", [["All regions", ""]], "", 1, Vector2(210, 52), 18)
	_romm_region_drop.size_flags_horizontal = Control.SIZE_SHRINK_END
	_romm_region_drop.float_panel = true
	_romm_region_drop.set_toggle_glyph(_ICON_REGION, _symbols())
	_romm_region_drop.item_selected.connect(func(id: Variant) -> void:
		_romm_region_filter = str(id)
		_rebuild_romm_rows()
	)
	toolbar.add_child(_romm_region_drop)

	_romm_empty_label = Label.new()
	_romm_empty_label.add_theme_font_size_override("font_size", 18)
	_romm_empty_label.add_theme_color_override("font_color", COLOR_DESC)
	_romm_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_romm_empty_label.visible = false
	vbox.add_child(_romm_empty_label)

	_romm_list = VirtualRowList.new()
	_romm_list.row_height = 100
	_romm_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_romm_list.set_row_builder(_build_blank_rom_row)
	_romm_list.set_row_binder(_bind_rom_row)
	vbox.add_child(_romm_list)

	# Start before the first rebuild, or the empty list reads "add ROMs here"
	# while a sync is in fact already running.
	if _romm_platforms.has(systemid) and not RommCatalog.has_index(systemid):
		var pid := int((_romm_platforms[systemid] as Dictionary).get("id", 0))
		if pid > 0:
			romm_catalog.sync_platform(systemid, pid, true)

	_rebuild_romm_rows()


## Build the merged row model: every local file, plus every server entry, with
## entries that are both collapsed into one row.
##
## Dedupe is by filename first — cheap and correct for the overwhelmingly common
## case. Hashing 361 GiB to build a list is not an option, so MD5 is only
## consulted when a local hash happens to be cached already.
func _rebuild_romm_rows() -> void:
	var systemid := _romm_detail_systemid
	if systemid.is_empty():
		return

	_romm_rows.clear()
	var regions_seen: Dictionary = {}

	# 1. Local files, keyed by lowercase basename.
	#
	# Scanned WITHOUT the extension filter: RomM stores ROMs as .zip, which is
	# not in any core's supported_extensions, so a filtered scan cannot see a
	# freshly downloaded file and every row stays stuck on "download me".
	# Keying on the basename also survives the archive being unpacked, where
	# X.zip becomes X.3ds.
	# Cached: this is a directory listing, and a rebuild happens on every filter
	# change. Invalidated whenever something writes to the ROM dir — see
	# _invalidate_local_scan.
	var local_by_name: Dictionary = _local_by_name(systemid)

	# 2. Server entries. Everything here comes from sidecars already in RAM —
	# no seek and no JSON parse per row, or opening a 3k-ROM platform stalls the
	# frame for a second building rows nobody is looking at yet. The row's real
	# data is read on demand in _bind_rom_row, for the dozen rows on screen.
	var have_index := romm_catalog.load_index(systemid)
	var matched: Dictionary = {}
	if have_index:
		var fast := romm_catalog.has_fast_sidecars()
		var indices := PackedInt32Array()
		if _romm_filter.is_empty():
			indices.resize(romm_catalog.count())
			for i in romm_catalog.count():
				indices[i] = i
		else:
			indices = romm_catalog.search(_romm_filter)

		for i: int in indices:
			var key := ""
			var label := ""
			var regions := PackedStringArray()
			if fast:
				key = romm_catalog.fs_basename_at(i)
				label = romm_catalog.name_at(i)
				regions = romm_catalog.regions_at(i)
			else:
				# Index predates the sidecars; fall back to the slow path so an
				# un-resynced platform still works.
				var entry := romm_catalog.row(i)
				if entry.is_empty():
					continue
				key = str(entry.get("fs_name", "")).get_basename().to_lower()
				label = str(entry.get("name", key))
				var rl: Array = entry.get("regions", []) if entry.get("regions") is Array else []
				for r: Variant in rl:
					regions.append(str(r))

			var local: Dictionary = local_by_name.get(key, {})
			if not local.is_empty():
				matched[key] = true

			for r: String in regions:
				regions_seen[r] = true

			var src := "both" if not local.is_empty() else "server"
			if not _romm_row_passes(src, regions):
				continue
			_romm_rows.append({
				"source": src,
				"index": i,
				"path": str(local.get("path", "")),
				"label": label,
			})

	# 3. Local-only files the server doesn't know about. The extension filter
	# skipped in step 1 applies here, or gamelist.json lists itself as a ROM.
	for key: String in local_by_name:
		if matched.has(key):
			continue
		var rom: Dictionary = local_by_name[key]
		var ext := str(rom["path"]).get_extension().to_lower()
		if not _romm_detail_exts.is_empty() and ext not in _romm_detail_exts:
			continue
		var label := str(rom["label"])
		if not _romm_filter.is_empty() and not label.containsn(_romm_filter):
			continue
		# A local-only file has no server metadata, so it has no region to match.
		if not _romm_row_passes("local", PackedStringArray()):
			continue
		_romm_rows.append({
			"source": "local",
			"index": -1,
			"path": str(rom["path"]),
			"label": label,
		})

	_romm_refresh_region_options(regions_seen)

	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.set_row_count(_romm_rows.size())

	if _romm_empty_label != null and is_instance_valid(_romm_empty_label):
		_romm_empty_label.visible = _romm_rows.is_empty()
		if _romm_rows.is_empty():
			if not _romm_filter.is_empty():
				_romm_empty_label.text = "No games match “%s”." % _romm_filter
			elif romm_catalog.is_syncing():
				_romm_empty_label.text = "Syncing from RomM…"
			else:
				_romm_empty_label.text = "Add ROMs to %s/ to see them here." \
					% RomLibrary.rom_dir_for_system(systemid)


## Warm the sidecars for the platforms most likely to be opened next.
##
## Biggest first, because cost scales with row count and those are the ones that
## stutter. Capped: the warm worker handles one platform at a time and a long
## queue would still be running when the user taps.
func _prewarm_top_platforms(systems: Array) -> void:
	if romm_catalog == null:
		return
	var sized: Array = []
	for s: Dictionary in systems:
		var sid: String = s["systemid"]
		if int(s.get("badge_count", 0)) > 0:
			sized.append([int(s["badge_count"]), sid])
	sized.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	# Every synced platform, not just the first few: the worker also backfills
	# missing sidecars, which is a one-time repair worth doing for all of them
	# rather than only the ones that happen to be biggest.
	for e: Array in sized:
		romm_catalog.prewarm_index(str(e[1]))


## Local ROM files for one system, keyed by lowercase basename.
##
## Scanned WITHOUT the extension filter: RomM stores ROMs as .zip, which is not
## in any core's supported_extensions, so a filtered scan cannot see a freshly
## downloaded file and every row stays stuck on "download me". Keying on the
## basename also survives the archive being unpacked, where X.zip becomes X.3ds.
func _local_by_name(systemid: String) -> Dictionary:
	if _local_scan_cache.has(systemid):
		return _local_scan_cache[systemid]
	var by_name: Dictionary = {}
	for rom: Dictionary in RomLibrary.scan_roms(systemid, [] as Array[String]):
		by_name[str(rom["path"]).get_file().get_basename().to_lower()] = rom
	_local_scan_cache[systemid] = by_name
	return by_name


## Drop the cached listing after anything that writes to a ROM directory —
## a download landing, an eviction, a scrape, a manual refresh.
func _invalidate_local_scan(systemid: String = "") -> void:
	if systemid.is_empty():
		_local_scan_cache.clear()
	else:
		_local_scan_cache.erase(systemid)


func _romm_row_passes(source: String, regions: PackedStringArray) -> bool:
	match _romm_source_filter:
		"downloaded":
			if source == "server":
				return false
		"server":
			if source != "server":
				return false
		"local":
			if source != "local":
				return false

	if not _romm_region_filter.is_empty():
		if _romm_region_filter not in regions:
			return false
	return true


## Rebuild the region list from what the platform actually contains, keeping the
## current selection if it survives.
func _romm_refresh_region_options(seen: Dictionary) -> void:
	var names: Array[String] = []
	for r: String in seen:
		if not r.is_empty():
			names.append(r)
	names.sort()
	if names == _romm_region_options:
		return
	_romm_region_options = names

	# A selection that no longer exists on this platform would silently empty
	# the list.
	if not _romm_region_filter.is_empty() and _romm_region_filter not in names:
		_romm_region_filter = ""

	if _romm_region_drop == null or not is_instance_valid(_romm_region_drop):
		return
	var opts: Array = [["All regions", ""]]
	for r: String in names:
		opts.append([r, r])
	_romm_region_drop.set_options(opts, _romm_region_filter)


## Debounced: a rebuild scans the ROM dir, runs the filter over every server
## row and rebuilds the model, which is tens of milliseconds on a 3k platform
## on Quest. Doing that per keystroke made typing stutter; typing is bursty, so
## coalescing to one rebuild once the keys stop costs nothing in responsiveness.
func _on_romm_search_changed(text: String) -> void:
	_romm_filter = text.strip_edges().to_lower()
	if _romm_search_timer == null:
		_romm_search_timer = Timer.new()
		_romm_search_timer.one_shot = true
		_romm_search_timer.wait_time = SEARCH_DEBOUNCE_SEC
		_romm_search_timer.timeout.connect(_rebuild_romm_rows)
		add_child(_romm_search_timer)
	_romm_search_timer.start(SEARCH_DEBOUNCE_SEC)


# ── Virtualized ROM rows ──────────────────────────────────────────────────────
# Glyph codepoints verified present in RetroVR/fonts/SymbolsNerdFont-Regular.ttf.
# Two different delete glyphs is deliberate: the pictogram encodes whether the
# file can be got back. (At row size the two trash cans look near-identical, so
# the confirm text carries the real distinction — the glyph is a support cue.)
const _ICON_DOWNLOAD  := 0xF0ED    # fa-cloud_download  — on the server, not here
const _ICON_BUSY      := 0xF019    # fa-download        — transferring now
const _ICON_DELETE    := 0xF01B4   # md-delete          — reversible (still on server)
const _ICON_DELETE_FOREVER := 0xF05E8  # md-delete_forever — local only, gone for good
const _ICON_RETRY     := 0xF021    # fa-refresh
const _ICON_ERROR     := 0xF071    # fa-warning
const _ICON_GAMEPAD   := 0xF11B    # fa-gamepad
const _ICON_BOOK      := 0xF05DA   # md-book_open_page_variant
const _ICON_SCRAPE    := 0xF0866   # md-database_search
const _ICON_FILTER    := 0xF0B0    # fa-filter
const _ICON_REGION    := 0xF01E7   # md-earth
const _ICON_RECOMMENDED := 0xF0124 # md-certificate     — the pick for this system
const _ICON_CHECK     := 0xF012C   # md-check           — firmware present
const _ICON_CROSS     := 0xF0159   # md-close_thick     — required firmware absent
const _ICON_DASH      := 0xF0374   # md-minus           — optional firmware absent
const _SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"

const _TINT_DOWNLOAD := Color(0.45, 0.70, 1.00)
const _TINT_BUSY     := Color(1.00, 0.75, 0.25)
const _TINT_DELETE   := Color(0.95, 0.40, 0.40)
const _TINT_OK       := Color(0.40, 0.85, 0.45)
const _TINT_WARN     := Color(1.00, 0.72, 0.20)
const _TINT_MUTED    := Color(0.45, 0.45, 0.58)

## Built once and shared — the list recycles rows, so a FontVariation per row
## (or per bind) would churn resources on every scroll.
var _symbol_font: FontVariation = null


func _symbols() -> FontVariation:
	if _symbol_font != null:
		return _symbol_font
	_symbol_font = FontVariation.new()
	_symbol_font.base_font = ThemeDB.fallback_font
	var symbols: Font = load(_SYMBOL_FONT_PATH)
	if symbols != null:
		_symbol_font.fallbacks = [symbols]
	return _symbol_font


## Allocate one blank recyclable row. Called ~12 times total, not once per ROM.
func _build_blank_rom_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var state := Button.new()
	state.name = "State"
	state.custom_minimum_size = Vector2(76, 100)
	state.add_theme_font_override("font", _symbols())
	state.add_theme_font_size_override("font_size", 40)
	row.add_child(state)

	var pct := Label.new()
	pct.name = "Pct"
	pct.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pct.add_theme_font_size_override("font_size", 15)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pct.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	pct.offset_top = -32
	pct.offset_bottom = -14
	pct.visible = false
	state.add_child(pct)

	var cover := TextureRect.new()
	cover.name = "Cover"
	cover.custom_minimum_size = Vector2(72, 96)
	cover.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(cover)

	var main := MarqueeButton.create("", 22)
	main.name = "Main"
	main.custom_minimum_size = Vector2(0, 100)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(main)

	for n: String in ["Detail", "Manual", "Scrape"]:
		var b := Button.new()
		b.name = n
		b.custom_minimum_size = Vector2(66, 100)
		b.add_theme_font_override("font", _symbols())
		b.add_theme_font_size_override("font_size", 26)
		b.add_theme_color_override("font_color", Color(0.72, 0.72, 0.86))
		row.add_child(b)

	return row


## Fill a recycled row for `index`. Runs on every scroll, so it must be cheap
## and must disconnect anything it connected last time.
func _bind_rom_row(row: Control, index: int) -> void:
	if index < 0 or index >= _romm_rows.size():
		return
	var model: Dictionary = _romm_rows[index]
	# Read on demand: this is the only place a row's JSON is parsed.
	var cat_index := int(model.get("index", -1))
	var entry: Dictionary = romm_catalog.row(cat_index) if cat_index >= 0 else {}
	var systemid := _romm_detail_systemid
	var source := str(model["source"])
	var label := str(model["label"])
	var rom_id := int(entry.get("id", 0))
	var local_path := str(model["path"])

	var state := row.get_node("State") as Button
	var pct := state.get_node("Pct") as Label
	var cover := row.get_node("Cover") as TextureRect
	var main := row.get_node("Main") as MarqueeButton
	var detail := row.get_node("Detail") as Button
	var manual := row.get_node("Manual") as Button
	var scrape := row.get_node("Scrape") as Button

	_disconnect_all(state.pressed)
	_disconnect_all(main.pressed)
	_disconnect_all(detail.pressed)
	_disconnect_all(manual.pressed)
	_disconnect_all(scrape.pressed)

	# A scraped wheel logo replaces the title text entirely; otherwise the title
	# scrolls. MarqueeButton extends Button, so it carries the icon itself.
	var wheel: Texture2D = null
	if not local_path.is_empty():
		wheel = _cached_wheel_texture(systemid, local_path.get_file())
	if wheel != null:
		main.icon = wheel
		main.expand_icon = false
		main.add_theme_constant_override("icon_max_width", WHEEL_BOX.x)
		main.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		main.set_marquee_text("")
	else:
		main.icon = null
		main.expand_icon = false
		# MarqueeButton keeps its own `text` empty and draws via an internal
		# label — setting `text` directly would fight its width clipping.
		main.set_marquee_text("  " + label)

	# ── Leading state icon ──────────────────────────────────────────────────
	var downloading := rom_id > 0 and romm_downloader.current_rom_id() == rom_id
	pct.visible = false

	if downloading:
		state.text = String.chr(_ICON_BUSY)
		state.add_theme_color_override("font_color", _TINT_BUSY)
		state.tooltip_text = "Cancel download"
		pct.visible = true
		pct.add_theme_color_override("font_color", _TINT_BUSY)
		pct.text = "%d%%" % _romm_progress_pct.get(rom_id, 0)
		state.pressed.connect(func() -> void: romm_downloader.cancel_current())
	elif source == "server":
		state.text = String.chr(_ICON_DOWNLOAD)
		# The cloud glyph is visually lighter than the trash glyphs at the same
		# size — a small bump evens the weight out.
		state.add_theme_font_size_override("font_size", 44)
		state.add_theme_color_override("font_color", _TINT_DOWNLOAD)
		state.tooltip_text = "Download from RomM (%s)" % _human_bytes(int(entry.get("fs_size_bytes", 0)))
		state.pressed.connect(func() -> void: romm_downloader.enqueue(entry, systemid))
	else:
		state.add_theme_font_size_override("font_size", 40)
		var forever := source == "local"
		state.text = String.chr(_ICON_DELETE_FOREVER if forever else _ICON_DELETE)
		state.add_theme_color_override("font_color", _TINT_DELETE)
		state.tooltip_text = "Delete permanently" if forever else "Delete local copy"
		state.pressed.connect(_on_rom_delete_pressed.bind(index, state))

	# ── Cover ───────────────────────────────────────────────────────────────
	cover.texture = null
	if rom_id > 0:
		cover.texture = romm_art.get_or_request(rom_id, str(entry.get("cover_small", "")), systemid)
	if cover.texture == null and not model["path"].is_empty():
		cover.texture = MediaDimensions.load_label_texture(systemid, str(model["path"]))
	cover.visible = cover.texture != null

	# ── Launch ──────────────────────────────────────────────────────────────
	if not local_path.is_empty():
		main.pressed.connect(func() -> void:
			if romm_cache != null:
				romm_cache.touch(systemid, local_path.get_file())
			spawn_cartridge_requested.emit(local_path, label, systemid)
		)
	else:
		# Not downloaded yet — tapping the title fetches it, same as the icon.
		main.pressed.connect(func() -> void: romm_downloader.enqueue(entry, systemid))

	# ── Trailing cluster ────────────────────────────────────────────────────
	var meta := _romm_row_meta(systemid, local_path)
	var game: Dictionary = meta["game"]
	detail.text = String.chr(_ICON_GAMEPAD)
	detail.visible = not game.is_empty()
	if not game.is_empty():
		detail.pressed.connect(_show_game_detail_panel.bind(game, systemid))

	var has_manual: bool = meta["has_manual"]
	var manual_path: String = meta["manual_path"]
	manual.text = String.chr(_ICON_BOOK)
	manual.visible = has_manual
	if has_manual:
		manual.pressed.connect(spawn_manual_requested.emit.bind(manual_path))

	# Scraping hashes the local file, so it needs one on disk.
	# disabled is reset here or a mid-scrape scroll leaves it stuck on whichever
	# row later reuses this pooled button.
	scrape.text = String.chr(_ICON_SCRAPE)
	scrape.disabled = false
	scrape.visible = not local_path.is_empty()
	scrape.tooltip_text = "Scrape artwork and details from ScreenScraper"
	if not local_path.is_empty():
		scrape.pressed.connect(_on_scrape_pressed.bind(local_path, systemid, scrape))


## Two-stage delete: the first press arms it, the second within 3 s commits.
## A single mis-tap must never delete a 4 GB download, and every
## Viewport2Din3D click already fires twice.
func _on_rom_delete_pressed(index: int, state: Button) -> void:
	if index < 0 or index >= _romm_rows.size():
		return
	var model: Dictionary = _romm_rows[index]
	var local_path := str(model["path"])
	if local_path.is_empty():
		return

	if _romm_delete_armed != index:
		_romm_delete_armed = index
		state.text = String.chr(_ICON_ERROR)
		var forever := str(model["source"]) == "local"
		show_notice("Tap again to %s" % ("delete permanently" if forever else "delete local copy"), 3.0)
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if _romm_delete_armed == index:
				_romm_delete_armed = -1
				if _romm_list != null and is_instance_valid(_romm_list):
					_romm_list.rebind_visible()
		)
		return

	_romm_delete_armed = -1
	var systemid := _romm_detail_systemid
	var fname := local_path.get_file()

	if FileAccess.file_exists(local_path):
		DirAccess.remove_absolute(local_path)
	if romm_cache != null:
		romm_cache.forget(systemid, fname)

	show_notice("Deleted %s" % fname, 2.5)
	_romm_meta_cache.clear()
	_rebuild_romm_rows()


## Gamelist entry and manual path for a row. Memoized because the raw form is a
## linear scan of gamelist.json plus two file_exists calls, run per row on every
## bind — which is every scroll step and, previously, every download progress tick.
func _romm_row_meta(systemid: String, local_path: String) -> Dictionary:
	if local_path.is_empty():
		return {"game": {}, "manual_path": "", "has_manual": false}
	if _romm_meta_cache.has(local_path):
		return _romm_meta_cache[local_path]

	var manual_path := _scraped_manual_path(systemid, local_path.get_file())
	var meta := {
		"game": gamelist_manager.get_game_for_rom(systemid, local_path),
		"manual_path": manual_path,
		"has_manual": FileAccess.file_exists(manual_path),
	}
	_romm_meta_cache[local_path] = meta
	return meta


## Memoized _load_wheel_texture. Binding is per-row per-scroll, and the raw
## lookup is 4 file_exists calls plus a synchronous decode — misses are cached
## too, since most ROMs have no wheel.
func _cached_wheel_texture(systemid: String, filename: String) -> Texture2D:
	var key := systemid + "/" + filename
	if _wheel_cache.has(key):
		return _wheel_cache[key]

	var tex := _load_wheel_texture(systemid, filename)
	_wheel_cache[key] = tex
	_wheel_cache_order.append(key)
	while _wheel_cache_order.size() > MAX_WHEEL_TEXTURES:
		_wheel_cache.erase(_wheel_cache_order.pop_front())
	return tex


## Rows are recycled, so every connection from the previous bind must go.
static func _disconnect_all(sig: Signal) -> void:
	for c: Dictionary in sig.get_connections():
		sig.disconnect(c["callable"])




func _populate_books_tab() -> void:
	if not _books_vbox:
		return
	_clear_vbox(_books_vbox)
	var books := RomLibrary.scan_books()
	if books.is_empty():
		var hint := Label.new()
		hint.text = "No PDFs found in books folder."
		hint.add_theme_color_override("font_color", COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_books_vbox.add_child(hint)
		return
	for book: Dictionary in books:
		var btn := Button.new()
		btn.text = "  📖  " + book["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_manual_requested.emit.bind(book["path"]))
		_books_vbox.add_child(btn)
	_books_vbox.add_child(_spacer(8))


func _populate_videos_tab() -> void:
	if not _videos_vbox:
		return
	_clear_vbox(_videos_vbox)
	var videos := RomLibrary.scan_videos()
	if videos.is_empty():
		var hint := Label.new()
		hint.text = "No videos found in videos folder."
		hint.add_theme_color_override("font_color", COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_videos_vbox.add_child(hint)
		return
	for video: Dictionary in videos:
		var btn := Button.new()
		btn.text = "  📼  " + video["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_video_requested.emit.bind(video["path"]))
		_videos_vbox.add_child(btn)
	_videos_vbox.add_child(_spacer(8))


func _populate_dvds_tab() -> void:
	if not _dvds_vbox:
		return
	_clear_vbox(_dvds_vbox)
	var dvds := RomLibrary.scan_dvds()
	if dvds.is_empty():
		var hint := Label.new()
		hint.text = "No DVD images found in dvd folder."
		hint.add_theme_color_override("font_color", COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_dvds_vbox.add_child(hint)
		return
	for dvd: Dictionary in dvds:
		var btn := Button.new()
		btn.text = "  💿  " + dvd["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_dvd_requested.emit.bind(dvd["path"]))
		_dvds_vbox.add_child(btn)
	_dvds_vbox.add_child(_spacer(8))


func _populate_cds_tab() -> void:
	_populate_music_vbox(_cds_vbox, "💿", spawn_cd_requested)


func _populate_tapes_tab() -> void:
	_populate_music_vbox(_tapes_vbox, "🎵", spawn_cassette_requested)


## Shared list builder for the CDs / Tapes tabs — both list the same music
## albums, differing only in the icon and which spawn signal a row fires.
func _populate_music_vbox(vbox: VBoxContainer, icon: String, sig: Signal) -> void:
	if not vbox:
		return
	_clear_vbox(vbox)
	var albums := RomLibrary.scan_music()
	if albums.is_empty():
		var hint := Label.new()
		hint.text = "No music found in music folder."
		hint.add_theme_color_override("font_color", COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(hint)
		return
	for album: Dictionary in albums:
		var btn := Button.new()
		btn.text = "  %s  %s" % [icon, album["label"]]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(sig.emit.bind(album["path"]))
		vbox.add_child(btn)
	vbox.add_child(_spacer(8))


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
	_cores_tabs = tabs

	var dl_container := _build_download_tab()
	dl_container.name = "Download"
	tabs.add_child(dl_container)

	var mgr_container := _build_manager_tab()
	mgr_container.name = "Manager"
	tabs.add_child(mgr_container)

	var bios_container := _build_bios_tab()
	# The node name cannot hold the "/" — Godot rejects it in node names and
	# TabContainer titles each tab after its child, so it would read "BIOS _
	# Extras". The title has to be set separately, after the add.
	bios_container.name = "BIOSExtras"
	tabs.add_child(bios_container)
	tabs.set_tab_title(tabs.get_tab_count() - 1, "BIOS / Extras")

	# Both the Manager and BIOS lists are derived from what is on disk, so each
	# is rebuilt on entry rather than cached — installing a core changes both.
	tabs.tab_changed.connect(func(idx: int):
		if idx == 1:
			_populate_manager_tab()
		elif idx == 2:
			_populate_bios_tab()
		_update_cores_active_scroll()
	)

	return TabStrip.wrap(tabs)


# ── Manager tab ───────────────────────────────────────────────────────────────────

func _build_manager_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	var hdr := Label.new()
	hdr.text = "Pick a system to set the default core it launches with."
	hdr.add_theme_font_size_override("font_size", 15)
	hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(hdr)

	outer.add_child(HSeparator.new())

	_manager_browser = SystemGridBrowser.new()
	_manager_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_manager_browser.empty_text = "No cores downloaded yet.\nUse the Download tab to install cores."
	_manager_browser.set_detail_populator(_populate_manager_detail)
	_manager_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_manager_browser)

	return outer


## Rebuild the Manager home grid: one tile per system with installed cores,
## badge = its current default core. Rescans the cores dir each call.
func _populate_manager_tab() -> void:
	if not _manager_browser:
		return

	_manager_cores_by_system.clear()
	var system_labels: Dictionary = {}   # systemid -> human label

	var cores_dir := CoreDownloadManager.default_cores_dir()
	var dir := DirAccess.open(cores_dir)
	if dir:
		var seen: Dictionary = {}   # a core can sit there under two naming conventions
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			var cn := "" if dir.current_is_dir() else CoreDownloadManager.core_name_from_lib_filename(fname)
			if not cn.is_empty() and not seen.has(cn):
				seen[cn] = true
				var info: Dictionary = core_db.get_by_core_name(cn)
				var sid: String  = info.get("systemid",   "unknown") if not info.is_empty() else "unknown"
				var sname: String = info.get("systemname", cn)       if not info.is_empty() else cn
				if not _manager_cores_by_system.has(sid):
					_manager_cores_by_system[sid] = []
					system_labels[sid]  = sname
				(_manager_cores_by_system[sid] as Array).append({"core_name": cn,
					"display_name": info.get("corename", cn) if not info.is_empty() else cn})
			fname = dir.get_next()
		dir.list_dir_end()

	var systems: Array = []
	for sid: String in _manager_cores_by_system:
		# Recommended first, so it heads the detail list AND is what the
		# no-default-yet branch below picks up.
		var cores_list: Array = CoreRecommendations.first(
			sid, _manager_cores_by_system[sid] as Array)
		_manager_cores_by_system[sid] = cores_list
		# If no default was saved yet, persist the first available core.
		var current_default: String = core_defaults.get_default_core(sid)
		if current_default.is_empty() and not cores_list.is_empty():
			current_default = (cores_list[0] as Dictionary)["core_name"] as String
			core_defaults.set_default_core(sid, current_default)
			core_defaults.save()
			RomLibrary.ensure_rom_dir(sid)
			default_core_changed.emit(sid, current_default)
		var badge := ""
		for e: Dictionary in cores_list:
			if e["core_name"] == current_default:
				badge = e["display_name"] as String
		systems.append({"systemid": sid, "name": system_labels[sid] as String, "badge": badge})

	_manager_browser.set_systems(systems)


## Detail page for one system: its installed cores, tap to set the default.
func _populate_manager_detail(systemid: String, vbox: VBoxContainer) -> void:
	var cores: Array = _manager_cores_by_system.get(systemid, [])
	var current: String = core_defaults.get_default_core(systemid)
	for entry: Dictionary in cores:
		var cn: String = entry["core_name"] as String
		var is_def := cn == current

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.custom_minimum_size = Vector2(0, 64)

		var lbl := Label.new()
		lbl.text = ("✓  " if is_def else "     ") + (entry["display_name"] as String)
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.add_theme_color_override("font_color", COLOR_TITLE if is_def else COLOR_LICENSE)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(lbl)

		# Its own element rather than a recolour of the name: the name's ✓ and
		# colour already mean "this is your default", and the two states are
		# independent — a core can be recommended without being selected.
		if CoreRecommendations.is_recommended(systemid, cn):
			row.add_child(_recommended_badge(16))

		var btn := Button.new()
		btn.text = "Default" if is_def else "Set default"
		btn.disabled = is_def
		btn.custom_minimum_size = Vector2(180, 52)
		btn.add_theme_font_size_override("font_size", 17)
		btn.pressed.connect(func() -> void:
			core_defaults.set_default_core(systemid, cn)
			core_defaults.save()
			RomLibrary.ensure_rom_dir(systemid)
			default_core_changed.emit(systemid, cn)
			# Rebuild tiles (badge) then re-render this detail (checkmarks).
			_populate_manager_tab()
			_manager_browser.open_system(systemid)
		)
		row.add_child(btn)

		vbox.add_child(row)
		vbox.add_child(HSeparator.new())


# ── BIOS / Extras tab ─────────────────────────────────────────────────────────
#
# Every installed core declares, in its .info, the files it wants in its system
# directory. Nothing surfaced them before, so a core that cannot boot without a
# BIOS just failed silently. This lists them per system, marks what is there,
# and (Phase 2/3) fetches what is not.
#
# Required and optional are shown very differently on purpose: of the ~149
# entries a typical install declares, only about 6 are actually required. A red
# cross on every missing optional would paint every system as broken.

func _build_bios_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	var hdr := Label.new()
	hdr.text = "Files each core needs in its system folder. Only missing required files stop a game from running."
	hdr.add_theme_font_size_override("font_size", 15)
	hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(hdr)

	outer.add_child(HSeparator.new())

	_bios_browser = SystemGridBrowser.new()
	_bios_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bios_browser.empty_text = "No cores downloaded yet.\nUse the Download tab to install cores."
	_bios_browser.filter_placeholder = "Filter systems…"
	_bios_browser.set_detail_populator(_populate_bios_detail)
	_bios_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_bios_browser)

	_firmware_installer = FirmwareInstaller.new()
	_firmware_installer.name = "FirmwareInstaller"
	_firmware_installer.job_started.connect(_on_firmware_started)
	_firmware_installer.job_progress.connect(_on_firmware_progress)
	_firmware_installer.job_retrying.connect(_on_firmware_retrying)
	_firmware_installer.job_finished.connect(_on_firmware_finished)
	_firmware_installer.job_cancelled.connect(_on_firmware_cancelled)
	add_child(_firmware_installer)

	return outer


# ── Install progress ──────────────────────────────────────────────────────────

func _on_firmware_started(key: String, label: String, total: int) -> void:
	var size_text := "" if total <= 0 else "  (%s)" % String.humanize_size(total)
	_romm_notify_or_queue(key, String.chr(_ICON_BUSY),
		"Downloading %s%s" % [label, size_text], 0.0, 0.0)


func _on_firmware_progress(key: String, received: int, total: int) -> void:
	var frac := 0.0 if total <= 0 else clampf(float(received) / float(total), 0.0, 1.0)
	var btn := _bios_job_buttons.get(key) as Button
	if btn != null and is_instance_valid(btn):
		btn.text = "%d%%" % int(frac * 100.0)
	_romm_notify_or_queue(key, String.chr(_ICON_BUSY),
		"Downloading %s" % String.humanize_size(total), 0.0, frac)


func _on_firmware_retrying(key: String, attempt: int, total: int, reason: String) -> void:
	_romm_notify_or_queue(key, String.chr(_ICON_RETRY),
		"%s — retry %d of %d" % [reason, attempt, total], 0.0)


func _on_firmware_finished(key: String, ok: bool, error: String) -> void:
	_bios_job_buttons.erase(key)
	if ok:
		_romm_notify_or_queue(key, String.chr(_ICON_CHECK), "Installed", _ROMM_DWELL_OK)
	else:
		_romm_notify_or_queue(key, String.chr(_ICON_ERROR),
			error if not error.is_empty() else "Install failed", _ROMM_DWELL_FAIL)
	_refresh_bios_view()


func _on_firmware_cancelled(key: String) -> void:
	_bios_job_buttons.erase(key)
	notify_clear(key)
	_refresh_bios_view()


## Re-derive status and redraw, keeping the user where they were.
## Guarded: a rebuild touches the RomM list and the installer, either of which
## can call back into here.
func _refresh_bios_view() -> void:
	if _bios_browser == null or _bios_refreshing:
		return
	_bios_refreshing = true
	var open_sid := _bios_browser.current_systemid()
	_populate_bios_tab()
	if not open_sid.is_empty():
		_bios_browser.open_system(open_sid)
	_bios_refreshing = false


## Rebuild the home grid: one tile per system that has an installed core, badged
## with what that system is still missing. Rescans the cores dir and the system
## dirs on every call, so installing a core or dropping a BIOS in by hand shows
## up without a restart.
func _populate_bios_tab() -> void:
	if not _bios_browser:
		return

	# Dropped in by hand or by the web uploader since the last look — the whole
	# point of the tab is that it reflects the disk, so nothing survives a rebuild.
	_bios_row_cache.clear()
	_bios_cores_by_system = FirmwareRequirements.installed_cores_by_system()

	# One request per session, and the grid does not wait for it — `listed`
	# redraws when it lands.
	if romm_firmware != null and romm_config != null and romm_config.is_configured():
		romm_firmware.refresh()

	var systems: Array = []
	for sid: String in _bios_cores_by_system:
		var rows: Array[Dictionary] = []
		for c: Dictionary in _bios_cores_by_system[sid]:
			rows.append_array(_bios_rows_for_core(str(c["core_name"])))
		# A core with nothing to declare is not "complete", it is silent — no
		# tile, so the grid only shows systems where there is something to know.
		if rows.is_empty():
			continue
		systems.append({
			"systemid": sid,
			"name": core_db.get_systemname_for_id(sid) if sid != "unknown" else "Other",
			"badge": str(FirmwareState.summarise(rows)["badge"]),
		})

	_bios_browser.set_systems(systems)


## Resolved status rows for one core, memoised for the life of this rebuild.
func _bios_rows_for_core(core_name: String) -> Array[Dictionary]:
	if _bios_row_cache.has(core_name):
		return _bios_row_cache[core_name]
	var rows := FirmwareState.shared().evaluate(
		core_name, FirmwareRequirements.for_core(core_name))
	# Carried on the row so a detail row knows which core's system dir it is
	# talking about without the builder having to be told separately.
	for r: Dictionary in rows:
		r["core_name"] = core_name
	_bios_row_cache[core_name] = rows
	return rows


## Detail page: every declared file for every installed core of this system.
## Grouped by core, with the heading shown only when there is more than one —
## the requirements genuinely differ between cores for the same machine.
func _populate_bios_detail(systemid: String, vbox: VBoxContainer) -> void:
	var cores: Array = _bios_cores_by_system.get(systemid, [])
	var multi := cores.size() > 1

	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Files go in:  %s" % CoreDownloadManager.default_system_dir("<core>")
	path_lbl.add_theme_font_size_override("font_size", 14)
	path_lbl.add_theme_color_override("font_color", COLOR_DESC)
	path_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(path_lbl)
	vbox.add_child(path_row)
	vbox.add_child(HSeparator.new())

	for entry: Dictionary in cores:
		var cn: String = entry["core_name"]
		var rows := _bios_rows_for_core(cn)
		if rows.is_empty():
			continue

		if multi:
			var head := Label.new()
			head.text = str(entry["display_name"])
			head.add_theme_font_size_override("font_size", 20)
			head.add_theme_color_override("font_color", COLOR_TITLE)
			vbox.add_child(head)

		if SystemAssetCatalog.has_archive(cn):
			vbox.add_child(_build_bios_archive_row(cn, rows))

		for r: Dictionary in rows:
			vbox.add_child(_build_bios_row(r))

		vbox.add_child(HSeparator.new())


## The one-tap route for cores whose support files libretro redistributes.
## An archive unpacks straight over the declared paths, so it fills in every row
## it covers at once — for ScummVM that is all 39.
func _build_bios_archive_row(core_name: String, rows: Array[Dictionary]) -> Control:
	var key := "bios:zip:%s" % core_name

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 60)

	var lbl := Label.new()
	lbl.text = SystemAssetCatalog.button_label(core_name)
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)

	var running := _firmware_installer != null and _firmware_installer.is_queued(key)

	# "Every row present" is not a usable test for whether the archive ran:
	# Dolphin.zip carries one of the four files dolphin declares and never the
	# three GameCube IPL dumps, so it can never reach zero outstanding. The
	# recorded install is what makes those cases readable; the zero-outstanding
	# case still counts, so a tree that predates this feature reads correctly.
	var outstanding := 0
	for r: Dictionary in rows:
		if int(r.get("status", 0)) != FirmwareState.Status.PRESENT:
			outstanding += 1
	var installed := SystemAssetCatalog.is_installed(core_name) or outstanding == 0

	if installed and not running:
		var done := Label.new()
		done.text = "Installed"
		done.add_theme_font_size_override("font_size", 15)
		done.add_theme_color_override("font_color", _TINT_OK)
		done.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(done)

	var btn := Button.new()
	btn.add_theme_font_override("font", _symbols())
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(120, 52)
	if running:
		btn.text = String.chr(_ICON_BUSY)
		btn.add_theme_color_override("font_color", _TINT_BUSY)
		btn.tooltip_text = "Downloading — press to cancel"
	elif installed:
		# Still pressable: re-running the archive is how you repair a file that
		# went bad, so the affordance stays and only its reading changes.
		btn.text = String.chr(_ICON_RETRY)
		btn.add_theme_color_override("font_color", _TINT_MUTED)
		btn.tooltip_text = "Already installed — download again to replace these files"
	else:
		btn.text = String.chr(_ICON_DOWNLOAD)
		btn.add_theme_color_override("font_color", _TINT_DOWNLOAD)
		btn.tooltip_text = "Download and unpack into this core's system folder"
	btn.pressed.connect(func() -> void:
		if _firmware_installer == null:
			return
		if _firmware_installer.is_queued(key):
			_firmware_installer.cancel_current()
			return
		_bios_job_buttons[key] = btn
		_firmware_installer.enqueue_archive(key, core_name)
		btn.text = "0%"
		btn.add_theme_color_override("font_color", _TINT_BUSY)
	)
	row.add_child(btn)

	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## One firmware row: status glyph, path, description, and an Optional tag.
func _build_bios_row(r: Dictionary) -> Control:
	var status := int(r.get("status", FirmwareState.Status.PRESENT))
	var optional: bool = bool(r.get("optional", true))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)

	var glyph := Label.new()
	glyph.add_theme_font_override("font", _symbols())
	glyph.add_theme_font_size_override("font_size", 26)
	glyph.custom_minimum_size = Vector2(40, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match status:
		FirmwareState.Status.PRESENT:
			glyph.text = String.chr(_ICON_CHECK)
			glyph.add_theme_color_override("font_color", _TINT_OK)
		FirmwareState.Status.MISMATCH:
			glyph.text = String.chr(_ICON_ERROR)
			glyph.add_theme_color_override("font_color", _TINT_WARN)
		FirmwareState.Status.MISSING_REQUIRED:
			glyph.text = String.chr(_ICON_CROSS)
			glyph.add_theme_color_override("font_color", _TINT_DELETE)
		_:
			glyph.text = String.chr(_ICON_DASH)
			glyph.add_theme_color_override("font_color", _TINT_MUTED)
	row.add_child(glyph)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 0)
	row.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = str(r.get("path", ""))
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color",
		COLOR_TITLE if status != FirmwareState.Status.MISSING_OPTIONAL else COLOR_LICENSE)
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name_lbl)

	var desc := _bios_desc_for(str(r.get("path", "")), str(r.get("desc", "")))
	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.add_theme_font_size_override("font_size", 15)
		desc_lbl.add_theme_color_override("font_color", COLOR_DESC)
		desc_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(desc_lbl)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 15)
	tag.custom_minimum_size = Vector2(170, 0)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if status == FirmwareState.Status.MISMATCH:
		tag.text = "Wrong file"
		tag.add_theme_color_override("font_color", _TINT_WARN)
	elif optional:
		tag.text = "Optional"
		tag.add_theme_color_override("font_color", _TINT_MUTED)
	else:
		tag.text = "Required"
		tag.add_theme_color_override("font_color",
			_TINT_DELETE if status == FirmwareState.Status.MISSING_REQUIRED else COLOR_LICENSE)
	row.add_child(tag)

	row.add_child(_build_bios_action(r))

	# The detail list scrolls, and its scrollbar is 40 px wide and drawn over the
	# content — without this the tag sits underneath it.
	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## The right-hand cell of a firmware row.
##
## A cloud button when RomM is holding this file, and otherwise a plain note
## saying so — most declared BIOSes are console dumps no server redistributes,
## and a dead button on every one of them would read as broken.
func _build_bios_action(r: Dictionary) -> Control:
	var status := int(r.get("status", FirmwareState.Status.PRESENT))
	var path := str(r.get("path", ""))

	var cell := HBoxContainer.new()
	cell.custom_minimum_size = Vector2(230, 0)
	cell.alignment = BoxContainer.ALIGNMENT_END
	cell.add_theme_constant_override("separation", 10)

	if status == FirmwareState.Status.PRESENT or bool(r.get("is_dir", false)):
		return cell

	var hit: Dictionary = romm_firmware.find(path) if romm_firmware != null else {}
	if hit.is_empty():
		var note := Label.new()
		note.text = "Not on RomM" if _romm_ready() else ""
		note.add_theme_font_size_override("font_size", 14)
		note.add_theme_color_override("font_color", _TINT_MUTED)
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_child(note)
		return cell

	var core_name := str(r.get("core_name", ""))
	var key := "bios:file:%s:%s" % [core_name, path]
	var running := _firmware_installer != null and _firmware_installer.is_queued(key)

	# The mark says WHERE the file is coming from; the cloud says what pressing
	# it does. The rows beside it read "Not on RomM" as words, so the source
	# needs to be as legible as the absence of one.
	var mark := _romm_mark()
	if mark != null:
		var mark_rect := TextureRect.new()
		mark_rect.texture = mark
		mark_rect.custom_minimum_size = Vector2(30, 30)
		mark_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark_rect.tooltip_text = "On your RomM server"
		cell.add_child(mark_rect)

	var btn := Button.new()
	btn.add_theme_font_override("font", _symbols())
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(110, 48)
	btn.text = String.chr(_ICON_BUSY if running else _ICON_DOWNLOAD)
	btn.add_theme_color_override("font_color", _TINT_BUSY if running else _TINT_DOWNLOAD)
	btn.tooltip_text = "Download %s from RomM (%s)" % [
		str(hit["file_name"]), String.humanize_size(int(hit["size"]))]
	btn.pressed.connect(func() -> void:
		if _firmware_installer == null:
			return
		if _firmware_installer.is_queued(key):
			_firmware_installer.cancel_current()
			return
		_bios_job_buttons[key] = btn
		# One download, written to every installed core that declares this same
		# file — the system dir is per-core, so they each need their own copy.
		var dests := _bios_destinations_for(path)
		_firmware_installer.enqueue_file(
			key, path.get_file(), romm_config.base_url,
			RommFirmware.content_path(int(hit["id"]), str(hit["file_name"])),
			romm_config.auth_headers(), dests,
			int(hit["size"]), str(hit["md5"]))
		btn.text = "0%"
		btn.add_theme_color_override("font_color", _TINT_BUSY)
	)
	cell.add_child(btn)
	return cell


## Every installed core that declares this exact firmware path wants its own
## copy, so one fetch fills them all.
func _bios_destinations_for(path: String) -> Array[String]:
	var dests: Array[String] = []
	for sid: String in _bios_cores_by_system:
		for c: Dictionary in _bios_cores_by_system[sid]:
			var cn := str(c["core_name"])
			for req: Dictionary in FirmwareRequirements.for_core(cn):
				if str(req["path"]) == path:
					dests.append(FirmwareRequirements.destination(cn, path))
					break
	return dests


func _romm_ready() -> bool:
	return romm_firmware != null and romm_firmware.is_loaded()


## The .info `desc` almost always restates the filename before adding anything
## useful ("scph5500.bin (PS1 JP BIOS)"), which reads as a stutter under a label
## that is already the path. Drop the repeated part and keep the rest.
static func _bios_desc_for(path: String, desc: String) -> String:
	if desc.is_empty():
		return ""
	var rest := desc
	for prefix: String in [path, path.get_file()]:
		if not prefix.is_empty() and rest.begins_with(prefix):
			rest = rest.substr(prefix.length())
			break
	rest = rest.strip_edges().lstrip("-–—:").strip_edges()
	if rest.begins_with("(") and rest.ends_with(")"):
		rest = rest.substr(1, rest.length() - 2).strip_edges()
	# Nothing left means the desc was only ever the filename.
	return "" if rest == path or rest == path.get_file() else rest


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

	# Drill-down browser: pick a system, then see its cores.
	_download_browser = SystemGridBrowser.new()
	_download_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_download_browser.empty_text = "No cores available."
	_download_browser.set_detail_populator(_populate_download_detail)
	_download_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_download_browser)

	return outer


func _start_fetch() -> void:
	_download_loading_label.text = "Fetching core list from buildbot..."
	_download_loading_label.visible = true
	_download_widgets.clear()
	download_manager.fetch_available_cores(_on_cores_fetched)


func _on_cores_fetched(cores: Array) -> void:
	_download_loading_label.visible = false
	if cores.is_empty():
		_download_loading_label.text = "Failed to fetch core list. Check your connection."
		_download_loading_label.visible = true
		return
	# Group the flat buildbot list by system; cores unknown to the DB go in a
	# single "Other" bucket. SystemFilter keeps non-console systems out of the
	# grid — see _refresh_download_systems.
	_download_cores_by_system.clear()
	for entry: Dictionary in cores:
		var core_name: String   = entry["core_name"]
		var remote_date: String = entry["remote_date"]
		var info: Dictionary    = core_db.get_by_core_name(core_name)
		var sid: String = info.get("systemid", "") if not info.is_empty() else ""
		if sid.is_empty():
			sid = "__other__"
		if not _download_cores_by_system.has(sid):
			_download_cores_by_system[sid] = []
		(_download_cores_by_system[sid] as Array).append(
			{"core_name": core_name, "remote_date": remote_date, "info": info})
	_refresh_download_systems()


## Build the Download home grid from the grouped fetch results.
func _refresh_download_systems() -> void:
	if not _download_browser:
		return
	var systems: Array = []
	for sid: String in _download_cores_by_system:
		if SystemFilter.is_hidden(sid):
			continue
		var arr: Array = _download_cores_by_system[sid] as Array
		var name := "Other / Uncategorized" if sid == "__other__" else core_db.get_systemname_for_id(sid)
		var n := arr.size()
		systems.append({"systemid": sid, "name": name,
			"badge": "%d core%s" % [n, "" if n == 1 else "s"]})
	_download_browser.set_systems(systems)


## Detail page for one system: its downloadable cores (built lazily on open).
func _populate_download_detail(systemid: String, vbox: VBoxContainer) -> void:
	var arr: Array = _download_cores_by_system.get(systemid, [])
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var an: String = a["info"].get("display_name", a["core_name"]) if not (a["info"] as Dictionary).is_empty() else a["core_name"]
		var bn: String = b["info"].get("display_name", b["core_name"]) if not (b["info"] as Dictionary).is_empty() else b["core_name"]
		return an.naturalnocasecmp_to(bn) < 0
	)
	arr = CoreRecommendations.first(systemid, arr)
	for e: Dictionary in arr:
		vbox.add_child(_build_core_entry(e["core_name"], e["remote_date"], e["info"]))
	vbox.add_child(_spacer(20))


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

	if CoreRecommendations.is_recommended(str(info.get("systemid", "")), core_name):
		left.add_child(_recommended_badge(13))

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
		# The row can be freed if the user navigates away mid-download (detail
		# pages are built lazily), so guard the captured widgets.
		func(fraction: float):
			if is_instance_valid(bar):
				bar.value = fraction,
		func(success: bool, err_msg: String):
			if is_instance_valid(bar):
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
			if is_instance_valid(btn):
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

	if _is_vr_mode():
		# Turn Style option (XR only)
		var turn_opt := VRDropdown.create("Turn Style",
			[["SNAP", "SNAP"], ["SMOOTH", "SMOOTH"]], "SNAP",
			1, Vector2(220, 56), 22)
		turn_opt.item_selected.connect(func(id: Variant) -> void:
			turn_style_changed.emit(str(id))
		)
		vbox.add_child(turn_opt)

		# Snap Turn Angle option (XR only)
		var sa_opt := VRDropdown.create("Snap Angle",
			[["30°", 30.0], ["45°", 45.0], ["60°", 60.0]], 45.0,
			1, Vector2(140, 56), 22)
		sa_opt.item_selected.connect(func(id: Variant) -> void:
			snap_angle_changed.emit(float(id))
		)
		vbox.add_child(sa_opt)

		vbox.add_child(HSeparator.new())
	else:
		# FOV slider (desktop only)
		var fov_header := HBoxContainer.new()
		fov_header.add_theme_constant_override("separation", 10)
		vbox.add_child(fov_header)

		var fov_lbl := Label.new()
		fov_lbl.text = "Field of View"
		fov_lbl.add_theme_font_size_override("font_size", 22)
		fov_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		fov_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fov_header.add_child(fov_lbl)

		var fov_val := Label.new()
		fov_val.text = "75°"
		fov_val.add_theme_font_size_override("font_size", 20)
		fov_val.add_theme_color_override("font_color", COLOR_LICENSE)
		fov_val.custom_minimum_size = Vector2(60, 0)
		fov_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		fov_header.add_child(fov_val)

		var fov_slider := HSlider.new()
		fov_slider.min_value = 60.0
		fov_slider.max_value = 110.0
		fov_slider.step = 1.0
		fov_slider.value = 75.0
		fov_slider.custom_minimum_size = Vector2(0, 48)
		fov_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(fov_slider)

		fov_slider.value_changed.connect(func(v: float) -> void:
			fov_val.text = "%d°" % int(v)
			fov_changed.emit(v)
		)

		vbox.add_child(HSeparator.new())

	# Height Offset slider
	var ho_header := HBoxContainer.new()
	ho_header.add_theme_constant_override("separation", 10)
	vbox.add_child(ho_header)

	var ho_lbl := Label.new()
	ho_lbl.text = "Height Offset"
	ho_lbl.add_theme_font_size_override("font_size", 22)
	ho_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	ho_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ho_header.add_child(ho_lbl)

	var ho_val := Label.new()
	ho_val.text = "0.00 m"
	ho_val.add_theme_font_size_override("font_size", 20)
	ho_val.add_theme_color_override("font_color", COLOR_LICENSE)
	ho_val.custom_minimum_size = Vector2(80, 0)
	ho_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ho_header.add_child(ho_val)

	var ho_slider := HSlider.new()
	ho_slider.min_value = -1.0
	ho_slider.max_value = 1.0
	ho_slider.step = 0.01
	ho_slider.value = 0.0
	ho_slider.custom_minimum_size = Vector2(0, 48)
	ho_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ho_slider.add_theme_constant_override("grabber_offset", 0)
	vbox.add_child(ho_slider)

	ho_slider.value_changed.connect(func(v: float) -> void:
		ho_val.text = "%+.2f m" % v
		height_offset_changed.emit(v)
	)

	vbox.add_child(HSeparator.new())

	# World Scale slider — below 1.0 makes you feel smaller and the room bigger.
	# XR only, like Turn Style above: on desktop it only moves the eye height,
	# which is what the Height Offset slider already does more directly.
	if _is_vr_mode():
		var ws_header := HBoxContainer.new()
		ws_header.add_theme_constant_override("separation", 10)
		vbox.add_child(ws_header)

		var ws_lbl := Label.new()
		ws_lbl.text = "World Scale"
		ws_lbl.add_theme_font_size_override("font_size", 22)
		ws_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		ws_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ws_header.add_child(ws_lbl)

		var ws_val := Label.new()
		ws_val.add_theme_font_size_override("font_size", 20)
		ws_val.add_theme_color_override("font_color", COLOR_LICENSE)
		ws_val.custom_minimum_size = Vector2(80, 0)
		ws_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ws_header.add_child(ws_val)

		var ws_slider := HSlider.new()
		ws_slider.min_value = 0.4
		ws_slider.max_value = 1.5
		ws_slider.step = 0.05
		# Default matches DEFAULT_WORLD_SCALE in spawn_menu_controller.gd (applied
		# at startup). Hardcoded rather than read from XRServer.world_scale because
		# this view is built before the controller's deferred setup applies it.
		ws_slider.value = 0.8
		ws_val.text = "%.2f×" % ws_slider.value
		ws_slider.custom_minimum_size = Vector2(0, 48)
		ws_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(ws_slider)

		ws_slider.value_changed.connect(func(v: float) -> void:
			ws_val.text = "%.2f×" % v
			world_scale_changed.emit(v)
		)

		# Passthrough pins the scale to 1.0 so the virtual room stays registered
		# with the real one. Shown as such rather than left live and inert.
		var sm_ws := _get_scene_manager()
		if sm_ws and sm_ws.current_scene_id == "passthrough":
			ws_slider.value = 1.0
			ws_slider.editable = false
			ws_val.text = "1.00× (passthrough)"

		# Inside the guard too, or hiding the slider leaves two rules stacked.
		vbox.add_child(HSeparator.new())

	# Auto-save scene on switch option
	var as_row := HBoxContainer.new()
	as_row.add_theme_constant_override("separation", 10)
	as_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(as_row)

	var as_lbl := Label.new()
	as_lbl.text = "Auto-save Scene"
	as_lbl.add_theme_font_size_override("font_size", 22)
	as_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	as_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	as_row.add_child(as_lbl)

	as_row.add_child(_make_toggle(AppPrefs.auto_save_scene, func(on: bool) -> void:
		AppPrefs.auto_save_scene = on
		AppPrefs.save_prefs()
		auto_save_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# Show FPS option
	var fps_row := HBoxContainer.new()
	fps_row.add_theme_constant_override("separation", 10)
	fps_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(fps_row)

	var fps_lbl := Label.new()
	fps_lbl.text = "Show FPS"
	fps_lbl.add_theme_font_size_override("font_size", 22)
	fps_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	fps_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_row.add_child(fps_lbl)

	fps_row.add_child(_make_toggle(AppPrefs.show_fps, func(on: bool) -> void:
		AppPrefs.show_fps = on
		AppPrefs.save_prefs()
		show_fps_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# Spatial audio backend. Desktop only: in a headset the SDK's binaural
	# rendering is simply right, and offering the swap there would only be a way
	# to make it worse. On a desk it is a real choice -- over speakers the HRTF
	# fights the room, and a surround rig gets no centre channel from a renderer
	# that produces two channels by design.
	if QualityManager.is_desktop():
		var spatial_row := HBoxContainer.new()
		spatial_row.add_theme_constant_override("separation", 10)
		spatial_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(spatial_row)

		var spatial_lbl := Label.new()
		spatial_lbl.text = "Meta XR Spatial Audio"
		spatial_lbl.add_theme_font_size_override("font_size", 22)
		spatial_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		spatial_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spatial_row.add_child(spatial_lbl)

		# Applied straight away for everything in the room. A system that is
		# already switched on keeps the backend it booted with; see
		# SpatialAudioListener.set_sdk_enabled.
		spatial_row.add_child(_make_toggle(AppPrefs.spatial_audio_sdk, func(on: bool) -> void:
			AppPrefs.spatial_audio_sdk = on
			AppPrefs.save_prefs()
			SpatialAudioListener.set_sdk_enabled(on)
		))

		vbox.add_child(HSeparator.new())

	# Ray Gun crosshair option
	var xhair_row := HBoxContainer.new()
	xhair_row.add_theme_constant_override("separation", 10)
	xhair_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(xhair_row)

	var xhair_lbl := Label.new()
	xhair_lbl.text = "Ray Gun Crosshair"
	xhair_lbl.add_theme_font_size_override("font_size", 22)
	xhair_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	xhair_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xhair_row.add_child(xhair_lbl)

	xhair_row.add_child(_make_toggle(AppPrefs.aim_crosshair, func(on: bool) -> void:
		AppPrefs.aim_crosshair = on
		AppPrefs.save_prefs()
		aim_crosshair_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# Hint popups over held devices (drop combo, Scroll Lock capture)
	var hints_row := HBoxContainer.new()
	hints_row.add_theme_constant_override("separation", 10)
	hints_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(hints_row)

	var hints_lbl := Label.new()
	hints_lbl.text = "Held Device Hints"
	hints_lbl.add_theme_font_size_override("font_size", 22)
	hints_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	hints_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints_row.add_child(hints_lbl)

	# No signal: HeldHint reads AppPrefs when the object is picked up, so nothing
	# has to be told. Clearing the counts is what makes re-enabling visible —
	# without it anyone already past HeldHint.LEARNED_AFTER sees no change.
	hints_row.add_child(_make_toggle(AppPrefs.show_hints, func(on: bool) -> void:
		AppPrefs.show_hints = on
		if on:
			AppPrefs.hint_uses.clear()
		AppPrefs.save_prefs()
	))

	vbox.add_child(HSeparator.new())

	# Draw hands on held controllers option (default off)
	var hands_row := HBoxContainer.new()
	hands_row.add_theme_constant_override("separation", 10)
	hands_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(hands_row)

	var hands_lbl := Label.new()
	hands_lbl.text = "Controller Hands"
	hands_lbl.add_theme_font_size_override("font_size", 22)
	hands_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	hands_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hands_row.add_child(hands_lbl)

	hands_row.add_child(_make_toggle(AppPrefs.controller_hands, func(on: bool) -> void:
		AppPrefs.controller_hands = on
		AppPrefs.save_prefs()
		controller_hands_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# System Filter option — off shows the media players, test core and
	# single-game cores that SystemFilter keeps out of the Download grid.
	var sf_row := HBoxContainer.new()
	sf_row.add_theme_constant_override("separation", 10)
	sf_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(sf_row)

	var sf_col := VBoxContainer.new()
	sf_col.add_theme_constant_override("separation", 0)
	sf_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sf_row.add_child(sf_col)

	var sf_lbl := Label.new()
	sf_lbl.text = "Libretro System Filter"
	sf_lbl.add_theme_font_size_override("font_size", 22)
	sf_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	sf_col.add_child(sf_lbl)

	var sf_sub := Label.new()
	sf_sub.text = "Hide %d non-console systems" % SystemFilter.hidden_ids().size()
	sf_sub.add_theme_font_size_override("font_size", 16)
	sf_sub.add_theme_color_override("font_color", COLOR_LICENSE)
	sf_col.add_child(sf_sub)

	sf_row.add_child(_make_toggle(AppPrefs.system_filter, func(on: bool) -> void:
		AppPrefs.system_filter = on
		AppPrefs.save_prefs()
		SystemFilter.enabled = on
		_refresh_download_systems()
	))

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

		var fs_toggle := _make_toggle(scraper_config.web_server_enabled, func(on: bool) -> void:
			if on:
				web_server.start()
			else:
				web_server.stop()
			scraper_config.web_server_enabled = on
			scraper_config.save_config()
			_server_address_label.visible = on
		)
		fs_row.add_child(fs_toggle)

		_server_address_label = Label.new()
		_server_address_label.add_theme_font_size_override("font_size", 16)
		_server_address_label.add_theme_color_override("font_color", COLOR_DESC)
		_server_address_label.text = "http://%s:8080   PIN: %s" % \
			[WebFileServer.local_ip(), scraper_config.ensure_web_server_pin()]
		_server_address_label.visible = scraper_config.web_server_enabled
		vbox.add_child(_server_address_label)

		vbox.add_child(HSeparator.new())

	# ── RomM server ──────────────────────────────────────────────────────────
	_build_romm_options(vbox)

	# ── Scraper settings ─────────────────────────────────────────────────────
	var scraper_hdr := Label.new()
	scraper_hdr.text = "SCREENSCRAPER.FR"
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


## ROMM SERVER section of the OPTIONS view.
func _build_romm_options(vbox: VBoxContainer) -> void:
	var hdr := Label.new()
	hdr.text = "ROMM SERVER"
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(hdr)

	var enable_row := HBoxContainer.new()
	enable_row.custom_minimum_size = Vector2(0, 68)
	enable_row.add_theme_constant_override("separation", 10)
	vbox.add_child(enable_row)

	var enable_lbl := Label.new()
	enable_lbl.text = "Enable RomM library"
	enable_lbl.add_theme_font_size_override("font_size", 20)
	enable_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	enable_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enable_row.add_child(enable_lbl)

	enable_row.add_child(_make_toggle(romm_config.enabled, func(on: bool) -> void:
		romm_config.enabled = on
		romm_config.save_config()
		if on:
			_romm_fetch_platforms()
	))

	_add_options_text_field(vbox, "Server URL", romm_config.base_url, func(text: String) -> void:
		romm_config.base_url = RommConfig.normalize_url(text)
		romm_config.save_config()
		if romm_art != null:
			romm_art.setup(romm_config.base_url)
	)

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	var mode_drop := VRDropdown.create("Sign in with",
		[["API token", RommConfig.AUTH_TOKEN],
		 ["Username + password", RommConfig.AUTH_BASIC]],
		romm_config.auth_mode, 1, Vector2(300, 56), 18)
	mode_drop.item_selected.connect(func(id: Variant) -> void:
		romm_config.auth_mode = str(id)
		romm_config.save_config()
	)
	vbox.add_child(mode_drop)

	_add_options_text_field(vbox, "API token", romm_config.token, func(text: String) -> void:
		romm_config.token = text.strip_edges()
		romm_config.save_config()
	, true)

	_add_options_text_field(vbox, "Username", romm_config.username, func(text: String) -> void:
		romm_config.username = text.strip_edges()
		romm_config.save_config()
	)

	_add_options_text_field(vbox, "Password", romm_config.password, func(text: String) -> void:
		romm_config.password = text
		romm_config.save_config()
	, true)

	# Device pairing: type 8 digits instead of a 68-character token in VR.
	_add_options_text_field(vbox, "Pair code (8 digits)", "", func(text: String) -> void:
		var code := text.strip_edges()
		if code.length() != 8:
			return
		romm_client.pair_with_code(code, func(ok: bool, token: String, err: String) -> void:
			if ok:
				romm_config.auth_mode = RommConfig.AUTH_TOKEN
				romm_config.token = token
				romm_config.enabled = true
				romm_config.save_config()
				notify("romm:conn", "✅", "Paired with RomM", -1.0, _ROMM_DWELL_OK)
				_romm_fetch_platforms()
			else:
				notify("romm:conn", "❌", err, -1.0, _ROMM_DWELL_FAIL)
		)
	)

	_add_options_text_field(vbox, "Cache budget (GB)", str(romm_config.cache_budget_gb),
		func(text: String) -> void:
			var v := text.strip_edges().to_float()
			if v > 0.0:
				romm_config.cache_budget_gb = v
				romm_config.save_config()
				_update_romm_status_label()
	)

	var group_row := HBoxContainer.new()
	group_row.custom_minimum_size = Vector2(0, 68)
	group_row.add_theme_constant_override("separation", 10)
	vbox.add_child(group_row)
	var group_lbl := Label.new()
	group_lbl.text = "Group multi-region duplicates"
	group_lbl.add_theme_font_size_override("font_size", 20)
	group_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	group_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group_row.add_child(group_lbl)
	group_row.add_child(_make_toggle(romm_config.group_by_meta_id, func(on: bool) -> void:
		romm_config.group_by_meta_id = on
		romm_config.save_config()
	))

	# Actions
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)

	var test_btn := Button.new()
	test_btn.text = "  Test connection  "
	test_btn.custom_minimum_size = Vector2(0, 56)
	test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_btn.add_theme_font_size_override("font_size", 18)
	test_btn.pressed.connect(func() -> void:
		notify("romm:conn", "⏳", "Contacting RomM…", -1.0)
		romm_client.test_connection(func(ok: bool, summary: String) -> void:
			notify("romm:conn", "✅" if ok else "❌", summary, -1.0,
				_ROMM_DWELL_OK if ok else _ROMM_DWELL_FAIL)
			if ok:
				_romm_fetch_platforms()
		)
	)
	actions.add_child(test_btn)

	var sync_btn := Button.new()
	sync_btn.text = "  Sync all now  "
	sync_btn.custom_minimum_size = Vector2(0, 56)
	sync_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_btn.add_theme_font_size_override("font_size", 18)
	sync_btn.pressed.connect(_on_romm_sync_all_pressed)
	actions.add_child(sync_btn)

	_romm_status_label = Label.new()
	_romm_status_label.add_theme_font_size_override("font_size", 16)
	_romm_status_label.add_theme_color_override("font_color", COLOR_DESC)
	_romm_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_romm_status_label)
	_update_romm_status_label()

	vbox.add_child(HSeparator.new())


## Sync every mapped platform, one after another — for deliberate offline
## browsing. Normal use never needs this; platforms sync when you open them.
func _on_romm_sync_all_pressed() -> void:
	if not romm_config.is_configured():
		notify("romm:conn", "❌", "Set a server URL and sign-in first", -1.0, _ROMM_DWELL_FAIL)
		return
	if _romm_platforms.is_empty():
		_romm_fetch_platforms()
		return
	_romm_sync_queue.clear()
	for systemid: String in _romm_platforms:
		_romm_sync_queue.append(systemid)
	_pump_romm_sync_queue()


func _pump_romm_sync_queue() -> void:
	if _romm_sync_queue.is_empty() or romm_catalog.is_syncing():
		return
	var systemid: String = _romm_sync_queue.pop_front()
	var pid := int((_romm_platforms.get(systemid, {}) as Dictionary).get("id", 0))
	if pid > 0:
		romm_catalog.sync_platform(systemid, pid, true)


func _update_romm_status_label() -> void:
	if _romm_status_label == null or not is_instance_valid(_romm_status_label):
		return

	var parts: Array[String] = []
	if not romm_client.server_version.is_empty():
		parts.append("RomM %s" % romm_client.server_version)
	if not _romm_platforms.is_empty():
		var total := 0
		for sid: String in _romm_platforms:
			total += int((_romm_platforms[sid] as Dictionary).get("rom_count", 0))
		parts.append("%d games across %d platforms" % [total, _romm_platforms.size()])
	if romm_cache != null:
		parts.append("%s cached / %.0f GB budget"
			% [_human_bytes(romm_cache.total_bytes()), romm_config.cache_budget_gb])

	var text := " · ".join(PackedStringArray(parts)) if not parts.is_empty() \
		else "Not connected."

	if not _romm_unmapped.is_empty():
		# Biggest first, capped — a full list runs to dozens of engine cores and
		# one-ROM oddities that will never have a systemid.
		var sorted_un := _romm_unmapped.duplicate()
		sorted_un.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("rom_count", 0)) > int(b.get("rom_count", 0))
		)
		var names: Array[String] = []
		for i in mini(sorted_un.size(), 6):
			var p: Dictionary = sorted_un[i]
			names.append("%s (%d)" % [RommPlatforms.display_name(p), int(p.get("rom_count", 0))])
		text += "\n%d unmapped: " % _romm_unmapped.size() + ", ".join(PackedStringArray(names))
		if sorted_un.size() > 6:
			text += " and %d more" % (sorted_un.size() - 6)

	_romm_status_label.text = text


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

	# Keyboard dismissal is handled globally by the VRKeyboard autoload.
	edit.text_submitted.connect(func(text: String) -> void: on_changed.call(text))
	edit.focus_exited.connect(func() -> void: on_changed.call(edit.text))

	row.add_child(edit)


# ── Controls remapping view ───────────────────────────────────────────────────

## Close the named inline dropdown.
func _close_dropdown(k: String) -> void:
	var drop := _controls_opts.get(k) as VRDropdown
	if drop:
		drop.close()


## Update an inline dropdown to reflect a new selection without reopening it.
func _reset_vr_dropdown(k: String, new_id: Variant) -> void:
	var drop := _controls_opts.get(k) as VRDropdown
	if drop:
		drop.select_id(new_id)


## Build a label + inline-expandable dropdown row. Thin wrapper over VRDropdown,
## which is shared with the core/TV/DVD panels — see vr_dropdown.gd for why an
## OptionButton cannot be used inside a VR viewport panel.
## options: Array of [display_name, id] where id is int or String.
func _make_vr_dropdown_row(
		key: String,
		label_text: String,
		options: Array,
		current_id: Variant,
		on_changed: Callable,
		grid_cols: int = 1
) -> VBoxContainer:
	var drop := VRDropdown.create(label_text, options, current_id,
		grid_cols, Vector2(220, 52), 20)
	drop.item_selected.connect(func(id: Variant) -> void: on_changed.call(id))
	_controls_opts[key] = drop
	return drop


func _build_controls_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_controls_scroll = scroll

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)

	vbox.add_child(_spacer(10))
	_build_controls_section(vbox)
	vbox.add_child(_spacer(10))

	return scroll


# ── Controls remapping ────────────────────────────────────────────────────────

## Joypad button target choices: [display_name, bit_index].
const _JOYPAD_OPTIONS: Array = [
	["None",    -1],
	["B",        0], ["Y",       1], ["SELECT",  2], ["START",   3],
	["D-Up",     4], ["D-Down",  5], ["D-Left",  6], ["D-Right", 7],
	["A",        8], ["X",       9], ["L",       10], ["R",      11],
	["L2",      12], ["R2",     13], ["L3",      14], ["R3",     15],
]

## Analog stick target choices: [display_name, target_string].
const _STICK_OPTIONS: Array = [
	["Left Analog + D-pad",  "left+dpad"],
	["Left Analog",   "left"],
	["Right Analog + D-pad", "right+dpad"],
	["Right Analog",  "right"],
	["D-pad only",    "dpad"],
]

## Lightgun button target choices: [display_name, button_id].
const _LIGHTGUN_OPTIONS: Array = [
	["None",    -1],
	["Trigger",  2], ["Aux A",   3], ["Aux B",    4], ["Aux C",    5],
	["Start",    6], ["Select",  7],
	["D-Up",     8], ["D-Down",  9], ["D-Left",  10], ["D-Right", 11],
]

## Order in which joypad button sources appear in the Controls UI.
const _BUTTON_SOURCE_ORDER: Array = [
	"right_ax_button", "right_by_button", "right_grip", "right_trigger", "right_primary_click",
	"left_ax_button",  "left_by_button",  "left_grip",  "left_trigger",  "left_primary_click",
]

## Height reserved for the ControllerDiagram: five 56 px rows plus their gaps,
## with room for the art between the columns.
const _CONTROLS_DIAGRAM_H := 520.0

## Order in which lightgun sources appear in the Controls UI.
const _LIGHTGUN_SOURCE_ORDER: Array = [
	"trigger", "grip", "ax_button", "by_button", "primary_click",
]



func _build_controls_section(vbox: VBoxContainer) -> void:
	# ── Header ────────────────────────────────────────────────────────────────
	var hdr := Label.new()
	hdr.text = "CONTROLS"
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(hdr)

	if _is_vr_mode():
		_build_xr_controls(vbox)
	else:
		_build_desktop_controls(vbox)

	# Physical gamepad section — shown in both modes (a real pad works whether
	# the player is in VR or at the desktop). Added unconditionally because it
	# applies regardless of headset/desktop.
	vbox.add_child(HSeparator.new())
	_build_gamepad_controls(vbox)


func _build_xr_controls(vbox: VBoxContainer) -> void:
	# Load current global bindings as the working copy.
	var global := ControllerBindings.get_global()
	_edit_button_map  = global["buttons"].duplicate()
	_edit_stick_map   = global["sticks"].duplicate()
	_edit_lightgun_map = global["lightgun"].duplicate()

	# ── Joypad Buttons ────────────────────────────────────────────────────────
	var btn_hdr := Label.new()
	btn_hdr.text = "XR Joypad Buttons"
	btn_hdr.add_theme_font_size_override("font_size", 18)
	btn_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(btn_hdr)

	# Picture of both controllers with a leader line from each input to its own
	# dropdown, instead of ten unillustrated "Left Grip"-style rows. Its
	# dropdowns register under the same "btn:<src>" keys, so reset still drives
	# them through _reset_vr_dropdown.
	var diagram := ControllerDiagram.new()
	diagram.custom_minimum_size = Vector2(0, _CONTROLS_DIAGRAM_H)
	diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagram.setup(_edit_button_map, _JOYPAD_OPTIONS)
	diagram.binding_changed.connect(func(src: String, bit: int) -> void:
		_edit_button_map[src] = bit
		_apply_xr_bindings())
	vbox.add_child(diagram)

	for src: String in _BUTTON_SOURCE_ORDER:
		_controls_opts["btn:" + src] = diagram.get_dropdown(src)

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var stick_hdr := Label.new()
	stick_hdr.text = "Analog Sticks"
	stick_hdr.add_theme_font_size_override("font_size", 18)
	stick_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(stick_hdr)

	for stick: String in ["stick_left", "stick_right"]:
		var s_label := "Left Stick" if stick == "stick_left" else "Right Stick"
		var def_target := "left+dpad" if stick == "stick_left" else "right"
		var current_target: String = _edit_stick_map.get(stick, def_target)
		var captured_stick := stick
		vbox.add_child(_make_vr_dropdown_row(
			"stick:" + stick, s_label, _STICK_OPTIONS, current_target,
			func(v: Variant) -> void:
				_edit_stick_map[captured_stick] = v as String
				_apply_xr_bindings(),
			3
		))

	# ── Light Gun Buttons ─────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var gun_hdr := Label.new()
	gun_hdr.text = "Light Gun Buttons"
	gun_hdr.add_theme_font_size_override("font_size", 18)
	gun_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(gun_hdr)

	for src: String in _LIGHTGUN_SOURCE_ORDER:
		var label: String = ControllerBindings.LIGHTGUN_SOURCE_LABELS.get(src, src)
		var current_id: int = _edit_lightgun_map.get(src, -1)
		var captured_src := src
		vbox.add_child(_make_vr_dropdown_row(
			"gun:" + src, label, _LIGHTGUN_OPTIONS, current_id,
			func(v: Variant) -> void:
				_edit_lightgun_map[captured_src] = v as int
				_apply_xr_bindings(),
			4
		))

	# Thumbstick mode row
	var stick_label: String = ControllerBindings.LIGHTGUN_SOURCE_LABELS.get("stick", "Thumbstick")
	var cur_stick_mode: String = str(_edit_lightgun_map.get("stick", "dpad"))
	vbox.add_child(_make_vr_dropdown_row(
		"gun:stick", stick_label,
		[["None", "none"], ["D-pad", "dpad"]],
		cur_stick_mode,
		func(v: Variant) -> void:
			_edit_lightgun_map["stick"] = v as String
			_apply_xr_bindings(),
		2
	))

	# ── Action buttons ────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Default"
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_controls_reset)
	action_row.add_child(reset_btn)

	# No Save button any more: every dropdown above applies itself. It used to sit
	# here, at the bottom of a scroll, below the joypad, stick AND lightgun
	# sections — so a rebind looked like it had taken and silently had not.


func _build_desktop_controls(vbox: VBoxContainer) -> void:
	_rebind_buttons.clear()

	# ── Gamepad Buttons ───────────────────────────────────────────────────────
	var btn_hdr := Label.new()
	btn_hdr.text = "Gamepad Buttons"
	btn_hdr.add_theme_font_size_override("font_size", 18)
	btn_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(btn_hdr)

	for action: String in DesktopBindings.JOYPAD_ACTIONS:
		vbox.add_child(_make_rebind_row(action))

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var stick_hdr := Label.new()
	stick_hdr.text = "Analog Sticks"
	stick_hdr.add_theme_font_size_override("font_size", 18)
	stick_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(stick_hdr)

	for action: String in DesktopBindings.ANALOG_ACTIONS:
		vbox.add_child(_make_rebind_row(action))

	# ── Save / Reset ──────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Default"
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_desktop_controls_reset)
	action_row.add_child(reset_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(220, 52)
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(DesktopBindings.save)
	action_row.add_child(save_btn)


## Creates a single rebind row: [Label: action display name] [Button: current key]
func _make_rebind_row(action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 48)

	var lbl := Label.new()
	lbl.text = DesktopBindings.ACTION_LABELS.get(action, action)
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var btn := Button.new()
	btn.text = DesktopBindings.event_display_name(action)
	btn.custom_minimum_size = Vector2(140, 44)
	btn.add_theme_font_size_override("font_size", 18)
	btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	_rebind_buttons[action] = btn

	var captured_action := action
	btn.pressed.connect(func() -> void:
		# Cancel any in-progress rebind first.
		if _rebinding_action != "" and _rebinding_action != captured_action:
			var old_btn: Button = _rebind_buttons.get(_rebinding_action) as Button
			if is_instance_valid(old_btn):
				old_btn.text = DesktopBindings.event_display_name(_rebinding_action)
		_rebinding_action = captured_action
		btn.text = "[ Press a key… ]"
		rebind_started.emit(captured_action)
	)
	row.add_child(btn)
	return row


## Called by spawn_menu_controller after a key/mouse press is captured.
## event is null when the user cancelled with Escape.
func on_rebind_complete(action: String, event: InputEvent) -> void:
	_rebinding_action = ""
	var btn: Button = _rebind_buttons.get(action) as Button
	if not is_instance_valid(btn):
		return
	btn.text = DesktopBindings.event_display_name(action)


func _on_desktop_controls_reset() -> void:
	# Reload project defaults by restoring from project settings.
	InputMap.load_from_project_settings()
	# Refresh all button labels.
	for action: String in _rebind_buttons:
		var btn: Button = _rebind_buttons[action] as Button
		if is_instance_valid(btn):
			btn.text = DesktopBindings.event_display_name(action)


## Write the XR bindings and push them to everything holding a copy. Called from
## every dropdown, so a change is live the moment it is made — which is what a
## dropdown implies, and what the missing Save button used to gate.
func _apply_xr_bindings() -> void:
	ControllerBindings.save_global(_edit_button_map, _edit_stick_map, _edit_lightgun_map)
	controller_bindings_changed.emit()


func _on_controls_reset() -> void:
	_edit_button_map   = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
	_edit_stick_map    = ControllerBindings.DEFAULT_STICK_MAP.duplicate()
	_edit_lightgun_map = ControllerBindings.DEFAULT_LIGHTGUN_MAP.duplicate()
	for src: String in _BUTTON_SOURCE_ORDER:
		_reset_vr_dropdown("btn:" + src, _edit_button_map.get(src, -1))
	for stick: String in ["stick_left", "stick_right"]:
		var def := "left+dpad" if stick == "stick_left" else "right"
		_reset_vr_dropdown("stick:" + stick, _edit_stick_map.get(stick, def))
	for src: String in _LIGHTGUN_SOURCE_ORDER:
		_reset_vr_dropdown("gun:" + src, _edit_lightgun_map.get(src, -1))
	_reset_vr_dropdown("gun:stick", str(_edit_lightgun_map.get("stick", "dpad")))
	_apply_xr_bindings()


# ── Physical gamepad remapping ────────────────────────────────────────────────

func _build_gamepad_controls(vbox: VBoxContainer) -> void:
	_pad_rebind_buttons.clear()
	var pad := GamepadBindings.get_global()
	_edit_pad_button_map = pad["buttons"].duplicate()
	_edit_pad_stick_map  = pad["sticks"].duplicate()

	# ── Header ────────────────────────────────────────────────────────────────
	var hdr := Label.new()
	hdr.text = "GAME CONTROLLER"
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(hdr)

	# ── Connected-pad status line ─────────────────────────────────────────────
	var status := Label.new()
	status.add_theme_font_size_override("font_size", 16)
	status.add_theme_color_override("font_color", COLOR_LICENSE)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status)
	_pad_status_label = status
	_refresh_pad_status()
	if not Input.joy_connection_changed.is_connected(_on_pad_connection_changed):
		Input.joy_connection_changed.connect(_on_pad_connection_changed)

	# ── Diagram ───────────────────────────────────────────────────────────────
	_pad_diagram = GamepadDiagram.new()
	_pad_diagram.custom_minimum_size = Vector2(0, 580)
	_pad_diagram.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_pad_diagram)
	_pad_diagram.setup(_edit_pad_button_map)
	_pad_diagram.binding_changed.connect(_on_pad_diagram_changed)

	# ── Buttons (press-to-rebind; joypad presses reach us in VR and desktop) ──
	# Behind a switch, because the diagram covers it for an Xbox-layout pad. It
	# stays reachable for the ones it cannot: a pad with paddles or extra buttons
	# reports indices the picture has nowhere to point at, and Guide is left off
	# the diagram on purpose.
	var list_row := HBoxContainer.new()
	list_row.add_theme_constant_override("separation", 10)
	list_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(list_row)

	var btn_hdr := Label.new()
	btn_hdr.text = "Button list (for pads the diagram can't show)"
	btn_hdr.add_theme_font_size_override("font_size", 18)
	btn_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	btn_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_row.add_child(btn_hdr)

	var list_box := VBoxContainer.new()
	list_box.visible = false
	vbox.add_child(list_box)
	_pad_list_box = list_box

	list_row.add_child(_make_toggle(false, func(on: bool) -> void:
		if is_instance_valid(_pad_list_box):
			_pad_list_box.visible = on
	))

	for target: String in GamepadBindings.TARGET_ORDER:
		list_box.add_child(_make_pad_rebind_row(target))

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var stick_hdr := Label.new()
	stick_hdr.text = "Analog Sticks"
	stick_hdr.add_theme_font_size_override("font_size", 18)
	stick_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(stick_hdr)

	for stick: String in ["stick_left", "stick_right"]:
		var s_label := "Left Stick" if stick == "stick_left" else "Right Stick"
		var def_target := "left+dpad" if stick == "stick_left" else "right"
		var current_target: String = _edit_pad_stick_map.get(stick, def_target)
		var captured_stick := stick
		vbox.add_child(_make_vr_dropdown_row(
			"padstick:" + stick, s_label, _STICK_OPTIONS, current_target,
			func(v: Variant) -> void:
				_edit_pad_stick_map[captured_stick] = v as String
				_on_pad_controls_save(),
			3
		))

	# ── Action buttons ────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 10)
	action_row.custom_minimum_size = Vector2(0, 60)
	vbox.add_child(action_row)

	var reset_btn := Button.new()
	reset_btn.text = "Reset to Default"
	reset_btn.custom_minimum_size = Vector2(220, 52)
	reset_btn.add_theme_font_size_override("font_size", 18)
	reset_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_pad_controls_reset)
	action_row.add_child(reset_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(220, 52)
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	save_btn.focus_mode = Control.FOCUS_NONE
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_pad_controls_save)
	action_row.add_child(save_btn)


## Creates a single gamepad rebind row: [Label: RetroPad target] [Button: binding].
func _make_pad_rebind_row(target: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 48)

	var lbl := Label.new()
	lbl.text = GamepadBindings.TARGET_LABELS.get(target, target)
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var binding: String = _edit_pad_button_map.get(target, "none")
	var btn := Button.new()
	btn.text = GamepadBindings.binding_display_name(binding)
	btn.custom_minimum_size = Vector2(160, 44)
	btn.add_theme_font_size_override("font_size", 18)
	btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	btn.focus_mode = Control.FOCUS_NONE
	_pad_rebind_buttons[target] = btn

	var captured_target := target
	btn.pressed.connect(func() -> void:
		# Cancel any in-progress pad rebind first.
		if _pad_rebinding_target != "" and _pad_rebinding_target != captured_target:
			var old_btn: Button = _pad_rebind_buttons.get(_pad_rebinding_target) as Button
			if is_instance_valid(old_btn):
				var prev: String = _edit_pad_button_map.get(_pad_rebinding_target, "none")
				old_btn.text = GamepadBindings.binding_display_name(prev)
		_pad_rebinding_target = captured_target
		btn.text = "[ Press gamepad… ]"
		pad_rebind_started.emit(captured_target)
	)
	row.add_child(btn)
	return row


## Called by spawn_menu_controller after a joypad press is captured.
## binding is "" when the user cancelled.
func on_pad_rebind_complete(target: String, binding: String) -> void:
	_pad_rebinding_target = ""
	if binding != "":
		_edit_pad_button_map[target] = binding
		_on_pad_controls_save()
		# The same binding is shown in both places; a capture must move the
		# diagram too or the two disagree until the tab is rebuilt.
		_refresh_pad_diagram()
	var btn: Button = _pad_rebind_buttons.get(target) as Button
	if is_instance_valid(btn):
		var cur: String = _edit_pad_button_map.get(target, "none")
		btn.text = GamepadBindings.binding_display_name(cur)


## The diagram edits input -> target; the stored map is target -> binding. One
## input drives one target, so assigning a target that another input already held
## takes it away from that one, and the diagram is refreshed to show it released.
func _on_pad_diagram_changed(input: String, target: String) -> void:
	var by_input := GamepadDiagram.invert(_edit_pad_button_map)
	if target != "":
		for other: String in by_input.keys():
			if other != input and String(by_input[other]) == target:
				by_input.erase(other)
	by_input[input] = target
	_edit_pad_button_map = GamepadDiagram.to_button_map(by_input)
	_on_pad_controls_save()
	_refresh_pad_diagram()
	_refresh_pad_list()


func _refresh_pad_diagram() -> void:
	if not is_instance_valid(_pad_diagram):
		return
	var by_input := GamepadDiagram.invert(_edit_pad_button_map)
	for key: String in GamepadDiagram.INPUTS:
		_pad_diagram.set_binding(key, String(by_input.get(key, "")))


func _refresh_pad_list() -> void:
	for target: String in GamepadBindings.TARGET_ORDER:
		var btn: Button = _pad_rebind_buttons.get(target) as Button
		if is_instance_valid(btn):
			btn.text = GamepadBindings.binding_display_name(
				_edit_pad_button_map.get(target, "none"))


func _on_pad_controls_reset() -> void:
	_edit_pad_button_map = GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
	_edit_pad_stick_map  = GamepadBindings.DEFAULT_STICK_MAP.duplicate()
	_refresh_pad_diagram()
	for target: String in GamepadBindings.TARGET_ORDER:
		var btn: Button = _pad_rebind_buttons.get(target) as Button
		if is_instance_valid(btn):
			var cur: String = _edit_pad_button_map.get(target, "none")
			btn.text = GamepadBindings.binding_display_name(cur)
	for stick: String in ["stick_left", "stick_right"]:
		var def := "left+dpad" if stick == "stick_left" else "right"
		_reset_vr_dropdown("padstick:" + stick, _edit_pad_stick_map.get(stick, def))


func _on_pad_controls_save() -> void:
	GamepadBindings.save_global(_edit_pad_button_map, _edit_pad_stick_map)
	controller_bindings_changed.emit()


func _refresh_pad_status() -> void:
	if not is_instance_valid(_pad_status_label):
		return
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		_pad_status_label.text = "No gamepad detected — connect one via USB or Bluetooth."
		return
	var names: Array[String] = []
	for device: int in pads:
		names.append(Input.get_joy_name(device))
	_pad_status_label.text = "%d pad(s): %s" % [pads.size(), ", ".join(names)]


func _on_pad_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_pad_status()


# ── Scraper ──────────────────────────────────────────────────────────────────

func _on_scrape_pressed(rom_path: String, systemid: String, btn: Button) -> void:
	if _scrape_in_progress:
		print("[SpawnMenu] Scrape already in progress, ignoring request for: %s" % rom_path.get_file())
		return
	_scrape_in_progress = true
	btn.text = "⏳"
	btn.disabled = true
	_show_scrape_status("Hashing ROM...")

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
		btn.text = String.chr(_ICON_SCRAPE)
		btn.disabled = false
		_hide_scrape_status()
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
			btn.text = String.chr(_ICON_SCRAPE)
			btn.disabled = false
		_hide_scrape_status()
		print("[SpawnMenu] Scrape completed for: %s" % rom_path.get_file())
		_show_scrape_popup(rom_path, systemid, result)

	failed_cb = func(error: String):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = String.chr(_ICON_SCRAPE)
			btn.disabled = false
		_hide_scrape_status()
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


func _show_scrape_status(msg: String) -> void:
	if _scrape_status_bar != null and is_instance_valid(_scrape_status_bar):
		if _scrape_status_label != null:
			_scrape_status_label.text = msg
			_refresh_toast_panel()
		return

	_scrape_status_bar = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.10, 0.28, 0.96)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_status_bar.add_theme_stylebox_override("panel", bg)
	_scrape_status_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scrape_status_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 8)
	_scrape_status_bar.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(hbox)

	var icon := Label.new()
	icon.text = "⏳"
	icon.add_theme_font_size_override("font_size", 18)
	hbox.add_child(icon)

	_scrape_status_label = Label.new()
	_scrape_status_label.text = msg
	_scrape_status_label.add_theme_font_size_override("font_size", 18)
	_scrape_status_label.add_theme_color_override("font_color", COLOR_TITLE)
	hbox.add_child(_scrape_status_label)

	# Into the same stack as the media toasts, so this rides the 3D quad too —
	# it used to be anchored straight onto the page and stayed flat there. Last
	# child, because it always sat below them, and the stack grows upward.
	_ensure_media_toast_stack()
	_media_toast_stack.add_child(_scrape_status_bar)
	_media_toast_stack.move_child(_scrape_status_bar, -1)
	_refresh_toast_panel()


func _update_scrape_status(msg: String) -> void:
	if _scrape_status_label != null and is_instance_valid(_scrape_status_label):
		_scrape_status_label.text = msg
		_refresh_toast_panel()


# Bumped per notice so a stale auto-hide can't clear a newer message.
var _notice_token := 0


## Transient notice in the bottom status bar slot (same look as the scraper's
## "Hashing rom…" bar) — e.g. "Drop Item From Hand First". Auto-hides.
func show_notice(msg: String, seconds := 2.5) -> void:
	_show_scrape_status(msg)
	_notice_token += 1
	var tok := _notice_token
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		# Only clear if nothing (newer notice / live scrape) replaced our text.
		if tok == _notice_token and _scrape_status_label != null \
				and is_instance_valid(_scrape_status_label) \
				and _scrape_status_label.text == msg:
			_hide_scrape_status())


func _hide_scrape_status() -> void:
	if _scrape_status_bar != null and is_instance_valid(_scrape_status_bar):
		if _scrape_status_bar.get_parent() != null:
			_scrape_status_bar.get_parent().remove_child(_scrape_status_bar)
		_scrape_status_bar.queue_free()
	_scrape_status_bar = null
	_scrape_status_label = null
	_refresh_toast_panel()


# ── Stacking media-download toasts ───────────────────────────────────────────
# Same look as the "Hashing ROM…" bar, but one bar per in-flight media file so
# simultaneous box/manual/wheel/label downloads stack up instead of clobbering
# a single status line. Bars sit just above the scrape status bar.

func _ensure_media_toast_stack() -> void:
	if _media_toast_stack != null and is_instance_valid(_media_toast_stack):
		return
	_media_toast_stack = VBoxContainer.new()
	_media_toast_stack.add_theme_constant_override("separation", 6)
	_media_toast_stack.alignment = BoxContainer.ALIGNMENT_END
	# Anchor to the bottom, sitting above the scrape status bar's slot.
	_media_toast_stack.anchor_left   = 0.1
	_media_toast_stack.anchor_right  = 0.9
	_media_toast_stack.anchor_top    = 1.0
	_media_toast_stack.anchor_bottom = 1.0
	_media_toast_stack.offset_top    = -300.0
	_media_toast_stack.offset_bottom = -62.0
	_media_toast_stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_media_toast_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_media_toast_stack)

	# Lift the stack onto its own quad in front of the menu, like a dropdown's
	# option list. It takes the stack as-is — everything that builds, updates or
	# removes a toast below is unchanged. Falls back to the anchors above when
	# there is no 3D host (a plain 2D scene, or a probe).
	_toast_panel = ToastPanel.adopt(_host_viewport(), _media_toast_stack)


## The Viewport2Din3D this menu renders inside, if any. xr-tools parents the
## SubViewport directly under it, so one hop out lands on the 3D node.
func _host_viewport() -> XRToolsViewport2DIn3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_parent() as XRToolsViewport2DIn3D


## Re-measure the toast quad. Deferred so it lands after _enforce_toast_cap's
## visibility pass and after any other toasts raised in the same frame;
## refresh() is idempotent, so extra calls cost nothing.
func _refresh_toast_panel() -> void:
	if _toast_panel != null and is_instance_valid(_toast_panel):
		_toast_panel.refresh.call_deferred()


## Public notification entry point for background services (RomM sync/downloads,
## cache eviction, …). Keyed so each concurrent operation owns one bar and
## updates it in place — never one bar per progress tick or per retry.
##
## key      : stable per operation, e.g. "romm:dl:1289". Use a namespace prefix
##            so it can't collide with the scraper's "box"/"wheel"/… keys.
## progress : 0.0-1.0 to show a bar, or <0 for none.
## seconds  : >0 auto-dismisses after that long; <=0 keeps it until replaced.
func notify(key: String, icon_text: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _media_toasts.has(key):
		_update_media_toast(key, icon_text, msg, progress)
	else:
		_make_media_toast(key, icon_text, msg, progress)
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(_remove_media_toast.bind(key))


## Drop a notification immediately (e.g. an operation was cancelled).
func notify_clear(key: String) -> void:
	_remove_media_toast(key)


func _update_media_toast(key: String, icon_text: String, msg: String,
						 progress: float = -1.0) -> void:
	if not _media_toasts.has(key):
		return
	var toast: Dictionary = _media_toasts[key]
	var lbl: Label = toast.get("label")
	var icn: Label = toast.get("icon")
	var bar: ProgressBar = toast.get("progress")
	if lbl != null and is_instance_valid(lbl):
		lbl.text = msg
	if icn != null and is_instance_valid(icn):
		icn.text = icon_text
	if bar != null and is_instance_valid(bar):
		bar.visible = progress >= 0.0
		bar.value = clampf(progress, 0.0, 1.0) * 100.0
	# The quad is sized to the widest bar, and the text just changed.
	_refresh_toast_panel()


func _make_media_toast(media_type: String, icon_text: String, msg: String,
					   progress: float = -1.0) -> void:
	_ensure_media_toast_stack()

	var bar := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.10, 0.28, 0.96)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(k, 8)
	bar.add_theme_stylebox_override("panel", bg)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Hug the text rather than filling the stack — the quad is sized to the widest
	# bar, so a filling bar would stretch every one of them to that width.
	bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 8)
	bar.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(hbox)

	var icon := Label.new()
	icon.text = icon_text
	icon.add_theme_font_size_override("font_size", 18)
	hbox.add_child(icon)

	var label := Label.new()
	label.text = msg
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_TITLE)
	hbox.add_child(label)

	# Optional progress bar, stacked under the icon+text line.
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.remove_child(hbox)
	vbox.add_child(hbox)
	margin.add_child(vbox)

	var prog := ProgressBar.new()
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog.show_percentage = false
	prog.custom_minimum_size = Vector2(0, 5)
	prog.value = maxf(progress, 0.0) * 100.0
	prog.visible = progress >= 0.0
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.45, 0.70, 1.0)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.25, 0.25, 0.38)
	for st: StyleBoxFlat in [fill, track]:
		for k in ["corner_radius_top_left", "corner_radius_top_right",
				  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
			st.set(k, 3)
	prog.add_theme_stylebox_override("fill", fill)
	prog.add_theme_stylebox_override("background", track)
	vbox.add_child(prog)

	_media_toast_stack.add_child(bar)
	_media_toasts[media_type] = {"bar": bar, "label": label, "icon": icon, "progress": prog}
	_enforce_toast_cap()
	_refresh_toast_panel()


func _on_media_download_started(media_type: String) -> void:
	_make_media_toast(media_type, "⏳", "Downloading %s…" % media_type.capitalize())


func _on_media_download_notice(media_type: String, _path: String) -> void:
	_finish_media_toast(media_type, "✅", "%s downloaded" % media_type.capitalize())


func _on_media_download_notice_failed(media_type: String, _error: String) -> void:
	_finish_media_toast(media_type, "❌", "%s failed" % media_type.capitalize())


## `seconds` defaults to the old 2.5 s; failures pass a longer dwell, because
## 2.5 s is not enough to read a failure reason through a headset.
func _finish_media_toast(media_type: String, icon_text: String, msg: String,
						 seconds: float = 2.5) -> void:
	if not _media_toasts.has(media_type):
		# No "started" toast (e.g. failed before request began) — make one so
		# the outcome is still surfaced.
		_make_media_toast(media_type, icon_text, msg)
	else:
		_update_media_toast(media_type, icon_text, msg, -1.0)

	# Auto-dismiss this toast after a short delay.
	get_tree().create_timer(seconds).timeout.connect(
		_remove_media_toast.bind(media_type))


func _remove_media_toast(media_type: String) -> void:
	if _media_toasts.has(media_type):
		var toast: Dictionary = _media_toasts[media_type]
		var bar: PanelContainer = toast.get("bar")
		if bar != null and is_instance_valid(bar):
			_media_toast_stack.remove_child(bar)
			bar.queue_free()
		_media_toasts.erase(media_type)
		_enforce_toast_cap()
		_refresh_toast_panel()


## Keep at most MAX_VISIBLE_TOASTS bars on screen; older ones collapse into a
## single "+N more" row at the top of the stack. Without this, a queue of
## downloads pushes bars off the top of the menu panel.
func _enforce_toast_cap() -> void:
	if _media_toast_stack == null or not is_instance_valid(_media_toast_stack):
		return

	# The scrape/notice bar shares the stack but is not a media toast: it must
	# never be hidden by the cap nor counted toward it, and it stays at the
	# bottom because that is where it sat when it was anchored to the page.
	if _scrape_status_bar != null and is_instance_valid(_scrape_status_bar) \
			and _scrape_status_bar.get_parent() == _media_toast_stack:
		_media_toast_stack.move_child(_scrape_status_bar, -1)

	var bars: Array[Control] = []
	for c: Node in _media_toast_stack.get_children():
		if c == _toast_overflow_bar or c == _scrape_status_bar:
			continue
		if c is Control:
			bars.append(c)

	var overflow := maxi(0, bars.size() - MAX_VISIBLE_TOASTS)
	# Newest are appended last, so hide from the front.
	for i in bars.size():
		bars[i].visible = i >= overflow

	if overflow <= 0:
		if _toast_overflow_bar != null and is_instance_valid(_toast_overflow_bar):
			_toast_overflow_bar.queue_free()
		_toast_overflow_bar = null
		_toast_overflow_label = null
		return

	if _toast_overflow_bar == null or not is_instance_valid(_toast_overflow_bar):
		_toast_overflow_bar = PanelContainer.new()
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(0.05, 0.10, 0.28, 0.80)
		for k in ["corner_radius_top_left", "corner_radius_top_right",
				  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
			bg.set(k, 8)
		_toast_overflow_bar.add_theme_stylebox_override("panel", bg)
		_toast_overflow_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_toast_overflow_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		var m := MarginContainer.new()
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			m.add_theme_constant_override(side, 6)
		_toast_overflow_bar.add_child(m)

		_toast_overflow_label = Label.new()
		_toast_overflow_label.add_theme_font_size_override("font_size", 15)
		_toast_overflow_label.add_theme_color_override("font_color", COLOR_DESC)
		_toast_overflow_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		m.add_child(_toast_overflow_label)

		_media_toast_stack.add_child(_toast_overflow_bar)

	_media_toast_stack.move_child(_toast_overflow_bar, 0)
	_toast_overflow_label.text = "+%d more" % overflow


# ── RomM notifications ────────────────────────────────────────────────────────
# All of these land in the same bottom-of-menu toast stack the scraper uses.
# Keys are namespaced "romm:" so they cannot collide with the scraper's
# box/wheel/label/manual keys.

const _ROMM_DWELL_OK   := 2.5
const _ROMM_DWELL_INFO := 3.0
const _ROMM_DWELL_FAIL := 6.0   # 2.5 s is not long enough to read a failure

## Driven by the controller's _show_menu/_hide_menu — the Control is always
## visible, it's the Viewport2Din3D node in the world that gets toggled.
var _menu_shown: bool = false


## Called when the menu panel becomes visible in the world.
func on_menu_shown() -> void:
	_menu_shown = true
	_flush_romm_notices()
	_romm_check_for_changes()
	# Deferred so it lands after the menu has finished appearing rather than in
	# the same frame: the first dropdown opened otherwise pays for instancing
	# its quad, SubViewport and option scene right when it is tapped.
	_prewarm_dropdowns.call_deferred()


## Every VRDropdown currently in the menu builds its popout now. Cheap after the
## first time — each one guards on already having built it.
func _prewarm_dropdowns() -> void:
	for d: Node in _find_dropdowns(self):
		d.call("prewarm")


func _find_dropdowns(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c: Node in node.get_children():
		if c is VRDropdown:
			out.append(c)
		out.append_array(_find_dropdowns(c))
	return out


func on_menu_hidden() -> void:
	_menu_shown = false


## The cheapest possible "did anything change?" — /api/stats is public and ~100
## bytes. If the fingerprint matches, the library provably hasn't changed and no
## /api/roms call is made at all.
func _romm_check_for_changes() -> void:
	if romm_config == null or not romm_config.is_configured():
		return
	romm_client.stats(func(ok: bool, stats: Dictionary) -> void:
		if not ok or stats.is_empty():
			return
		if not romm_config.stats_unchanged(stats):
			romm_config.last_stats = stats
			romm_config.save_config()
		# The cached list is already on screen; this corrects it in the
		# background and costs nothing visible.
		_romm_fetch_platforms()
	)


## Toasts can only be seen while the menu panel is open. A 4 GB download keeps
## running while the user plays, so terminal outcomes are queued and flushed
## (coalesced) the next time the menu opens, rather than vanishing unseen.
func _romm_notify_or_queue(key: String, icon: String, msg: String, dwell: float,
						   progress: float = -1.0) -> void:
	if _menu_shown:
		notify(key, icon, msg, progress, dwell)
	elif progress < 0.0:
		# Only outcomes are worth keeping for later. Queueing progress ticks
		# would bank hundreds of them and then replay a finished download.
		_romm_pending_notices.append({"ok": icon == "✅", "msg": msg})


## Called when the menu becomes visible.
func _flush_romm_notices() -> void:
	if _romm_pending_notices.is_empty():
		return
	var done := 0
	var failed := 0
	for n: Dictionary in _romm_pending_notices:
		if bool(n["ok"]):
			done += 1
		else:
			failed += 1
	_romm_pending_notices.clear()

	# One summary, not a replay of every toast.
	if done > 0 and failed == 0:
		notify("romm:flush", "✅", "%d download%s finished" % [done, "" if done == 1 else "s"],
			-1.0, _ROMM_DWELL_INFO)
	elif done == 0 and failed > 0:
		notify("romm:flush", "❌", "%d download%s failed" % [failed, "" if failed == 1 else "s"],
			-1.0, _ROMM_DWELL_FAIL)
	else:
		notify("romm:flush", "✅", "%d finished · %d failed" % [done, failed],
			-1.0, _ROMM_DWELL_FAIL)


func _on_romm_auth_failed(detail: String) -> void:
	push_warning("[RomM] auth failed: %s" % detail)
	notify("romm:conn", "❌", "RomM sign-in expired — check OPTIONS", -1.0, _ROMM_DWELL_FAIL)


## Fires only on a transition, so a dead server can't produce a toast stream.
func _on_romm_reachability_changed(reachable: bool) -> void:
	if reachable:
		return
	notify("romm:conn", "❌", "RomM unreachable", -1.0, _ROMM_DWELL_FAIL)


## Fires twice: once before the first request, then again with the real total
## once page one lands. The toast updates in place.
func _on_romm_sync_started(systemid: String, total: int) -> void:
	var label := _system_label(systemid)
	if total <= 0:
		notify("romm:sync:" + systemid, "⏳", "Fetching the %s list from RomM…" % label, -1.0)
	else:
		notify("romm:sync:" + systemid, "⏳",
			"Syncing %s · 0 / %s" % [label, _commas(total)], 0.0)


func _on_romm_sync_progress(systemid: String, done: int, total: int) -> void:
	var frac := (float(done) / float(total)) if total > 0 else -1.0
	notify("romm:sync:" + systemid, "⏳",
		"Syncing %s · %s / %s" % [_system_label(systemid), _commas(done), _commas(total)], frac)


func _on_romm_sync_finished(systemid: String, ok: bool, added: int, removed: int, error: String) -> void:
	var key := "romm:sync:" + systemid
	var label := _system_label(systemid)

	if not ok:
		notify(key, "❌", "RomM sync failed — %s" % error, -1.0, _ROMM_DWELL_FAIL)
		return

	# Record the watermark so the next open can skip the network entirely.
	var meta := RommCatalog.read_meta(systemid)
	romm_config.set_sync_state(systemid, str(meta.get("updated_after", "")), int(meta.get("total", 0)))
	romm_config.save_config()

	if added > 0:
		notify(key, "✅", "%s · %d new game%s" % [label, added, "" if added == 1 else "s"],
			-1.0, _ROMM_DWELL_INFO)
	elif removed > 0:
		notify(key, "✅", "%s · %d game%s removed" % [label, removed, "" if removed == 1 else "s"],
			-1.0, _ROMM_DWELL_INFO)
	else:
		notify(key, "✅", "%s · up to date" % label, -1.0, 1.5)

	# The open detail page is showing a stale list — rebuild it against the new index.
	if systemid == _romm_detail_systemid:
		_rebuild_romm_rows()
	_update_romm_status_label()
	_pump_romm_sync_queue()


func _on_romm_dl_started(rom_id: int, label: String, total_bytes: int) -> void:
	notify("romm:dl:%d" % rom_id, "⬇", "%s · %s" % [label, _human_bytes(total_bytes)], 0.0)
	# Resolved once; a scan per progress tick would be O(rows) on an 11k list.
	_romm_dl_row_index = -1
	for i in _romm_rows.size():
		if romm_catalog.rom_id_at(int(_romm_rows[i].get("index", -1))) == rom_id:
			_romm_dl_row_index = i
			break


## Progress arrives every 256 KB — ~700 times for a 178 MB ROM, ~16,000 for a
## 4 GB one. Rebinding the whole visible window each time meant thousands of
## row binds, each doing a gamelist scan and several file_exists calls on the
## main thread; with an emulator running that reads as a hard freeze. Only act
## when the displayed percentage actually changes, and touch one row.
func _on_romm_dl_progress(rom_id: int, received: int, total: int) -> void:
	var frac := (float(received) / float(total)) if total > 0 else -1.0
	var pct := int(frac * 100.0) if frac >= 0.0 else 0
	if int(_romm_progress_pct.get(rom_id, -1)) == pct:
		return
	_romm_progress_pct[rom_id] = pct
	notify("romm:dl:%d" % rom_id, "⬇",
		"%d%% · %s / %s" % [pct, _human_bytes(received), _human_bytes(total)], frac)
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_index(_romm_dl_row_index)


func _on_romm_dl_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String) -> void:
	notify("romm:dl:%d" % rom_id, "⏳",
		"%s — retry %d/%d" % [reason, attempt, max_attempts], -1.0)


func _on_romm_dl_finished(rom_id: int, ok: bool, path: String, error: String) -> void:
	var key := "romm:dl:%d" % rom_id
	if ok:
		_romm_notify_or_queue(key, "✅", "%s ready" % path.get_file().get_basename(), _ROMM_DWELL_OK)
	else:
		_romm_notify_or_queue(key, "❌", error, _ROMM_DWELL_FAIL)
	_romm_dl_row_index = -1
	_romm_meta_cache.clear()
	_invalidate_local_scan()
	_rebuild_romm_rows()


func _on_romm_dl_cancelled(rom_id: int) -> void:
	notify_clear("romm:dl:%d" % rom_id)
	_rebuild_romm_rows()


## Files silently vanishing from a library reads as data loss — always say so.
func _on_romm_cache_evicted(freed_bytes: int, count: int) -> void:
	notify("romm:cache", "🗑", "Freed %s — removed %d game%s"
		% [_human_bytes(freed_bytes), count, "" if count == 1 else "s"], -1.0, 4.0)


## Eviction can remove a file behind a visible row, so re-bind rather than let
## the row icon lie about what is on disk.
func _on_romm_cache_changed() -> void:
	_romm_meta_cache.clear()
	_invalidate_local_scan()
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_visible()


func _on_romm_art_ready(_rom_id: int, _texture: Texture2D) -> void:
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_visible()


func _system_label(systemid: String) -> String:
	var name := core_db.get_systemname_for_id(systemid)
	return name if not name.is_empty() else systemid


static func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


static func _human_bytes(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (float(bytes) / 1024.0)
	return "%d B" % bytes


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
			# The memo cached a miss for this ROM before the art existed.
			_wheel_cache.clear()
			_wheel_cache_order.clear()
			_romm_meta_cache.clear()
			_populate_cartridges_tab()
			_rebuild_romm_rows()
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
		rom_btn.pressed.connect(spawn_cartridge_requested.emit.bind(abs_path, romname.get_basename(), systemid))
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
				_fit_within(img, WHEEL_BOX)
				return ImageTexture.create_from_image(img)
	return null


## Scale an image down to fit a box, preserving aspect.
##
## Wheel logos are full-res (600x300 is typical) and were drawn via expand_icon,
## which scales them to a button far wider than it is tall — so the logo rendered
## much larger than its 100 px row and spilled across the boundary into the rows
## either side. Bounding the texture keeps it inside the row whatever its aspect;
## icon_max_width alone caps width only, which cannot bound a square-ish logo.
## (Measured: expand_icon does NOT inflate the button's minimum height, so this
## was a drawing-size problem, not a layout one.)
static func _fit_within(img: Image, box: Vector2i) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0 or (w <= box.x and h <= box.y):
		return
	var scale: float = minf(float(box.x) / float(w), float(box.y) / float(h))
	img.resize(maxi(1, int(round(w * scale))), maxi(1, int(round(h * scale))),
		Image.INTERPOLATE_LANCZOS)


func _has_scraped_manual(systemid: String, romname: String) -> bool:
	if romname.is_empty():
		return false
	return FileAccess.file_exists(_scraped_manual_path(systemid, romname))


func _scraped_manual_path(systemid: String, romname: String) -> String:
	var base := romname.get_basename()
	var dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/manual")
	for ext in ["pdf", "cbz"]:
		var path := dir.path_join(base + "." + ext)
		if FileAccess.file_exists(path):
			return path
	return dir.path_join(base + ".pdf")


func _find_game_by_id(systemid: String, game_id: String) -> Dictionary:
	var gamelist := gamelist_manager.load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		if g.get("game_id", "") == game_id:
			return g
	return {}


# ── Helpers ───────────────────────────────────────────────────────────────────

## SceneManager is an autoload, but every other caller in the project guards the
## lookup rather than naming the global, so this does too. Still here because the
## OPTIONS view reads it; it moves out with that view.
func _get_scene_manager() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("SceneManager")


func _build_about_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_about_scroll = scroll

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)
	vbox.add_child(_spacer(16))

	# Author credit
	var author_lbl := Label.new()
	author_lbl.text = "Ryan McClelland"
	author_lbl.add_theme_font_size_override("font_size", 32)
	author_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	author_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(author_lbl)

	var role_lbl := Label.new()
	role_lbl.text = "Author"
	role_lbl.add_theme_font_size_override("font_size", 18)
	role_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	role_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(role_lbl)

	vbox.add_child(_spacer(8))

	# Donate button
	var donate_btn := Button.new()
	donate_btn.text = "  ❤  DONATE  "
	donate_btn.custom_minimum_size = Vector2(0, 64)
	donate_btn.add_theme_font_size_override("font_size", 24)
	var donate_style := StyleBoxFlat.new()
	donate_style.bg_color = COLOR_BTN_DL
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		donate_style.set(k, 8)
	for state in ["normal", "hover", "pressed"]:
		donate_btn.add_theme_stylebox_override(state, donate_style)
	donate_btn.pressed.connect(func(): OS.shell_open("https://placeholder"))
	vbox.add_child(donate_btn)

	vbox.add_child(HSeparator.new())

	# OSS libraries header
	var libs_hdr := Label.new()
	libs_hdr.text = "OPEN SOURCE LIBRARIES"
	libs_hdr.add_theme_font_size_override("font_size", 20)
	libs_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(libs_hdr)

	const LIBS: Array = [
		["SK.Libretro.Godot", "SKurdt", "MIT"],
		["pdfium",            "The Chromium Authors", "BSD 3-Clause"],
		["godot-xr-tools",   "Bastiaan Olij",   "MIT"],
		["godot-cpp",        "Godot Engine contributors", "MIT"],
		["SDL3",             "Sam Lantinga / SDL contributors", "zlib"],
		["libretro-common",  "libretro team",   "MIT"],
		["ReaderWriterQueue","Cameron Desrochers","BSD"],
		["libVLC",           "VideoLAN",        "LGPL v2.1"],
		["Nerd Fonts",       "Ryan L McIntyre", "MIT"],
		["RomM",             "RomM contributors", "AGPL v3"],
	]
	for entry: Array in LIBS:
		_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)

	vbox.add_child(_spacer(6))

	# Proprietary SDKs. Deliberately not folded into the list above: the Meta XR
	# Audio SDK is not open source, and its licence requires the copyright notice
	# be reproduced wherever the library ships — so this credit is an obligation,
	# not a courtesy.
	var sdk_hdr := Label.new()
	sdk_hdr.text = "THIRD-PARTY SDKS"
	sdk_hdr.add_theme_font_size_override("font_size", 20)
	sdk_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(sdk_hdr)

	const SDKS: Array = [
		["Meta XR Audio SDK", "Meta Platforms, Inc.", "Oculus SDK License"],
	]
	for entry: Array in SDKS:
		_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)

	var sdk_note := Label.new()
	sdk_note.text = "Spatial audio on Quest is HRTF-rendered by the Meta XR Audio SDK, "\
		+ "which places each sound in three dimensions rather than simply panning it "\
		+ "left and right. Where the SDK is unavailable the room falls back to Godot's "\
		+ "built-in 3D audio."
	sdk_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sdk_note.add_theme_font_size_override("font_size", 14)
	sdk_note.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(sdk_note)

	vbox.add_child(_spacer(6))

	# Artwork header
	var art_hdr := Label.new()
	art_hdr.text = "ARTWORK"
	art_hdr.add_theme_font_size_override("font_size", 20)
	art_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(art_hdr)

	const ART: Array = [
		["Systematic icon set", "BAXY Square — github.com/baxysquare", "MIT"],
		["Input Prompts", "Kenney — kenney.nl", "CC0 1.0"],
		["Touch controller model", "immersive-web/webxr-input-profiles", "MIT"],
		["Lamp chain switch (audio)", "ftpalad — freesound.org", "CC0 1.0"],
	]
	for entry: Array in ART:
		_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)

	var art_note := Label.new()
	art_note.text = "Console art from the Systematic theme for RetroArch / Lakka. "\
		+ "Controller line art is rendered from the WebXR input profile model; "\
		+ "button glyphs are Kenney's Input Prompts."
	art_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	art_note.add_theme_font_size_override("font_size", 14)
	art_note.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(art_note)

	vbox.add_child(_spacer(6))

	# Game data sources
	var data_hdr := Label.new()
	data_hdr.text = "GAME DATA"
	data_hdr.add_theme_font_size_override("font_size", 20)
	data_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(data_hdr)

	const DATA: Array = [
		["ScreenScraper", "screenscraper.fr contributors", "CC BY-NC-SA 4.0"],
	]
	for entry: Array in DATA:
		_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)

	var data_note := Label.new()
	data_note.text = "Box art, screenshots and game details are scraped from screenscraper.fr."
	data_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	data_note.add_theme_font_size_override("font_size", 14)
	data_note.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(data_note)

	vbox.add_child(_spacer(6))

	# 3D models. The CC BY entries below are the reason this section exists:
	# attribution is a licence condition for them, not a courtesy. The CC0 ones
	# are credited anyway.
	var mdl_hdr := Label.new()
	mdl_hdr.text = "3D MODELS"
	mdl_hdr.add_theme_font_size_override("font_size", 20)
	mdl_hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(mdl_hdr)

	const MODELS: Array = [
		["Bedroom furniture", "General of Thailand — @Melonpolygons", "CC BY 4.0"],
		["Bookcases with books", "Matthew Collings — @mtcollings", "CC BY 4.0"],
		["Ceiling fan", "lucaboechat", "CC BY 4.0"],
		["Corner TV stand", "Manix3D — @manix3d", "CC BY 4.0"],
		["CRT computer monitor", "fizyman", "CC BY 4.0"],
		["Desk chair", "Slava Izvekov — @guantanamera", "CC BY 4.0"],
		["Interior door and trim", "Roman — @janwama", "CC BY 4.0"],
		["Light switch", "BillieBones", "CC BY 4.0"],
		["Nightstand", "ilyafom1", "CC BY 4.0"],
		["Trash can", "Yury Misiyuk — @Tim0", "CC BY 4.0"],
		["Table lamp", "plaggy", "CC0 1.0"],
		["Television 02", "Benny Weimer — Poly Haven", "CC0 1.0"],
		["Throw pillows", "Serhii Khromov — Poly Haven", "CC0 1.0"],
		["Potted plant", "James Ray Cock — Poly Haven", "CC0 1.0"],
		["Suburban houses", "Kenney — kenney.nl", "CC0 1.0"],
		["Trees", "Quaternius", "CC0 1.0"],
		["Furniture Kit", "Kenney — kenney.nl", "CC0 1.0"],
		["Surfaces", "ambientCG", "CC0 1.0"],
	]
	for entry: Array in MODELS:
		_add_credit_row(vbox, entry[0] as String, entry[1] as String, entry[2] as String)

	var mdl_note := Label.new()
	mdl_note.text = "Room and prop models. CC BY entries require attribution; "\
		+ "wall and floor surfaces are ambientCG photogrammetry."
	mdl_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mdl_note.add_theme_font_size_override("font_size", 14)
	mdl_note.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(mdl_note)

	vbox.add_child(_spacer(12))
	return scroll


## One credit line: title over author on the left, licence on the right.
func _add_credit_row(vbox: VBoxContainer, title: String, author: String, license: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0, 52)
	vbox.add_child(row)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 2)
	row.add_child(left)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	left.add_child(title_lbl)

	var author_sub := Label.new()
	author_sub.text = author
	author_sub.add_theme_font_size_override("font_size", 14)
	author_sub.add_theme_color_override("font_color", COLOR_LICENSE)
	left.add_child(author_sub)

	var lic_lbl := Label.new()
	lic_lbl.text = license
	lic_lbl.add_theme_font_size_override("font_size", 16)
	lic_lbl.add_theme_color_override("font_color", COLOR_DESC)
	lic_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lic_lbl)

	# The scroll bar is drawn over the content, so the licence needs a gutter or
	# a long one ("CC BY-NC-SA 4.0") loses its last character behind it.
	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(18, 0)
	row.add_child(gutter)

	vbox.add_child(HSeparator.new())


func _spacer(height: int) -> Control:
	return MenuStyle.spacer(height)


## The "Recommended" badge shown against a system's suggested core. Uses
## _symbols() because the menu's theme font has no Nerd Font glyphs — the
## codepoint renders as tofu in a plain Label.
func _recommended_badge(font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = "%s  Recommended" % String.chr(_ICON_RECOMMENDED)
	lbl.add_theme_font_override("font", _symbols())
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", COLOR_RECOMMENDED)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


