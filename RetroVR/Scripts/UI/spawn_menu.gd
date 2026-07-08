## SpawnMenu2D — 2D Control rendered inside a SubViewport on the VR spawn panel.
## Builds its own UI programmatically so no extra tscn layout work is needed.
## Emits spawn_requested(type) when a spawn button is pressed,
## and close_requested when the ✕ button is pressed.
class_name SpawnMenu2D
extends Control

## Scale factor applied to the entire UI.  Increase this when viewport_size
## is higher than the logical design resolution so content stays the same
## apparent physical size in VR.  Default 2.0 matches viewport_size 1800×1500
## against the original 900×750 design resolution.
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
## Emitted when the user changes the snap turn angle.
signal snap_angle_changed(degrees: float)
## Emitted when the user adjusts the player height offset.
signal height_offset_changed(offset: float)
## Emitted when the user changes the desktop camera FOV.
signal fov_changed(degrees: float)
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

# ── UI state ──────────────────────────────────────────────────────────────────
var _spawn_view:    Control = null
var _cores_view:    Control = null
var _controls_view: Control = null
var _options_view:  Control = null
var _scene_view:    Control = null
var _about_view:    Control = null
var _net_view:      Control = null
var _net_scroll:    ScrollContainer = null
var _nav_net_btn:      Button = null
var _net_status_lbl:   Label = null
var _net_name_edit:    LineEdit = null
var _net_ip_edit:      LineEdit = null
var _net_players_box:  VBoxContainer = null
var _net_host_btn:     Button = null
var _net_join_btn:     Button = null
var _net_leave_btn:    Button = null
var _nav_spawn_btn:    Button = null
var _nav_cores_btn:    Button = null
var _nav_controls_btn: Button = null
var _nav_options_btn:  Button = null
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

# Custom scroll indicator (replaces native scrollbar)
var _vscrollbar: VScrollBar = null

# Cores > Manager tab state — drill-down browser + installed cores grouped by
# systemid: sid -> Array[{ "core_name", "display_name" }]
var _manager_browser: SystemGridBrowser = null
var _manager_cores_by_system: Dictionary = {}

# Spawn > Systems tab — rebuilt whenever defaults change
var _systems_vbox: VBoxContainer = null
# Spawn > Cartridges tab — drill-down browser, one tile per system
var _cartridges_browser: SystemGridBrowser = null
# Spawn > Books tab — rebuilt each time the tab is opened
var _books_vbox: VBoxContainer = null
# Spawn > Videos tab — rebuilt each time the tab is opened
var _videos_vbox: VBoxContainer = null

# Scene view state
var _scene_scroll:        ScrollContainer = null   # rooms-level scroll
var _scene_rooms_panel:   Control         = null   # Level 1: room picker
var _scene_states_panel:  Control         = null   # Level 2: slot grid
var _scene_states_scroll: ScrollContainer = null
var _scene_states_vbox:   VBoxContainer   = null
var _scene_hover_timer:   Dictionary      = {}     # slot_id -> bool (pending-hide)
var _scene_rename_slot_id: String         = ""
var _scene_rename_edit:   LineEdit        = null
var _auto_save_btn: Button = null

# Scrape popup overlay
var _scrape_popup: PanelContainer = null
var _scrape_in_progress: bool = false
# Scrape status bar (shows hashing / request / retry state below the menu)
var _scrape_status_bar: PanelContainer = null
var _scrape_status_label: Label = null
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
# Inline-dropdown state for the Controls section (source_key → dict).
var _controls_opts: Dictionary = {}
# Key of the currently-open inline dropdown ("" = none).
var _open_dropdown_key: String = ""

# Working copies of physical-gamepad bindings edited in the GAME CONTROLLER section.
var _edit_pad_button_map: Dictionary = {}
var _edit_pad_stick_map:  Dictionary = {}
# Gamepad rebinding state: target waiting for a joypad press, target → Button node.
var _pad_rebinding_target: String = ""
var _pad_rebind_buttons: Dictionary = {}
# Live "connected pads" status label in the GAME CONTROLLER section.
var _pad_status_label: Label = null


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
	RomLibrary.ensure_books_root()
	RomLibrary.ensure_videos_root()
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
	_nav_spawn_btn    = _make_nav_button("  SPAWN  ")
	_nav_cores_btn    = _make_nav_button("  CORES  ")
	_nav_controls_btn = _make_nav_button(" CONTROLS ")
	_nav_options_btn  = _make_nav_button(" OPTIONS ")
	_nav_scene_btn    = _make_nav_button("  SCENE  ")
	_nav_net_btn      = _make_nav_button("  NET  ")
	_nav_about_btn    = _make_nav_button("  ABOUT  ")
	_nav_spawn_btn.pressed.connect(_show_spawn_view)
	_nav_cores_btn.pressed.connect(_show_cores_view)
	_nav_controls_btn.pressed.connect(_show_controls_view)
	_nav_options_btn.pressed.connect(_show_options_view)
	_nav_scene_btn.pressed.connect(_show_scene_view)
	_nav_net_btn.pressed.connect(_show_net_view)
	_nav_about_btn.pressed.connect(_show_about_view)
	nav_bar.add_child(_nav_spawn_btn)
	nav_bar.add_child(_nav_cores_btn)
	nav_bar.add_child(_nav_controls_btn)
	nav_bar.add_child(_nav_options_btn)
	nav_bar.add_child(_nav_scene_btn)
	nav_bar.add_child(_nav_net_btn)
	nav_bar.add_child(_nav_about_btn)
	_nav_buttons = [_nav_spawn_btn, _nav_cores_btn, _nav_controls_btn, _nav_options_btn, _nav_scene_btn, _nav_net_btn, _nav_about_btn]

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

	_scene_view = _build_scene_view()
	_scene_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_scene_view)

	_net_view = _build_net_view()
	_net_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_net_view)

	_about_view = _build_about_view()
	_about_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_about_view)

	_show_spawn_view()


## Create an OptionButton configured for VR pointer use.
## ACTION_MODE_BUTTON_PRESS means the dropdown opens on trigger-squeeze (press),
## not on trigger-release, preventing accidental activation.
func _make_opt() -> OptionButton:
	var opt := OptionButton.new()
	opt.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	return opt


