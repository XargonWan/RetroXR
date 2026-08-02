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
var _cores_view:    SpawnMenuCoresView = null
var _controls_view: SpawnMenuControlsView = null
var _options_view:  SpawnMenuOptionsView = null
# Extracted into their own files — see Scripts/UI/spawn_menu/views/. Each owns
# its widgets and its state; this class only shows and hides them.
var _graphics_view: SpawnMenuGraphicsView = null
var _scene_view:    SpawnMenuSceneView = null
var _net_view:      SpawnMenuNetView = null
var _about_view:    SpawnMenuAboutView = null
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
# core_name -> { "button": Button, "bar": ProgressBar }
# Drill-down browser + fetched cores grouped by systemid ("__other__" = unknown):
#   sid -> Array[{ "core_name", "remote_date", "info" }]
# Outer Download/Manager TabContainer of the Cores view.

# The ScrollContainer currently in view
var _active_scroll:        ScrollContainer = null

# Spawn view tab ScrollContainers (indexed by tab index)
var _spawn_tab_scrolls: Array[ScrollContainer] = []
var _spawn_tabs: TabContainer = null

# Cores > Manager tab state — drill-down browser + installed cores grouped by
# systemid: sid -> Array[{ "core_name", "display_name" }]

## BIOS / Extras tab. `_bios_row_cache` is per-rebuild: the home grid and the
## detail page both need a system's resolved rows, and re-deriving them means
## re-stat'ing (and possibly re-hashing) every declared file.
## job key -> the Button that started it, so progress can be shown in place.
## Rebuilt pages drop their buttons, so entries are validity-checked on use.

## Typing is bursty; one rebuild after the keys stop instead of one per key.
const SEARCH_DEBOUNCE_SEC := 0.18
var _romm_search_timer: Timer = null
## systemid -> {lowercase basename: rom}. A directory listing, so it is cached
## and dropped whenever something writes to a ROM dir.
var _local_scan_cache: Dictionary = {}

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
## Status bars along the bottom: scrape/notice state, and one toast per
## in-flight download or sync. Owns its own 3D quad — see MenuToasts.
var _toasts: MenuToasts = null
# Game detail side panel
var _game_detail_panel: PanelContainer = null
# ROM variants side panel
var _rom_variants_panel: PanelContainer = null
# Callback connected to scraper_client.media_download_completed so the tab
# refreshes when a wheel image or manual PDF finishes downloading.
var _media_dl_refresh_cb: Callable = Callable()


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
		if ok and _cores_view != null and _cores_view.showing_bios_tab():
			_cores_view.refresh_bios_view()
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

	_cores_view = SpawnMenuCoresView.create(self)
	_cores_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cores_view.scroll_changed.connect(func(s: ScrollContainer) -> void:
		if _cores_view.visible:
			_active_scroll = s)
	_cores_view.default_core_changed.connect(
		func(sid: String, cn: String) -> void: default_core_changed.emit(sid, cn))
	content.add_child(_cores_view)

	_controls_view = SpawnMenuControlsView.create()
	_controls_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_controls_view.rebind_started.connect(
		func(action: String) -> void: rebind_started.emit(action))
	_controls_view.pad_rebind_started.connect(
		func(target: String) -> void: pad_rebind_started.emit(target))
	_controls_view.controller_bindings_changed.connect(
		func() -> void: controller_bindings_changed.emit())
	content.add_child(_controls_view)

	_options_view = SpawnMenuOptionsView.create(self)
	_options_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for relay: Array in [
			[_options_view.turn_style_changed, turn_style_changed],
			[_options_view.snap_angle_changed, snap_angle_changed],
			[_options_view.height_offset_changed, height_offset_changed],
			[_options_view.fov_changed, fov_changed],
			[_options_view.world_scale_changed, world_scale_changed],
			[_options_view.auto_save_changed, auto_save_changed],
			[_options_view.show_fps_changed, show_fps_changed],
			[_options_view.aim_crosshair_changed, aim_crosshair_changed],
			[_options_view.controller_hands_changed, controller_hands_changed]]:
		var out: Signal = relay[1]
		(relay[0] as Signal).connect(func(v: Variant) -> void: out.emit(v))
	_options_view.system_filter_changed.connect(_cores_view.refresh_download_systems)
	_options_view.romm_platforms_requested.connect(_romm_fetch_platforms)
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

	_about_view = SpawnMenuAboutView.create()
	_about_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_about_view)

	# Over the views, not inside one: a download raised on the SPAWN tab must stay
	# up when the player switches to CORES.
	_toasts = MenuToasts.create()
	add_child(_toasts)

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
	_active_scroll = _cores_view.active_scroll()
	_cores_view.ensure_fetched()


