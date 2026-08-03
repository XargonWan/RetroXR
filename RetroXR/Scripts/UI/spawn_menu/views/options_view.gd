## SpawnMenuOptionsView — the menu's OPTIONS tab: comfort settings, the on/off
## switches, and the RomM / ScreenScraper server setup.
##
## Unlike the other tabs this one is a control surface over services the menu
## owns, so it is handed them by setup() rather than reaching for them. What it
## cannot do itself it asks for by signal; the comfort rows all report upward,
## because applying them means touching the XR rig.
class_name SpawnMenuOptionsView
extends ScrollContainer

signal turn_style_changed(value: String)
signal snap_angle_changed(degrees: float)
signal height_offset_changed(offset: float)
signal fov_changed(degrees: float)
signal world_scale_changed(scale: float)
signal auto_save_changed(enabled: bool)
signal show_fps_changed(enabled: bool)
signal aim_crosshair_changed(enabled: bool)
## True to aim a teleport with the left stick, false to slide with it.
signal locomotion_mode_changed(teleport: bool)
signal controller_hands_changed(enabled: bool)
## The system filter was toggled — the CORES download list is built from it.
signal system_filter_changed
## Ask the menu to re-read the RomM platform list. It owns the result, because
## the cartridge browser reads it too.
signal romm_platforms_requested

# Services, injected by setup(). Named exactly as the menu names them so the
# rows below read the same as they did when they lived there.
var romm_config: RommConfig = null
var romm_client: RommClient = null
var romm_catalog: RommCatalog = null
var romm_cache: RommCacheManifest = null
var romm_art: RommArtCache = null
var scraper_config: ScraperConfig = null
var web_server: WebFileServer = null

## The menu, for the two things this view reads rather than owns: the RomM
## platform map (shared with the cartridge browser) and the toast stack. Typed
## as Node, not SpawnMenu2D — the two classes would otherwise name each other,
## which GDScript resolves badly.
var _menu: Node = null

var _server_address_label: Label = null
var _romm_status_label: Label = null
var _romm_sync_queue: Array[String] = []

# Kept so a pairing (typed or scanned) can show its result in the fields the
# player is looking at, rather than waiting for the view to be rebuilt.
var _romm_url_edit: LineEdit = null
var _romm_token_edit: LineEdit = null
var _qr_overlay: QrScanOverlay = null
var _last_scan_frame: int = -1

# Only one sign-in method applies at a time, so the other one's rows are hidden
# rather than left there to be filled in and quietly ignored.
## Matches the separation and field width _add_options_text_field lays out with.
const ROW_SEPARATION := 10
const SCAN_BTN_WIDTH := 64

var _romm_mode_drop: VRDropdown = null
var _romm_token_rows: Array[Control] = []
var _romm_basic_rows: Array[Control] = []


static func create(menu: Node) -> SpawnMenuOptionsView:
	var v := SpawnMenuOptionsView.new()
	v._menu = menu
	v.romm_config    = menu.romm_config
	v.romm_client    = menu.romm_client
	v.romm_catalog   = menu.romm_catalog
	v.romm_cache     = menu.romm_cache
	v.romm_art       = menu.romm_art
	v.scraper_config = menu.scraper_config
	v.web_server     = menu.web_server
	v._build()
	return v


## SceneManager is an autoload, but every caller in the project guards the
## lookup rather than naming the global, so this does too.
static func _scene_manager() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("SceneManager")


func _platforms() -> Dictionary:
	return _menu.romm_platforms() if _menu else {}


func _unmapped() -> Array:
	return _menu.romm_unmapped() if _menu else []