func _make_toggle(initial_on: bool, on_toggled: Callable) -> Button:
	const W      := 100.0
	const H      := 52.0
	const KNOB_S := 40.0
	const MARGIN := 6.0

	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_pressed = initial_on
	btn.custom_minimum_size = Vector2(W, H)
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = ""

	var off_style := StyleBoxFlat.new()
	off_style.bg_color = Color(0.20, 0.20, 0.26)
	off_style.border_color = Color(0.50, 0.50, 0.58)
	for side in ["border_width_left", "border_width_right", "border_width_top", "border_width_bottom"]:
		off_style.set(side, 2)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		off_style.set(k, int(H / 2.0))
	for m in ["content_margin_left", "content_margin_right",
			  "content_margin_top", "content_margin_bottom"]:
		off_style.set(m, 0)

	var on_style := StyleBoxFlat.new()
	on_style.bg_color = Color(0.14, 0.55, 0.30)
	on_style.border_color = Color(0.30, 0.80, 0.50)
	for side in ["border_width_left", "border_width_right", "border_width_top", "border_width_bottom"]:
		on_style.set(side, 2)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		on_style.set(k, int(H / 2.0))
	for m in ["content_margin_left", "content_margin_right",
			  "content_margin_top", "content_margin_bottom"]:
		on_style.set(m, 0)

	btn.add_theme_stylebox_override("normal",        off_style)
	btn.add_theme_stylebox_override("hover",         off_style)
	btn.add_theme_stylebox_override("pressed",       on_style)
	btn.add_theme_stylebox_override("hover_pressed", on_style)
	btn.add_theme_stylebox_override("focus",         StyleBoxEmpty.new())

	var knob := Panel.new()
	knob.size = Vector2(KNOB_S, KNOB_S)
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ks := StyleBoxFlat.new()
	ks.bg_color = Color.WHITE
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		ks.set(k, int(KNOB_S / 2.0))
	knob.add_theme_stylebox_override("panel", ks)

	var knob_y := (H - KNOB_S) / 2.0
	var x_off  := MARGIN
	var x_on   := W - KNOB_S - MARGIN
	knob.position = Vector2(x_on if initial_on else x_off, knob_y)
	btn.add_child(knob)

	btn.toggled.connect(func(on: bool) -> void:
		knob.position.x = x_on if on else x_off
		on_toggled.call(on)
	)
	return btn


func _make_nav_button(lbl: String) -> Button:
	var btn := Button.new()
	btn.text = lbl
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _show_view(view: Control, scroll: ScrollContainer, nav_btn: Button) -> void:
	for v: Control in [_spawn_view, _cores_view, _controls_view, _options_view, _scene_view, _net_view, _about_view]:
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


func _show_scene_view() -> void:
	_show_view(_scene_view, null, _nav_scene_btn)
	_show_rooms_view()


func _show_rooms_view() -> void:
	if _scene_rooms_panel:
		_scene_rooms_panel.visible = true
	if _scene_states_panel:
		_scene_states_panel.visible = false
	_active_scroll = _scene_scroll
	_update_room_card_highlights()


func _show_states_view() -> void:
	if _scene_rooms_panel:
		_scene_rooms_panel.visible = false
	if _scene_states_panel:
		_scene_states_panel.visible = true
	_active_scroll = _scene_states_scroll
	_rebuild_states_grid()


func _show_about_view() -> void:
	_show_view(_about_view, _about_scroll, _nav_about_btn)


func _show_net_view() -> void:
	_show_view(_net_view, _net_scroll, _nav_net_btn)
	_refresh_net_ui()


# ── Multiplayer (NET) view ────────────────────────────────────────────────────

const NET_PREFS_PATH := "user://net_prefs.json"


func _build_net_view() -> Control:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_net_scroll = scroll

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	var prefs := _load_net_prefs()

	var hdr := Label.new()
	hdr.text = "MULTIPLAYER (LAN)"
	hdr.add_theme_font_size_override("font_size", 22)
	hdr.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(hdr)

	_net_status_lbl = Label.new()
	_net_status_lbl.text = "Not connected"
	_net_status_lbl.add_theme_font_size_override("font_size", 18)
	_net_status_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	_net_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_net_status_lbl)

	# ── Player name ───────────────────────────────────────────────────────────
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	name_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(name_row)
	var name_lbl := Label.new()
	name_lbl.text = "Name"
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	name_row.add_child(name_lbl)
	_net_name_edit = LineEdit.new()
	_net_name_edit.text = str(prefs.get("name", "Player"))
	_net_name_edit.max_length = 24
	_net_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_name_edit.add_theme_font_size_override("font_size", 20)
	name_row.add_child(_net_name_edit)

	# ── Host ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	_net_host_btn = Button.new()
	_net_host_btn.text = "Host Game"
	_net_host_btn.custom_minimum_size = Vector2(0, 56)
	_net_host_btn.add_theme_font_size_override("font_size", 20)
	_net_host_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	_net_host_btn.focus_mode = Control.FOCUS_NONE
	_net_host_btn.pressed.connect(_on_net_host)
	vbox.add_child(_net_host_btn)

	# ── Join ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	join_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(join_row)
	var ip_lbl := Label.new()
	ip_lbl.text = "Host IP"
	ip_lbl.add_theme_font_size_override("font_size", 20)
	ip_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	join_row.add_child(ip_lbl)
	_net_ip_edit = LineEdit.new()
	_net_ip_edit.text = str(prefs.get("ip", ""))
	_net_ip_edit.placeholder_text = "192.168.1.10"
	_net_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_ip_edit.add_theme_font_size_override("font_size", 20)
	join_row.add_child(_net_ip_edit)
	_net_join_btn = Button.new()
	_net_join_btn.text = "  Join  "
	_net_join_btn.custom_minimum_size = Vector2(120, 52)
	_net_join_btn.add_theme_font_size_override("font_size", 20)
	_net_join_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	_net_join_btn.focus_mode = Control.FOCUS_NONE
	_net_join_btn.pressed.connect(_on_net_join)
	join_row.add_child(_net_join_btn)

	# On-menu keypad so the IP can be typed with the VR pointer.
	var pad := GridContainer.new()
	pad.columns = 6
	pad.add_theme_constant_override("h_separation", 6)
	pad.add_theme_constant_override("v_separation", 6)
	vbox.add_child(pad)
	for key: String in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ".", "⌫"]:
		var kb := Button.new()
		kb.text = key
		kb.custom_minimum_size = Vector2(0, 52)
		kb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kb.add_theme_font_size_override("font_size", 22)
		kb.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		kb.focus_mode = Control.FOCUS_NONE
		var captured := key
		kb.pressed.connect(func() -> void:
			if captured == "⌫":
				_net_ip_edit.text = _net_ip_edit.text.left(_net_ip_edit.text.length() - 1)
			else:
				_net_ip_edit.text += captured
		)
		pad.add_child(kb)

	# ── Players ───────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var players_hdr := Label.new()
	players_hdr.text = "Players"
	players_hdr.add_theme_font_size_override("font_size", 18)
	players_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(players_hdr)
	_net_players_box = VBoxContainer.new()
	_net_players_box.add_theme_constant_override("separation", 4)
	vbox.add_child(_net_players_box)

	# ── Disconnect ────────────────────────────────────────────────────────────
	_net_leave_btn = Button.new()
	_net_leave_btn.text = "Disconnect"
	_net_leave_btn.custom_minimum_size = Vector2(0, 56)
	_net_leave_btn.add_theme_font_size_override("font_size", 20)
	_net_leave_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	_net_leave_btn.focus_mode = Control.FOCUS_NONE
	_net_leave_btn.pressed.connect(func() -> void: NetworkManager.leave_session())
	vbox.add_child(_net_leave_btn)

	# Live updates from the session.
	NetworkManager.status_changed.connect(func(text: String) -> void:
		if is_instance_valid(_net_status_lbl):
			_net_status_lbl.text = text
	)
	NetworkManager.session_started.connect(func(_h: bool) -> void: _refresh_net_ui())
	NetworkManager.session_ended.connect(func(_r: String) -> void: _refresh_net_ui())
	NetworkManager.peer_registered.connect(func(_i: int, _d: Dictionary) -> void: _refresh_net_ui())
	NetworkManager.peer_left.connect(func(_i: int) -> void: _refresh_net_ui())

	# Keep ping readouts fresh while the NET view is on screen.
	var ping_timer := Timer.new()
	ping_timer.wait_time = 1.0
	ping_timer.autostart = true
	ping_timer.timeout.connect(func() -> void:
		if NetworkManager.is_active() and is_instance_valid(_net_view) and _net_view.visible:
			_refresh_net_ui()
	)
	vbox.add_child(ping_timer)

	return scroll