func _show_controls_view() -> void:
	_show_view(_controls_view, _controls_view, _nav_controls_btn)


func _show_options_view() -> void:
	_show_view(_options_view, _options_view, _nav_options_btn)


func _show_graphics_view() -> void:
	_show_view(_graphics_view, _graphics_view, _nav_graphics_btn)


func _show_scene_view() -> void:
	_show_view(_scene_view, null, _nav_scene_btn)
	# The view owns which of its two panels is up, and reports the scroll back
	# through scroll_changed — including when its own Back button switches them.
	_scene_view.show_rooms()


func _show_about_view() -> void:
	_show_view(_about_view, _about_view, _nav_about_btn)


func _show_net_view() -> void:
	_show_view(_net_view, _net_view, _nav_net_btn)
	_net_view.refresh()


## The RomM platform map and the systems RomM reports that we cannot map. Owned
## here because both the OPTIONS tab and the cartridge browser read them.
func romm_platforms() -> Dictionary:
	return _romm_platforms


func romm_unmapped() -> Array:
	return _romm_unmapped


# ── Notifications ─────────────────────────────────────────────────────────────
# Thin forwarders onto MenuToasts. Public because background services (RomM
# sync and downloads, cache eviction) and the controller all raise notices
# through the menu rather than reaching for the stack themselves.