func notify(key: String, icon: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _menu:
		_menu.notify(key, icon, msg, progress, seconds)

func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := MenuStyle.vbox(14)
	add_child(vbox)

	vbox.add_child(MenuStyle.spacer(10))

	if MenuStyle.is_vr_mode():
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
		fov_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		fov_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fov_header.add_child(fov_lbl)

		var fov_val := Label.new()
		fov_val.text = "75°"
		fov_val.add_theme_font_size_override("font_size", 20)
		fov_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
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
	ho_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	ho_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ho_header.add_child(ho_lbl)

	var ho_val := Label.new()
	ho_val.text = "0.00 m"
	ho_val.add_theme_font_size_override("font_size", 20)
	ho_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
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
	if MenuStyle.is_vr_mode():
		var ws_header := HBoxContainer.new()
		ws_header.add_theme_constant_override("separation", 10)
		vbox.add_child(ws_header)

		var ws_lbl := Label.new()
		ws_lbl.text = "World Scale"
		ws_lbl.add_theme_font_size_override("font_size", 22)
		ws_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		ws_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ws_header.add_child(ws_lbl)

		var ws_val := Label.new()
		ws_val.add_theme_font_size_override("font_size", 20)
		ws_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
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
		var sm_ws := _scene_manager()
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
	as_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	as_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	as_row.add_child(as_lbl)

	as_row.add_child(VRToggle.create(AppPrefs.auto_save_scene, func(on: bool) -> void:
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
	fps_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	fps_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fps_row.add_child(fps_lbl)

	fps_row.add_child(VRToggle.create(AppPrefs.show_fps, func(on: bool) -> void:
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
		spatial_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		spatial_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spatial_row.add_child(spatial_lbl)

		# Applied straight away for everything in the room. A system that is
		# already switched on keeps the backend it booted with; see
		# SpatialAudioListener.set_sdk_enabled.
		spatial_row.add_child(VRToggle.create(AppPrefs.spatial_audio_sdk, func(on: bool) -> void:
			AppPrefs.spatial_audio_sdk = on
			AppPrefs.save_prefs()
			SpatialAudioListener.set_sdk_enabled(on)
		))

		vbox.add_child(HSeparator.new())

	# Movement style. Both verbs are on the left stick and only one can be live,
	# so this is a choice, not a switch — hence a dropdown rather than a toggle.
	# VRDropdown, never OptionButton: every Viewport2Din3D click fires twice.
	var move_drop := VRDropdown.create("Movement",
		[["Slide", "slide"], ["Teleport", "teleport"]],
		"teleport" if AppPrefs.locomotion_teleport else "slide",
		2, Vector2(220, 52), 18)
	move_drop.item_selected.connect(func(id: Variant) -> void:
		AppPrefs.locomotion_teleport = str(id) == "teleport"
		AppPrefs.save_prefs()
		locomotion_mode_changed.emit(AppPrefs.locomotion_teleport)
	)
	vbox.add_child(move_drop)

	vbox.add_child(HSeparator.new())

	# Ray Gun crosshair option
	var xhair_row := HBoxContainer.new()
	xhair_row.add_theme_constant_override("separation", 10)
	xhair_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(xhair_row)

	var xhair_lbl := Label.new()
	xhair_lbl.text = "Ray Gun Crosshair"
	xhair_lbl.add_theme_font_size_override("font_size", 22)
	xhair_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	xhair_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xhair_row.add_child(xhair_lbl)

	xhair_row.add_child(VRToggle.create(AppPrefs.aim_crosshair, func(on: bool) -> void:
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
	hints_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	hints_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints_row.add_child(hints_lbl)

	# No signal: HeldHint reads AppPrefs when the object is picked up, so nothing
	# has to be told. Clearing the counts is what makes re-enabling visible —
	# without it anyone already past HeldHint.LEARNED_AFTER sees no change.
	hints_row.add_child(VRToggle.create(AppPrefs.show_hints, func(on: bool) -> void:
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
	hands_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	hands_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hands_row.add_child(hands_lbl)

	hands_row.add_child(VRToggle.create(AppPrefs.controller_hands, func(on: bool) -> void:
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

	sf_col.add_child(MenuStyle.label("Libretro System Filter", 22, MenuStyle.COLOR_TITLE))

	sf_col.add_child(MenuStyle.label("Hide %d non-console systems" % SystemFilter.hidden_ids().size(), 16, MenuStyle.COLOR_LICENSE))

	sf_row.add_child(VRToggle.create(AppPrefs.system_filter, func(on: bool) -> void:
		AppPrefs.system_filter = on
		AppPrefs.save_prefs()
		SystemFilter.enabled = on
		system_filter_changed.emit()
	))

	vbox.add_child(HSeparator.new())

	# ── File Server (Android / Quest only) ───────────────────────────────────
	if OS.get_name() == "Android":
		vbox.add_child(MenuStyle.label("FILE SERVER", 22, MenuStyle.COLOR_TITLE))

		var fs_row := HBoxContainer.new()
		fs_row.add_theme_constant_override("separation", 10)
		fs_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(fs_row)

		var fs_lbl := Label.new()
		fs_lbl.text = "Web File Manager"
		fs_lbl.add_theme_font_size_override("font_size", 20)
		fs_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		fs_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fs_row.add_child(fs_lbl)

		var fs_toggle := VRToggle.create(scraper_config.web_server_enabled, func(on: bool) -> void:
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
		_server_address_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		_server_address_label.text = "http://%s:8080   PIN: %s" % \
			[WebFileServer.local_ip(), scraper_config.ensure_web_server_pin()]
		_server_address_label.visible = scraper_config.web_server_enabled
		vbox.add_child(_server_address_label)

		vbox.add_child(HSeparator.new())

	# ── RomM server ──────────────────────────────────────────────────────────
	_build_romm_options(vbox)

	# ── Scraper settings ─────────────────────────────────────────────────────
	vbox.add_child(MenuStyle.label("SCREENSCRAPER.FR", 22, MenuStyle.COLOR_TITLE))

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




## ROMM SERVER section of the OPTIONS view.
func _build_romm_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.label("ROMM SERVER", 22, MenuStyle.COLOR_TITLE))

	var enable_row := HBoxContainer.new()
	enable_row.custom_minimum_size = Vector2(0, 68)
	enable_row.add_theme_constant_override("separation", 10)
	vbox.add_child(enable_row)

	var enable_lbl := Label.new()
	enable_lbl.text = "Enable RomM library"
	enable_lbl.add_theme_font_size_override("font_size", 20)
	enable_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	enable_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enable_row.add_child(enable_lbl)

	enable_row.add_child(VRToggle.create(romm_config.enabled, func(on: bool) -> void:
		romm_config.enabled = on
		romm_config.save_config()
		if on:
			romm_platforms_requested.emit()
	))

	_romm_url_edit = _add_options_text_field(vbox, "Server URL", romm_config.base_url,
		func(text: String) -> void:
			romm_config.base_url = RommConfig.normalize_url(text)
			romm_config.save_config()
			if romm_art != null:
				romm_art.setup(romm_config.base_url)
	)

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	_romm_mode_drop = VRDropdown.create("Sign in with",
		[["API token", RommConfig.AUTH_TOKEN],
		 ["Username + password", RommConfig.AUTH_BASIC]],
		romm_config.auth_mode, 1, Vector2(300, 56), 18)
	_romm_mode_drop.item_selected.connect(func(id: Variant) -> void:
		romm_config.auth_mode = str(id)
		romm_config.save_config()
		_apply_romm_auth_rows()
	)
	vbox.add_child(_romm_mode_drop)

	_romm_token_edit = _add_options_text_field(vbox, "API token", romm_config.token,
		func(text: String) -> void:
			romm_config.token = text.strip_edges()
			romm_config.save_config()
	, true)

	# Quest 3/3S only — everywhere else the row looks exactly as it always has.
	if QrScanner.is_available():
		var scan_btn := Button.new()
		scan_btn.text = String.chr(MenuIcons.SCAN_QR)
		scan_btn.add_theme_font_override("font", MenuIcons.symbols())
		scan_btn.add_theme_font_size_override("font_size", 26)
		scan_btn.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		scan_btn.custom_minimum_size = Vector2(SCAN_BTN_WIDTH, 48)
		scan_btn.focus_mode = Control.FOCUS_NONE
		scan_btn.tooltip_text = "Scan RomM pairing QR"
		scan_btn.pressed.connect(_on_scan_qr_pressed)
		# Narrow the field by exactly what the button costs, so the pair still
		# fills the same column as every other row and the right edges line up.
		_romm_token_edit.custom_minimum_size.x -= SCAN_BTN_WIDTH + ROW_SEPARATION
		_romm_token_edit.get_parent().add_child(scan_btn)

	var user_edit := _add_options_text_field(vbox, "Username", romm_config.username,
		func(text: String) -> void:
			romm_config.username = text.strip_edges()
			romm_config.save_config()
	)

	var pass_edit := _add_options_text_field(vbox, "Password", romm_config.password,
		func(text: String) -> void:
			romm_config.password = text
			romm_config.save_config()
	, true)

	# Device pairing: type a short code instead of a 68-character token in VR.
	# The code is alphanumeric and dashed (RomM issues e.g. MXWT-SDZE), so it is
	# not length- or digit-checked here — the server is the authority on format.
	var pair_edit := _add_options_text_field(vbox, "Pair code", "", func(text: String) -> void:
		var code := text.strip_edges()
		if code.is_empty():
			return
		if code.length() > RommPairUrl.MAX_CODE_LEN:
			notify("romm:conn", "❌", "That doesn't look like a pair code",
				-1.0, MenuToasts.DWELL_FAIL)
			return
		_apply_pair_code(code)
	)

	# Pairing yields a token, so it belongs with the token method.
	_romm_token_rows = [_romm_token_edit.get_parent(), pair_edit.get_parent()]
	_romm_basic_rows = [user_edit.get_parent(), pass_edit.get_parent()]
	_apply_romm_auth_rows()

	_add_options_text_field(vbox, "Cache budget (GB)", str(romm_config.cache_budget_gb),
		func(text: String) -> void:
			var v := text.strip_edges().to_float()
			if v > 0.0:
				romm_config.cache_budget_gb = v
				romm_config.save_config()
				update_romm_status_label()
	)

	var group_row := HBoxContainer.new()
	group_row.custom_minimum_size = Vector2(0, 68)
	group_row.add_theme_constant_override("separation", 10)
	vbox.add_child(group_row)
	var group_lbl := Label.new()
	group_lbl.text = "Group multi-region duplicates"
	group_lbl.add_theme_font_size_override("font_size", 20)
	group_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	group_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group_row.add_child(group_lbl)
	group_row.add_child(VRToggle.create(romm_config.group_by_meta_id, func(on: bool) -> void:
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
				MenuToasts.DWELL_OK if ok else MenuToasts.DWELL_FAIL)
			if ok:
				romm_platforms_requested.emit()
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
	_romm_status_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	_romm_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_romm_status_label)
	update_romm_status_label()

	vbox.add_child(HSeparator.new())


## Show only the rows the selected sign-in method uses.
func _apply_romm_auth_rows() -> void:
	var token_mode := romm_config.auth_mode == RommConfig.AUTH_TOKEN
	for row in _romm_token_rows:
		if is_instance_valid(row):
			row.visible = token_mode
	for row in _romm_basic_rows:
		if is_instance_valid(row):
			row.visible = not token_mode


## Exchange a pairing code for a scoped token. Shared by the typed field and the
## QR scanner, so both report the same way and both refresh the token field.
func _apply_pair_code(code: String) -> void:
	notify("romm:conn", "⏳", "Pairing with RomM…", -1.0)
	romm_client.pair_with_code(code, func(ok: bool, token: String, err: String) -> void:
		if not ok:
			notify("romm:conn", "❌", err, -1.0, MenuToasts.DWELL_FAIL)
			return
		romm_config.auth_mode = RommConfig.AUTH_TOKEN
		romm_config.token = token
		romm_config.enabled = true
		romm_config.save_config()
		if _romm_token_edit != null:
			_romm_token_edit.text = token
		# Pairing switches the method, so the dropdown and rows follow it.
		if is_instance_valid(_romm_mode_drop):
			_romm_mode_drop.select_id(RommConfig.AUTH_TOKEN)
		_apply_romm_auth_rows()
		var where := romm_config.base_url.trim_prefix("http://").trim_prefix("https://")
		notify("romm:conn", "✅",
			"Paired with RomM" if where.is_empty() else "Paired with RomM at %s" % where,
			-1.0, MenuToasts.DWELL_OK)
		romm_platforms_requested.emit()
	)


func _on_scan_qr_pressed() -> void:
	# Opening the overlay is not idempotent and every Viewport2Din3D click
	# arrives twice.
	var frame := Engine.get_process_frames()
	if frame == _last_scan_frame:
		return
	_last_scan_frame = frame

	if is_instance_valid(_qr_overlay):
		return

	if not QrScanner.has_permission():
		QrScanner.request_permission()
		notify("romm:qr", "⏳", "Allow camera access, then tap scan again",
			-1.0, MenuToasts.DWELL_INFO)
		return

	var host: Control = get_parent()
	if host == null:
		return

	_qr_overlay = QrScanOverlay.create(self)
	_qr_overlay.scanned.connect(_on_qr_scanned)
	host.add_child(_qr_overlay)


func _on_qr_scanned(payload: String) -> void:
	var parsed := RommPairUrl.parse(payload)
	var url := str(parsed.get("url", ""))
	var code := str(parsed.get("code", ""))

	if code.is_empty():
		notify("romm:qr", "❌", "That QR isn't a RomM pairing code",
			-1.0, MenuToasts.DWELL_FAIL)
		if is_instance_valid(_qr_overlay):
			_qr_overlay.set_status("Not a RomM pairing code — still looking…")
			_qr_overlay.resume()
		return

	var current := romm_config.base_url
	if not url.is_empty() and not current.is_empty() and url != current:
		if is_instance_valid(_qr_overlay):
			_qr_overlay.ask("Switch to %s?" % url,
				func() -> void: _commit_scan(url, code))
			return

	_commit_scan(url, code)


## The URL must be committed before the exchange — RommClient builds the request
## against the configured host. A failed exchange leaves the new URL in place so
## it stays visible and editable; silently restoring a stale address would be
## harder to recover from than a wrong one you can see.
func _commit_scan(url: String, code: String) -> void:
	if not url.is_empty():
		romm_config.base_url = url
		romm_config.save_config()
		if _romm_url_edit != null:
			_romm_url_edit.text = url
		if romm_art != null:
			romm_art.setup(url)

	if is_instance_valid(_qr_overlay):
		_qr_overlay.close()
		_qr_overlay = null

	_apply_pair_code(code)


## Sync every mapped platform, one after another — for deliberate offline
## browsing. Normal use never needs this; platforms sync when you open them.
func _on_romm_sync_all_pressed() -> void:
	if not romm_config.is_configured():
		notify("romm:conn", "❌", "Set a server URL and sign-in first", -1.0, MenuToasts.DWELL_FAIL)
		return
	if _platforms().is_empty():
		romm_platforms_requested.emit()
		return
	_romm_sync_queue.clear()
	for systemid: String in _platforms():
		_romm_sync_queue.append(systemid)
	pump_romm_sync_queue()


## Public for the same reason: the queue advances when a sync finishes, which
## the menu hears, not this view.
func pump_romm_sync_queue() -> void:
	if _romm_sync_queue.is_empty() or romm_catalog.is_syncing():
		return
	var systemid: String = _romm_sync_queue.pop_front()
	var pid := int((_platforms().get(systemid, {}) as Dictionary).get("id", 0))
	if pid > 0:
		romm_catalog.sync_platform(systemid, pid, true)


## Public: the menu owns the RomM sync signals, and a finished sync must move
## this readout even when the OPTIONS tab is not the one on screen.
func update_romm_status_label() -> void:
	if _romm_status_label == null or not is_instance_valid(_romm_status_label):
		return

	var parts: Array[String] = []
	if not romm_client.server_version.is_empty():
		parts.append("RomM %s" % romm_client.server_version)
	if not _platforms().is_empty():
		var total := 0
		for sid: String in _platforms():
			total += int((_platforms()[sid] as Dictionary).get("rom_count", 0))
		parts.append("%d games across %d platforms" % [total, _platforms().size()])
	if romm_cache != null:
		parts.append("%s cached / %.0f GB budget"
			% [MenuStyle.human_bytes(romm_cache.total_bytes()), romm_config.cache_budget_gb])

	var text := " · ".join(PackedStringArray(parts)) if not parts.is_empty() \
		else "Not connected."

	if not _unmapped().is_empty():
		# Biggest first, capped — a full list runs to dozens of engine cores and
		# one-ROM oddities that will never have a systemid.
		var sorted_un := _unmapped().duplicate()
		sorted_un.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("rom_count", 0)) > int(b.get("rom_count", 0))
		)
		var names: Array[String] = []
		for i in mini(sorted_un.size(), 6):
			var p: Dictionary = sorted_un[i]
			names.append("%s (%d)" % [RommPlatforms.display_name(p), int(p.get("rom_count", 0))])
		text += "\n%d unmapped: " % _unmapped().size() + ", ".join(PackedStringArray(names))
		if sorted_un.size() > 6:
			text += " and %d more" % (sorted_un.size() - 6)

	_romm_status_label.text = text


## Returns the LineEdit so a caller can hang a button off its row
## (edit.get_parent()) or write a value back into it.
func _add_options_text_field(parent: VBoxContainer, label_text: String,
							 initial_value: String, on_changed: Callable,
							 secret: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
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
	return edit