func _on_net_host() -> void:
	NetworkManager.player_name = _net_name_edit.text.strip_edges()
	_save_net_prefs()
	NetworkManager.host_game()


func _on_net_join() -> void:
	var ip := _net_ip_edit.text.strip_edges()
	if not ip.is_valid_ip_address():
		if is_instance_valid(_net_status_lbl):
			_net_status_lbl.text = "Invalid IP address: '%s'" % ip
		return
	NetworkManager.player_name = _net_name_edit.text.strip_edges()
	_save_net_prefs()
	NetworkManager.join_game(ip)


func _refresh_net_ui() -> void:
	if not is_instance_valid(_net_players_box):
		return
	var active: bool = NetworkManager.is_active()
	_net_host_btn.disabled = active
	_net_join_btn.disabled = active
	_net_leave_btn.disabled = not active
	_net_name_edit.editable = not active

	for child in _net_players_box.get_children():
		child.queue_free()
	var self_id: int = NetworkManager.multiplayer.get_unique_id() if active else -1
	for id: int in NetworkManager.peers:
		var info: Dictionary = NetworkManager.peers[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var swatch := ColorRect.new()
		swatch.color = NetworkManager.PLAYER_COLORS[int(info.get("color_idx", 0)) % NetworkManager.PLAYER_COLORS.size()]
		swatch.custom_minimum_size = Vector2(26, 26)
		row.add_child(swatch)
		var lbl := Label.new()
		var suffix := ""
		if id == 1:
			suffix += "  (host)"
		if id == self_id:
			suffix += "  (you)"
		var ping: int = NetworkManager.ping_ms(id)
		if ping > 0:
			suffix += "  %d ms" % ping
		lbl.text = "%s%s" % [info.get("name", "?"), suffix]
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", COLOR_TITLE)
		row.add_child(lbl)
		_net_players_box.add_child(row)


func _load_net_prefs() -> Dictionary:
	if not FileAccess.file_exists(NET_PREFS_PATH):
		return {}
	var f := FileAccess.open(NET_PREFS_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _save_net_prefs() -> void:
	var f := FileAccess.open(NET_PREFS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"name": _net_name_edit.text.strip_edges(),
			"ip": _net_ip_edit.text.strip_edges(),
		}))


func _update_spawn_active_scroll(tab_idx: int) -> void:
	if tab_idx == 2:
		_update_cartridges_inner_scroll()
	elif tab_idx >= 0 and tab_idx < _spawn_tab_scrolls.size():
		_active_scroll = _spawn_tab_scrolls[tab_idx]
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

	# Cartridges tab — drill-down browser, one tile per system
	_cartridges_browser = SystemGridBrowser.new()
	_cartridges_browser.name = "Cartridges"
	_cartridges_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cartridges_browser.empty_text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
	_cartridges_browser.set_detail_populator(_populate_cartridges_detail)
	_cartridges_browser.active_scroll_changed.connect(func(_s: ScrollContainer):
		_update_cartridges_inner_scroll()
	)
	tabs.add_child(_cartridges_browser)
	_spawn_tab_scrolls.append(null)  # index 2 handled via _update_cartridges_inner_scroll
	_populate_cartridges_tab()

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

	_add_spawn_tab(tabs, "Objects", [
		["Trash Can",   "trash_can"],
		["VCR",         "vcr_player"],
		["TV Remote",   "tv_remote"],
		["Memory Card", "memory_card"],
	])

	_add_spawn_tab(tabs, "Controllers", [
		["Regular Controller", "retro_controller"],
		["Ray Gun",            "ray_gun"],
	])

	# Refresh on tab switch — picks up files added to disk since last open
	# Also update _active_scroll to the current tab's ScrollContainer
	tabs.tab_changed.connect(func(idx: int):
		if idx == 2:
			_populate_cartridges_tab()
		elif idx == 3:
			_populate_books_tab()
		elif idx == 4:
			_populate_videos_tab()
		_update_spawn_active_scroll(idx)
	)

	return tabs


