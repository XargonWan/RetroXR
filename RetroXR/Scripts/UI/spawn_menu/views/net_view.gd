## SpawnMenuNetView — the menu's NET tab: host or join a LAN session, and see who
## is in it.
##
## Talks only to NetworkManager, so like the graphics tab it reports nothing back
## to the menu and has no signals. The name and last-used IP persist to
## user://net_prefs.json, kept here rather than in AppPrefs because nothing else
## reads them.
##
## It IS its own scroll container — the menu's _show_view wants a Control and a
## ScrollContainer, and for this tab they were always the same node.
##
## The keypad below was entering two digits per tap: a Viewport2Din3D delivered
## one pointer press to a Button as BOTH an InputEventScreenTouch and an
## InputEventMouseButton, and a press-mode Button fires on each. Fixed at the
## source in viewport_2d_in_3d_body.gd, which now sends the mouse pointer mouse
## events only. Release mode was never affected — the second event finds the
## button already released — which is why the rest of the menu was fine.
class_name SpawnMenuNetView
extends ScrollContainer

const PREFS_PATH := "user://net_prefs.json"

var _status_lbl:   Label = null
var _name_edit:    LineEdit = null
var _ip_edit:      LineEdit = null
var _players_box:  VBoxContainer = null
var _host_btn:     Button = null
var _join_btn:     Button = null
var _leave_btn:    Button = null


static func create() -> SpawnMenuNetView:
	var v := SpawnMenuNetView.new()
	v._build()
	return v


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := MenuStyle.vbox(10)
	add_child(vbox)

	var prefs := _load_prefs()

	vbox.add_child(MenuStyle.header("MULTIPLAYER (LAN)"))

	_status_lbl = MenuStyle.label("Not connected", 18, MenuStyle.COLOR_LICENSE)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_lbl)

	# ── Player name ───────────────────────────────────────────────────────────
	var name_row := MenuStyle.hbox(10)
	name_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(name_row)
	name_row.add_child(MenuStyle.label("Name", 20, MenuStyle.COLOR_TITLE))
	_name_edit = LineEdit.new()
	_name_edit.text = str(prefs.get("name", "Player"))
	_name_edit.max_length = 24
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_size_override("font_size", 20)
	name_row.add_child(_name_edit)

	# ── Host ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	_host_btn = _wide_button("Host Game")
	_host_btn.pressed.connect(_on_host)
	vbox.add_child(_host_btn)

	# ── Join ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var join_row := MenuStyle.hbox(10)
	join_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(join_row)
	join_row.add_child(MenuStyle.label("Host IP", 20, MenuStyle.COLOR_TITLE))
	_ip_edit = LineEdit.new()
	_ip_edit.text = str(prefs.get("ip", ""))
	_ip_edit.placeholder_text = "192.168.1.10"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip_edit.add_theme_font_size_override("font_size", 20)
	join_row.add_child(_ip_edit)
	_join_btn = Button.new()
	_join_btn.text = "  Join  "
	_join_btn.custom_minimum_size = Vector2(120, 52)
	_join_btn.add_theme_font_size_override("font_size", 20)
	_join_btn.focus_mode = Control.FOCUS_NONE
	_join_btn.pressed.connect(_on_join)
	join_row.add_child(_join_btn)

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
		kb.focus_mode = Control.FOCUS_NONE
		var captured := key
		kb.pressed.connect(func() -> void:
			if captured == "⌫":
				_ip_edit.text = _ip_edit.text.left(_ip_edit.text.length() - 1)
			else:
				_ip_edit.text += captured
		)
		pad.add_child(kb)

	# ── Players ───────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Players", 18, MenuStyle.COLOR_LICENSE))
	_players_box = MenuStyle.vbox(4, false)
	vbox.add_child(_players_box)

	# ── Disconnect ────────────────────────────────────────────────────────────
	_leave_btn = _wide_button("Disconnect")
	_leave_btn.pressed.connect(func() -> void: NetworkManager.leave_session())
	vbox.add_child(_leave_btn)

	# Live updates from the session.
	NetworkManager.status_changed.connect(func(text: String) -> void:
		if is_instance_valid(_status_lbl):
			_status_lbl.text = text
	)
	NetworkManager.session_started.connect(func(_h: bool) -> void: refresh())
	NetworkManager.session_ended.connect(func(_r: String) -> void: refresh())
	NetworkManager.peer_registered.connect(func(_i: int, _d: Dictionary) -> void: refresh())
	NetworkManager.peer_left.connect(func(_i: int) -> void: refresh())

	# Keep ping readouts fresh while the NET view is on screen.
	var ping_timer := Timer.new()
	ping_timer.wait_time = 1.0
	ping_timer.autostart = true
	ping_timer.timeout.connect(func() -> void:
		if NetworkManager.is_active() and visible:
			refresh()
	)
	vbox.add_child(ping_timer)


func _wide_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	return b


func _on_host() -> void:
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	NetworkManager.host_game()


func _on_join() -> void:
	var ip := _ip_edit.text.strip_edges()
	if not ip.is_valid_ip_address():
		if is_instance_valid(_status_lbl):
			_status_lbl.text = "Invalid IP address: '%s'" % ip
		return
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	NetworkManager.join_game(ip)


## Re-read the session and repaint.
func refresh() -> void:
	if not is_instance_valid(_players_box):
		return
	var active: bool = NetworkManager.is_active()
	_host_btn.disabled = active
	_join_btn.disabled = active
	_leave_btn.disabled = not active
	_name_edit.editable = not active

	for child in _players_box.get_children():
		child.queue_free()
	var self_id: int = NetworkManager.multiplayer.get_unique_id() if active else -1
	for id: int in NetworkManager.peers:
		var info: Dictionary = NetworkManager.peers[id]
		var row := MenuStyle.hbox(10)
		var swatch := ColorRect.new()
		swatch.color = NetworkManager.PLAYER_COLORS[int(info.get("color_idx", 0)) % NetworkManager.PLAYER_COLORS.size()]
		swatch.custom_minimum_size = Vector2(26, 26)
		row.add_child(swatch)
		var suffix := ""
		if id == 1:
			suffix += "  (host)"
		if id == self_id:
			suffix += "  (you)"
		var ping: int = NetworkManager.ping_ms(id)
		if ping > 0:
			suffix += "  %d ms" % ping
		row.add_child(MenuStyle.label("%s%s" % [info.get("name", "?"), suffix],
			18, MenuStyle.COLOR_TITLE))
		_players_box.add_child(row)


func _load_prefs() -> Dictionary:
	if not FileAccess.file_exists(PREFS_PATH):
		return {}
	var f := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"name": _name_edit.text.strip_edges(),
			"ip": _ip_edit.text.strip_edges(),
		}))