func notify(key: String, icon_text: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _toasts:
		_toasts.notify(key, icon_text, msg, progress, seconds)


func notify_clear(key: String) -> void:
	if _toasts:
		_toasts.clear(key)


func show_notice(msg: String, seconds := 2.5) -> void:
	if _toasts:
		_toasts.notice(msg, seconds)


func _show_scrape_status(msg: String) -> void:
	if _toasts:
		_toasts.status(msg)


func _update_scrape_status(msg: String) -> void:
	if _toasts:
		_toasts.status_update(msg)


func _hide_scrape_status() -> void:
	if _toasts:
		_toasts.status_clear()


func _on_media_download_started(media_type: String) -> void:
	notify(media_type, "⏳", "Downloading %s…" % media_type.capitalize())


func _on_media_download_notice(media_type: String, _path: String) -> void:
	if _toasts:
		_toasts.finish(media_type, "✅", "%s downloaded" % media_type.capitalize())


func _on_media_download_notice_failed(media_type: String, _error: String) -> void:
	if _toasts:
		_toasts.finish(media_type, "❌", "%s failed" % media_type.capitalize())


## Answers to rebind_started / pad_rebind_started. The capture happens in
## spawn_menu_controller, where raw input arrives; these hand the result to the
## view that asked. `event` is null, and `binding` "", when the user cancelled.
func on_rebind_complete(action: String, event: InputEvent) -> void:
	if _controls_view:
		_controls_view.on_rebind_complete(action, event)


func on_pad_rebind_complete(target: String, binding: String) -> void:
	if _controls_view:
		_controls_view.on_pad_rebind_complete(target, binding)


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


func _romm_mark() -> Texture2D:
	return MenuIcons.romm_mark()


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
		if _options_view:
			_options_view.update_romm_status_label()
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
	source_drop.set_toggle_glyph(MenuIcons.FILTER, _symbols())
	source_drop.item_selected.connect(func(id: Variant) -> void:
		_romm_source_filter = str(id)
		_rebuild_romm_rows()
	)
	toolbar.add_child(source_drop)

	_romm_region_drop = VRDropdown.create("", [["All regions", ""]], "", 1, Vector2(210, 52), 18)
	_romm_region_drop.size_flags_horizontal = Control.SIZE_SHRINK_END
	_romm_region_drop.float_panel = true
	_romm_region_drop.set_toggle_glyph(MenuIcons.REGION, _symbols())
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


func _symbols() -> FontVariation:
	return MenuIcons.symbols()


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
		state.text = String.chr(MenuIcons.BUSY)
		state.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		state.tooltip_text = "Cancel download"
		pct.visible = true
		pct.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		pct.text = "%d%%" % _romm_progress_pct.get(rom_id, 0)
		state.pressed.connect(func() -> void: romm_downloader.cancel_current())
	elif source == "server":
		state.text = String.chr(MenuIcons.DOWNLOAD)
		# The cloud glyph is visually lighter than the trash glyphs at the same
		# size — a small bump evens the weight out.
		state.add_theme_font_size_override("font_size", 44)
		state.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		state.tooltip_text = "Download from RomM (%s)" % _human_bytes(int(entry.get("fs_size_bytes", 0)))
		state.pressed.connect(func() -> void: romm_downloader.enqueue(entry, systemid))
	else:
		state.add_theme_font_size_override("font_size", 40)
		var forever := source == "local"
		state.text = String.chr(MenuIcons.DELETE_FOREVER if forever else MenuIcons.DELETE)
		state.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
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
	detail.text = String.chr(MenuIcons.GAMEPAD)
	detail.visible = not game.is_empty()
	if not game.is_empty():
		detail.pressed.connect(_show_game_detail_panel.bind(game, systemid))

	var has_manual: bool = meta["has_manual"]
	var manual_path: String = meta["manual_path"]
	manual.text = String.chr(MenuIcons.BOOK)
	manual.visible = has_manual
	if has_manual:
		manual.pressed.connect(spawn_manual_requested.emit.bind(manual_path))

	# Scraping hashes the local file, so it needs one on disk.
	# disabled is reset here or a mid-scrape scroll leaves it stuck on whichever
	# row later reuses this pooled button.
	scrape.text = String.chr(MenuIcons.SCRAPE)
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
		state.text = String.chr(MenuIcons.ERROR)
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
		btn.text = String.chr(MenuIcons.SCRAPE)
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
			btn.text = String.chr(MenuIcons.SCRAPE)
			btn.disabled = false
		_hide_scrape_status()
		print("[SpawnMenu] Scrape completed for: %s" % rom_path.get_file())
		_show_scrape_popup(rom_path, systemid, result)

	failed_cb = func(error: String):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = String.chr(MenuIcons.SCRAPE)
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


# ── RomM notifications ────────────────────────────────────────────────────────
# All of these land in the same bottom-of-menu toast stack the scraper uses.
# Keys are namespaced "romm:" so they cannot collide with the scraper's
# box/wheel/label/manual keys.

const _ROMM_DWELL_OK   := MenuToasts.DWELL_OK
const _ROMM_DWELL_INFO := MenuToasts.DWELL_INFO
const _ROMM_DWELL_FAIL := MenuToasts.DWELL_FAIL

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
	if _options_view:
		_options_view.update_romm_status_label()
		_options_view.pump_romm_sync_queue()


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
	return MenuStyle.human_bytes(bytes)


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


func _spacer(height: int) -> Control:
	return MenuStyle.spacer(height)


## The "Recommended" badge shown against a system's suggested core. Uses
## _symbols() because the menu's theme font has no Nerd Font glyphs — the
## codepoint renders as tofu in a plain Label.
func _recommended_badge(font_size: int) -> Label:
	return MenuIcons.recommended_badge(font_size)