func _clear_vbox(vbox: VBoxContainer) -> void:
	for child in vbox.get_children():
		child.queue_free()
	vbox.add_child(_spacer(10))


func _add_no_defaults_label(container: Container) -> void:
	var lbl := Label.new()
	lbl.text = "No default cores set.\nGo to Cores \u25b8 Manager to configure systems."
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", COLOR_LICENSE)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(lbl)


func _populate_systems_tab() -> void:
	if not _systems_vbox:
		return
	_clear_vbox(_systems_vbox)
	var defaults := core_defaults.all_defaults()
	if defaults.is_empty():
		_add_no_defaults_label(_systems_vbox)
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


## Rebuild the Cartridges home grid: one tile per system that has a default
## core. ROMs are scanned lazily, only when a system tile is opened.
func _populate_cartridges_tab() -> void:
	if not _cartridges_browser:
		return
	var systems: Array = []
	for systemid: String in core_defaults.all_defaults():
		systems.append({"systemid": systemid, "name": core_db.get_systemname_for_id(systemid)})
	_cartridges_browser.set_systems(systems)
	# If a system detail is open, re-run it so newly-added ROMs appear.
	_cartridges_browser.refresh()


## Detail page for one system: its scanned ROMs (deduped by scraped game).
func _populate_cartridges_detail(systemid: String, vbox: VBoxContainer) -> void:
	RomLibrary.ensure_rom_dir(systemid)
	# Collect all supported extensions for this system across all its cores.
	var exts: Array[String] = []
	for entry: Dictionary in core_db.get_by_systemid(systemid):
		for ext: String in entry.get("supported_extensions", "").split("|"):
			var e := ext.strip_edges().to_lower()
			if not e.is_empty() and e not in exts:
				exts.append(e)

	vbox.add_child(_spacer(4))
	var roms := RomLibrary.scan_roms(systemid, exts)
	if roms.is_empty():
		var hint := Label.new()
		hint.text = "Add ROMs to %s/ to see them here." % RomLibrary.rom_dir_for_system(systemid)
		hint.add_theme_font_size_override("font_size", 18)
		hint.add_theme_color_override("font_color", COLOR_DESC)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(hint)
		return

	var shown_games: Dictionary = {}
	for rom: Dictionary in roms:
		var rom_path: String = rom["path"]
		var game := gamelist_manager.get_game_for_rom(systemid, rom_path)
		var is_scraped := not game.is_empty()
		if is_scraped:
			var gid: String = game.get("game_id", "")
			if shown_games.has(gid):
				continue
			shown_games[gid] = true
		vbox.add_child(_build_rom_row(systemid, rom, game, is_scraped))
	vbox.add_child(_spacer(8))


## One ROM row: spawn button (+ wheel icon) plus scrape/detail/manual buttons.
func _build_rom_row(systemid: String, rom: Dictionary, game: Dictionary, is_scraped: bool) -> Control:
	var pref_rom: Dictionary = GamelistManager.get_preferred_rom(game) if is_scraped else {}
	var wheel_tex: Texture2D = _load_wheel_texture(systemid, pref_rom.get("romname", "")) if is_scraped else null
	var row_h: int = 100 if wheel_tex else 72

	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, row_h)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", 22)

	if is_scraped:
		var spawn_path: String = GamelistManager.to_absolute_path(systemid, pref_rom.get("path", rom["path"]))
		var game_name: String = game.get("name", rom["label"])
		if wheel_tex:
			btn.icon = wheel_tex
			btn.text = ""
			btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			btn.expand_icon = true
		else:
			btn.text = "  +  " + game_name
		btn.pressed.connect(spawn_cartridge_requested.emit.bind(spawn_path, game_name, systemid))
	else:
		btn.text = "  +  " + rom["label"]
		btn.pressed.connect(spawn_cartridge_requested.emit.bind(rom["path"], rom["label"], systemid))

	row.add_child(btn)

	if is_scraped:
		var detail_btn := Button.new()
		detail_btn.text = "🎮"
		detail_btn.custom_minimum_size = Vector2(72, row_h)
		detail_btn.tooltip_text = "Game info"
		detail_btn.add_theme_font_size_override("font_size", 26)
		detail_btn.pressed.connect(_show_game_detail_panel.bind(game, systemid))
		row.add_child(detail_btn)

	if is_scraped and _has_scraped_manual(systemid, pref_rom.get("romname", "")):
		var manual_btn := Button.new()
		manual_btn.text = "📖"
		manual_btn.custom_minimum_size = Vector2(72, row_h)
		manual_btn.tooltip_text = "Spawn manual"
		manual_btn.add_theme_font_size_override("font_size", 26)
		var pdf_path := _scraped_manual_path(systemid, pref_rom.get("romname", ""))
		manual_btn.pressed.connect(spawn_manual_requested.emit.bind(pdf_path))
		row.add_child(manual_btn)

	var scrape_btn := Button.new()
	scrape_btn.text = "✂️"
	scrape_btn.custom_minimum_size = Vector2(72, row_h)
	scrape_btn.tooltip_text = "Scrape ROM"
	scrape_btn.add_theme_font_size_override("font_size", 26)
	scrape_btn.pressed.connect(_on_scrape_pressed.bind(rom["path"], systemid, scrape_btn))
	row.add_child(scrape_btn)

	return row


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

	# Refresh Manager list each time the user switches to it, and keep the VR
	# scroll target pointed at the newly-visible tab's browser.
	tabs.tab_changed.connect(func(idx: int):
		if idx == 1:
			_populate_manager_tab()
		_update_cores_active_scroll()
	)

	return tabs


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
		var lib_suffix := "_libretro_android.so" if OS.get_name() == "Android" else "_libretro.dll"
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(lib_suffix):
				var cn := fname.trim_suffix(lib_suffix)
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
		var cores_list: Array = _manager_cores_by_system[sid] as Array
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
	# single "Other" bucket so nothing is hidden.
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

	if get_viewport().use_xr:
		# Turn Style option (XR only)
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

		var opt := _make_opt()
		opt.custom_minimum_size = Vector2(220, 56)
		opt.add_theme_font_size_override("font_size", 20)
		opt.add_item("SNAP", 0)
		opt.add_item("SMOOTH", 1)
		opt.selected = 0
		opt.item_selected.connect(func(idx: int) -> void:
			turn_style_changed.emit("SNAP" if idx == 0 else "SMOOTH")
		)
		row.add_child(opt)

		# Snap Turn Angle option (XR only)
		var sa_row := HBoxContainer.new()
		sa_row.add_theme_constant_override("separation", 10)
		sa_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(sa_row)

		var sa_lbl := Label.new()
		sa_lbl.text = "Snap Angle"
		sa_lbl.add_theme_font_size_override("font_size", 22)
		sa_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		sa_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sa_row.add_child(sa_lbl)

		var sa_opt := _make_opt()
		sa_opt.custom_minimum_size = Vector2(140, 56)
		sa_opt.add_theme_font_size_override("font_size", 20)
		sa_opt.add_item("30°", 0)
		sa_opt.add_item("45°", 1)
		sa_opt.add_item("60°", 2)
		sa_opt.selected = 1
		sa_opt.item_selected.connect(func(idx: int) -> void:
			var angles := [30.0, 45.0, 60.0]
			snap_angle_changed.emit(angles[idx])
		)
		sa_row.add_child(sa_opt)

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

	as_row.add_child(_make_toggle(true, func(on: bool) -> void:
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

	fps_row.add_child(_make_toggle(false, func(on: bool) -> void:
		show_fps_changed.emit(on)
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

	xhair_row.add_child(_make_toggle(true, func(on: bool) -> void:
		aim_crosshair_changed.emit(on)
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
		_server_address_label.text = "http://%s:8080" % WebFileServer.local_ip()
		_server_address_label.visible = scraper_config.web_server_enabled
		vbox.add_child(_server_address_label)

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

	# Meta XR overlay keyboard bounce fix: after the keyboard is dismissed
	# (via Enter or its close button), the Meta runtime fires a pointer-up
	# event that re-focuses the LineEdit and re-opens the keyboard.
	# A short cooldown on focus_entered prevents this loop.
	edit.focus_entered.connect(func() -> void:
		if edit.get_meta("kb_cooling", false):
			edit.release_focus.call_deferred()
	)
	edit.text_submitted.connect(func(text: String) -> void:
		on_changed.call(text)
		edit.release_focus()
		edit.set_meta("kb_cooling", true)
		get_tree().create_timer(0.5).timeout.connect(
			func() -> void: edit.set_meta("kb_cooling", false), CONNECT_ONE_SHOT)
	)
	edit.focus_exited.connect(func() -> void:
		on_changed.call(edit.text)
		edit.set_meta("kb_cooling", true)
		get_tree().create_timer(0.5).timeout.connect(
			func() -> void: edit.set_meta("kb_cooling", false), CONNECT_ONE_SHOT)
	)

	row.add_child(edit)


# ── Controls remapping view ───────────────────────────────────────────────────

## Close the named inline dropdown and reset its toggle arrow.
func _close_dropdown(k: String) -> void:
	var entry: Variant = _controls_opts.get(k)
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	var panel := d.get("panel") as PanelContainer
	var toggle := d.get("toggle") as Button
	if panel:
		panel.visible = false
	if toggle and toggle.text.ends_with(" ▴"):
		toggle.text = toggle.text.trim_suffix(" ▴") + " ▾"
	if _open_dropdown_key == k:
		_open_dropdown_key = ""


## Update an inline dropdown to reflect a new selection without reopening it.
func _reset_vr_dropdown(k: String, new_id: Variant) -> void:
	var entry: Variant = _controls_opts.get(k)
	if not entry is Dictionary:
		return
	var d := entry as Dictionary
	var toggle := d.get("toggle") as Button
	var panel  := d.get("panel")  as PanelContainer
	var opt_btns: Array = d.get("opt_btns", [])
	var ids: Array      = d.get("ids",      [])
	var options: Array  = d.get("options",  [])

	var new_label := ""
	for i: int in range(options.size()):
		if options[i][1] == new_id:
			new_label = options[i][0] as String
			break
	if toggle:
		toggle.text = new_label + " ▾"
	for i: int in range(opt_btns.size()):
		var btn := opt_btns[i] as Button
		if btn:
			btn.text = ("✓  " if ids[i] == new_id else "    ") + (options[i][0] as String)
	if panel:
		panel.visible = false
	if _open_dropdown_key == k:
		_open_dropdown_key = ""


## Build a label + inline-expandable dropdown row that lives entirely inside the
## ScrollContainer (no floating PopupMenu window).  All buttons use
## ACTION_MODE_BUTTON_PRESS so trigger-release never activates them.
## options: Array of [display_name, id] where id is int or String.
func _make_vr_dropdown_row(
		key: String,
		label_text: String,
		options: Array,
		current_id: Variant,
		on_changed: Callable,
		grid_cols: int = 1
) -> VBoxContainer:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 0)

	# ── Header row ────────────────────────────────────────────────────────────
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	wrapper.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var init_label := ""
	for opt_entry: Array in options:
		if opt_entry[1] == current_id:
			init_label = opt_entry[0] as String
			break

	var toggle := Button.new()
	toggle.text = init_label + " ▾"
	toggle.custom_minimum_size = Vector2(220, 52)
	toggle.add_theme_font_size_override("font_size", 18)
	toggle.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	toggle.focus_mode = Control.FOCUS_NONE
	row.add_child(toggle)

	# ── Dropdown panel ────────────────────────────────────────────────────────
	var panel := PanelContainer.new()
	panel.visible = false
	var ps := StyleBoxFlat.new()
	ps.bg_color = Color(0.10, 0.10, 0.22, 0.97)
	ps.border_color = Color(0.35, 0.35, 0.65)
	for side in ["border_width_left", "border_width_right",
			"border_width_top", "border_width_bottom"]:
		ps.set(side, 2)
	for k2 in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		ps.set(k2, 6)
	panel.add_theme_stylebox_override("panel", ps)
	wrapper.add_child(panel)

	var list := GridContainer.new()
	list.columns = max(1, grid_cols)
	list.add_theme_constant_override("h_separation", 4)
	list.add_theme_constant_override("v_separation", 2)
	panel.add_child(list)

	var opt_btns: Array[Button] = []
	var ids: Array = []

	for i: int in range(options.size()):
		var opt_entry: Array = options[i]
		var opt_label := opt_entry[0] as String
		var opt_id: Variant = opt_entry[1]
		ids.append(opt_id)

		var opt_btn := Button.new()
		opt_btn.text = ("✓  " if opt_id == current_id else "    ") + opt_label
		opt_btn.custom_minimum_size = Vector2(0, 40 if grid_cols > 1 else 48)
		opt_btn.add_theme_font_size_override("font_size", 16 if grid_cols > 1 else 18)
		opt_btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		opt_btn.focus_mode = Control.FOCUS_NONE
		opt_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT

		var captured_id:  Variant = opt_id
		var captured_lbl := opt_label
		opt_btn.pressed.connect(func() -> void:
			on_changed.call(captured_id)
			toggle.text = captured_lbl + " ▾"
			for j: int in range(opt_btns.size()):
				opt_btns[j].text = ("✓  " if ids[j] == captured_id else "    ") \
						+ (options[j][0] as String)
			panel.visible = false
			if _open_dropdown_key == key:
				_open_dropdown_key = ""
		)
		list.add_child(opt_btn)
		opt_btns.append(opt_btn)

	toggle.pressed.connect(func() -> void:
		if _open_dropdown_key != "" and _open_dropdown_key != key:
			_close_dropdown(_open_dropdown_key)
		var opening := not panel.visible
		panel.visible = opening
		_open_dropdown_key = key if opening else ""
		var base := toggle.text.trim_suffix(" ▾").trim_suffix(" ▴")
		toggle.text = base + (" ▴" if opening else " ▾")
	)

	_controls_opts[key] = {
		"toggle": toggle, "panel": panel,
		"opt_btns": opt_btns, "ids": ids, "options": options
	}
	return wrapper


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

	if get_viewport().use_xr:
		_build_xr_controls(vbox)
	else:
		_build_desktop_controls(vbox)

	# Physical gamepad section — shown in both modes (a real pad works whether
	# the player is in VR or at the desktop). Added unconditionally because
	# get_viewport().use_xr is unreliable inside this SubViewport-hosted menu.
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

	for src: String in _BUTTON_SOURCE_ORDER:
		var label: String = ControllerBindings.BUTTON_SOURCE_LABELS.get(src, src)
		var current_bit: int = _edit_button_map.get(src, -1)
		var captured_src := src
		vbox.add_child(_make_vr_dropdown_row(
			"btn:" + src, label, _JOYPAD_OPTIONS, current_bit,
			func(v: Variant) -> void: _edit_button_map[captured_src] = v as int,
			4
		))

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
			func(v: Variant) -> void: _edit_stick_map[captured_stick] = v as String,
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
			func(v: Variant) -> void: _edit_lightgun_map[captured_src] = v as int,
			4
		))

	# Thumbstick mode row
	var stick_label: String = ControllerBindings.LIGHTGUN_SOURCE_LABELS.get("stick", "Thumbstick")
	var cur_stick_mode: String = str(_edit_lightgun_map.get("stick", "dpad"))
	vbox.add_child(_make_vr_dropdown_row(
		"gun:stick", stick_label,
		[["None", "none"], ["D-pad", "dpad"]],
		cur_stick_mode,
		func(v: Variant) -> void: _edit_lightgun_map["stick"] = v as String,
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

	var save_btn := Button.new()
	save_btn.text = "Save as Global"
	save_btn.custom_minimum_size = Vector2(220, 52)
	save_btn.add_theme_font_size_override("font_size", 18)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_controls_save_global)
	action_row.add_child(save_btn)


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


func _on_controls_save_global() -> void:
	ControllerBindings.save_global(_edit_button_map, _edit_stick_map, _edit_lightgun_map)
	controller_bindings_changed.emit()


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

	# ── Buttons (press-to-rebind; joypad presses reach us in VR and desktop) ──
	var btn_hdr := Label.new()
	btn_hdr.text = "Buttons"
	btn_hdr.add_theme_font_size_override("font_size", 18)
	btn_hdr.add_theme_color_override("font_color", COLOR_LICENSE)
	vbox.add_child(btn_hdr)

	for target: String in GamepadBindings.TARGET_ORDER:
		vbox.add_child(_make_pad_rebind_row(target))

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
			func(v: Variant) -> void: _edit_pad_stick_map[captured_stick] = v as String,
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
	var btn: Button = _pad_rebind_buttons.get(target) as Button
	if is_instance_valid(btn):
		var cur: String = _edit_pad_button_map.get(target, "none")
		btn.text = GamepadBindings.binding_display_name(cur)


func _on_pad_controls_reset() -> void:
	_edit_pad_button_map = GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
	_edit_pad_stick_map  = GamepadBindings.DEFAULT_STICK_MAP.duplicate()
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
		btn.text = "✂️"
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
			btn.text = "✂️"
			btn.disabled = false
		_hide_scrape_status()
		print("[SpawnMenu] Scrape completed for: %s" % rom_path.get_file())
		_show_scrape_popup(rom_path, systemid, result)

	failed_cb = func(error: String):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = "✂️"
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
		return

	_scrape_status_bar = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.10, 0.28, 0.96)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_status_bar.add_theme_stylebox_override("panel", bg)

	# Anchor horizontally centered at the very bottom of the menu viewport.
	_scrape_status_bar.anchor_left   = 0.1
	_scrape_status_bar.anchor_right  = 0.9
	_scrape_status_bar.anchor_top    = 1.0
	_scrape_status_bar.anchor_bottom = 1.0
	_scrape_status_bar.offset_top    = -54.0
	_scrape_status_bar.offset_bottom = -8.0

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

	add_child(_scrape_status_bar)


func _update_scrape_status(msg: String) -> void:
	if _scrape_status_label != null and is_instance_valid(_scrape_status_label):
		_scrape_status_label.text = msg


func _hide_scrape_status() -> void:
	if _scrape_status_bar != null and is_instance_valid(_scrape_status_bar):
		_scrape_status_bar.queue_free()
	_scrape_status_bar = null
	_scrape_status_label = null


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
				return ImageTexture.create_from_image(img)
	return null


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

func _sync_vscrollbar() -> void:
	pass # no longer used


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
	]
	for entry: Array in LIBS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.custom_minimum_size = Vector2(0, 52)
		vbox.add_child(row)

		var left := VBoxContainer.new()
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		left.add_theme_constant_override("separation", 2)
		row.add_child(left)

		var name_lbl := Label.new()
		name_lbl.text = entry[0] as String
		name_lbl.add_theme_font_size_override("font_size", 18)
		name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		left.add_child(name_lbl)

		var author_sub := Label.new()
		author_sub.text = entry[1] as String
		author_sub.add_theme_font_size_override("font_size", 14)
		author_sub.add_theme_color_override("font_color", COLOR_LICENSE)
		left.add_child(author_sub)

		var lic_lbl := Label.new()
		lic_lbl.text = entry[2] as String
		lic_lbl.add_theme_font_size_override("font_size", 16)
		lic_lbl.add_theme_color_override("font_color", COLOR_DESC)
		lic_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(lic_lbl)

		vbox.add_child(HSeparator.new())

	vbox.add_child(_spacer(12))
	return scroll


func _spacer(height: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, height)
	return c


# ── Scene View ─────────────────────────────────────────────────────────────────

func _get_scene_manager() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("SceneManager")


const COLOR_SCENE_ACTIVE   := Color(0.3, 0.5, 0.3)
const COLOR_SCENE_INACTIVE := Color(0.15, 0.15, 0.30)
const COLOR_BTN_SAVE       := Color(0.15, 0.45, 0.15)
const COLOR_BTN_CLEAR      := Color(0.50, 0.15, 0.15)
const COLOR_BTN_LOAD       := Color(0.15, 0.30, 0.55)
const COLOR_SLOT_ACTIVE    := Color(0.20, 0.42, 0.20)
const COLOR_SLOT_NORMAL    := Color(0.12, 0.12, 0.27)


func _build_scene_view() -> Control:
	# Root container — two panels stack here via PRESET_FULL_RECT.
	var root := Control.new()
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# ── Level 1: Rooms panel ──────────────────────────────────────────────────
	var rooms_scroll := ScrollContainer.new()
	rooms_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rooms_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rooms_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scene_scroll = rooms_scroll
	_scene_rooms_panel = rooms_scroll
	root.add_child(rooms_scroll)

	var rooms_vbox := VBoxContainer.new()
	rooms_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rooms_vbox.add_theme_constant_override("separation", 14)
	rooms_scroll.add_child(rooms_vbox)

	rooms_vbox.add_child(_spacer(10))

	var hdr := Label.new()
	hdr.text = "SCENES"
	hdr.add_theme_font_size_override("font_size", 24)
	hdr.add_theme_color_override("font_color", COLOR_TITLE)
	rooms_vbox.add_child(hdr)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	rooms_vbox.add_child(grid)

	# Arcade Room card → navigates to state grid
	grid.add_child(_make_room_card("Arcade Room", Color(0.15, 0.13, 0.35), _show_states_view))

	# Passthrough card (only if supported) → direct scene switch
	var sm := _get_scene_manager()
	if sm and sm.is_passthrough_supported():
		grid.add_child(_make_room_card("Passthrough AR", Color(0.85, 0.85, 0.9),
			func(): scene_change_requested.emit("passthrough")))

	# ── Level 2: States panel ─────────────────────────────────────────────────
	var states_root := VBoxContainer.new()
	states_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	states_root.add_theme_constant_override("separation", 0)
	states_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	states_root.visible = false
	_scene_states_panel = states_root
	root.add_child(states_root)

	# Back / title row
	var back_row := HBoxContainer.new()
	back_row.add_theme_constant_override("separation", 8)
	back_row.custom_minimum_size = Vector2(0, 52)
	states_root.add_child(back_row)

	var back_btn := Button.new()
	back_btn.text = "← Back"
	back_btn.add_theme_font_size_override("font_size", 20)
	back_btn.pressed.connect(_show_rooms_view)
	back_row.add_child(back_btn)

	var title_lbl := Label.new()
	title_lbl.text = "Arcade Room"
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	back_row.add_child(title_lbl)

	# Spacer so title stays centered despite back button width
	var back_spacer := Control.new()
	back_spacer.custom_minimum_size = back_btn.custom_minimum_size
	back_spacer.size_flags_horizontal = Control.SIZE_SHRINK_END
	back_row.add_child(back_spacer)

	# Slot scroll
	var states_scroll := ScrollContainer.new()
	states_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	states_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scene_states_scroll = states_scroll
	states_root.add_child(states_scroll)

	var states_vbox := VBoxContainer.new()
	states_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	states_vbox.add_theme_constant_override("separation", 10)
	_scene_states_vbox = states_vbox
	states_scroll.add_child(states_vbox)

	# Bottom bar: Save New
	var bottom_bar := HBoxContainer.new()
	bottom_bar.custom_minimum_size = Vector2(0, 64)
	bottom_bar.add_theme_constant_override("separation", 0)
	states_root.add_child(bottom_bar)

	var save_new_btn := Button.new()
	save_new_btn.text = "  + Save New  "
	save_new_btn.add_theme_font_size_override("font_size", 22)
	save_new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_new_btn.custom_minimum_size = Vector2(0, 64)
	var sn_style := StyleBoxFlat.new()
	sn_style.bg_color = COLOR_BTN_SAVE
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		sn_style.set(k, 6)
	save_new_btn.add_theme_stylebox_override("normal", sn_style)
	save_new_btn.pressed.connect(func(): scene_slot_create_requested.emit())
	bottom_bar.add_child(save_new_btn)

	return root


func _make_room_card(label_text: String, thumb_color: Color, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 120)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_vbox := VBoxContainer.new()
	card_vbox.add_theme_constant_override("separation", 6)
	card_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(card_vbox)

	var thumb := PanelContainer.new()
	thumb.custom_minimum_size = Vector2(0, 70)
	thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var thumb_style := StyleBoxFlat.new()
	thumb_style.bg_color = thumb_color
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		thumb_style.set(k, 4)
	thumb.add_theme_stylebox_override("panel", thumb_style)
	card_vbox.add_child(thumb)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", COLOR_TITLE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_vbox.add_child(lbl)

	btn.pressed.connect(on_press)
	return btn


## Update arcade room card highlight (called when entering the rooms panel).
func _update_room_card_highlights() -> void:
	# Currently the room cards are plain buttons with no active-state tracking.
	# Extend here if a visual active indicator for "Arcade Room" is desired.
	pass


## Rebuild the slot grid inside _scene_states_vbox.
func _rebuild_states_grid() -> void:
	if not _scene_states_vbox:
		return
	for child in _scene_states_vbox.get_children():
		child.queue_free()
	_scene_hover_timer.clear()

	var persistence := ScenePersistence.new()
	var slots := persistence.get_slots()
	var sm := _get_scene_manager()
	var active_id: String = sm.active_slot_id if sm else "clean"

	for slot: Dictionary in slots:
		var card := _make_state_card(slot, active_id)
		_scene_states_vbox.add_child(card)

	_scene_states_vbox.add_child(_spacer(8))


func _make_state_card(slot: Dictionary, active_slot_id: String) -> Control:
	var slot_id: String   = slot.get("id", "")
	var slot_name: String = slot.get("name", "")
	var readonly: bool    = slot.get("readonly", false)
	var is_active: bool   = (slot_id == active_slot_id)
	var is_renaming: bool = (slot_id == _scene_rename_slot_id)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 90)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_style := StyleBoxFlat.new()
	card_style.bg_color = COLOR_SLOT_ACTIVE if is_active else COLOR_SLOT_NORMAL
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		card_style.set(k, 6)
	if is_active:
		card_style.border_width_top = 2
		card_style.border_width_bottom = 2
		card_style.border_width_left = 2
		card_style.border_width_right = 2
		card_style.border_color = Color(0.5, 0.8, 0.5)
	panel.add_theme_stylebox_override("panel", card_style)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 4)
	inner.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_child(inner)

	# Name row
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	name_row.mouse_filter = Control.MOUSE_FILTER_PASS
	inner.add_child(name_row)

	if is_renaming:
		var edit := LineEdit.new()
		edit.text = slot_name
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.add_theme_font_size_override("font_size", 20)
		_scene_rename_edit = edit
		# Meta XR overlay keyboard bounce fix (same pattern as options fields)
		edit.focus_entered.connect(func() -> void:
			if is_instance_valid(edit) and edit.get_meta("kb_cooling", false):
				edit.release_focus.call_deferred()
		)
		edit.text_submitted.connect(func(_t: String) -> void:
			_finish_rename()
		)
		edit.focus_exited.connect(func() -> void:
			_finish_rename()
		)
		name_row.add_child(edit)
	elif readonly:
		var name_lbl := Label.new()
		name_lbl.text = slot_name
		name_lbl.add_theme_font_size_override("font_size", 20)
		name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(name_lbl)
	else:
		var name_btn := Button.new()
		name_btn.text = slot_name
		name_btn.add_theme_font_size_override("font_size", 20)
		name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_btn.flat = true
		name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_btn.pressed.connect(_start_rename.bind(slot_id, slot_name))
		name_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, null))
		name_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, null))
		name_row.add_child(name_btn)

	if is_active:
		var dot := Label.new()
		dot.text = "●"
		dot.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
		dot.add_theme_font_size_override("font_size", 18)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_row.add_child(dot)

	# Action row (hidden until hover)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	action_row.visible = false
	action_row.mouse_filter = Control.MOUSE_FILTER_PASS
	inner.add_child(action_row)

	var load_btn := _make_action_btn("Load", COLOR_BTN_LOAD)
	load_btn.pressed.connect(func(): scene_slot_load_requested.emit(slot_id))
	load_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
	load_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
	action_row.add_child(load_btn)

	if not readonly:
		var save_btn := _make_action_btn("Save", COLOR_BTN_SAVE)
		save_btn.pressed.connect(func(): scene_slot_save_requested.emit(slot_id))
		save_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
		save_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
		action_row.add_child(save_btn)

		var del_btn := _make_action_btn("Delete", COLOR_BTN_CLEAR)
		del_btn.pressed.connect(func(): scene_slot_delete_requested.emit(slot_id))
		del_btn.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
		del_btn.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))
		action_row.add_child(del_btn)

	# Hover on the outer panel itself
	panel.mouse_entered.connect(_on_card_hover_enter.bind(slot_id, action_row))
	panel.mouse_exited.connect(_on_card_hover_exit.bind(slot_id, action_row))

	return panel


func _make_action_btn(label_text: String, bg_color: Color) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.add_theme_font_size_override("font_size", 18)
	btn.custom_minimum_size = Vector2(80, 36)
	var s := StyleBoxFlat.new()
	s.bg_color = bg_color
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		s.set(k, 4)
	btn.add_theme_stylebox_override("normal", s)
	return btn


func _on_card_hover_enter(slot_id: String, action_row: HBoxContainer) -> void:
	_scene_hover_timer[slot_id] = false
	if action_row:
		action_row.visible = true


func _on_card_hover_exit(slot_id: String, action_row: HBoxContainer) -> void:
	_scene_hover_timer[slot_id] = true
	(func(): _deferred_card_hide(slot_id, action_row)).call_deferred()


func _deferred_card_hide(slot_id: String, action_row: HBoxContainer) -> void:
	if _scene_hover_timer.get(slot_id, false):
		if is_instance_valid(action_row):
			action_row.visible = false
		_scene_hover_timer.erase(slot_id)


func _start_rename(slot_id: String, current_name: String) -> void:
	_scene_rename_slot_id = slot_id
	_scene_rename_edit = null
	_rebuild_states_grid()
	# Don't programmatically grab_focus() — it causes Android EditText desync
	# (Godot #72969). The user taps the LineEdit to focus it, which naturally
	# opens the overlay keyboard via virtual_keyboard_enabled (default true).


func _finish_rename() -> void:
	# Guard: if already cleared (e.g. called twice), bail immediately.
	if _scene_rename_slot_id.is_empty():
		return
	var edit := _scene_rename_edit
	var slot_id := _scene_rename_slot_id
	# Clear state first so any re-entrant calls are no-ops.
	_scene_rename_slot_id = ""
	_scene_rename_edit = null
	var new_name := edit.text.strip_edges() if edit else ""
	if not new_name.is_empty():
		scene_slot_rename_requested.emit(slot_id, new_name)
	_rebuild_states_grid()
