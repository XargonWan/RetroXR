## Save-state UI self-tests — the decisions the States tab makes, headless.
##
##     "$godot" --headless --path RetroXR res://Tests/state_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is here is what can be decided without a core: where the tab sits, which
## list the thumbstick drives, which buttons a blocker greys out, and the
## arm-then-confirm machine that stands between a press and a destroyed file.
## Capturing and restoring need a real core and live in Tools/state_probe.tscn;
## how any of this LOOKS needs a GPU and lives in Tools/cart_states_probe.tscn.
##
## The tab-order case is the regression record for a landmine this feature
## tripped: _sync_active_scroll() hard-coded `current_tab == 1`, so inserting a
## tab silently pointed the stick at the wrong page — and a corrected constant
## would only have re-armed it.
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[state-ui] TIMEOUT")
		get_tree().quit(1))
	_test_tab_order()
	_test_active_scroll_follows_the_tab()
	_test_rows()
	_test_blocked()
	_test_armed_row()
	_test_arm_ladder()
	_test_thumb_cache()
	_test_backup_notice()
	print("[state-ui] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[state-ui] PASS  %s" % name)
	else:
		_fail += 1
		print("[state-ui] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


## A built view in the tree. Caller frees it.
func _ui() -> CartridgeOptions2D:
	var ui := CartridgeOptions2D.new()
	add_child(ui)
	return ui


func _tabs_of(ui: CartridgeOptions2D) -> TabContainer:
	return _find(ui, "TabContainer") as TabContainer


func _find(node: Node, cls: String) -> Node:
	if node.is_class(cls):
		return node
	for child in node.get_children():
		var got := _find(child, cls)
		if got != null:
			return got
	return null


func _titles(tabs: TabContainer) -> Array:
	var out: Array = []
	for i in range(tabs.get_tab_count()):
		out.append(tabs.get_tab_title(i))
	return out


## Every Button under `node`, in tree order.
func _buttons(node: Node, into: Array = []) -> Array:
	if node is Button:
		into.append(node)
	for child in node.get_children():
		_buttons(child, into)
	return into


## Children that are actually still there. populate_states() frees the old rows
## with queue_free(), which does not take effect until the frame ends, so a
## plain get_child_count() after a second populate counts both lists.
func _live_children(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		if not child.is_queued_for_deletion():
			n += 1
	return n


func _rows(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({
			"state_id": "%d-%06x" % [1787000000000 + i * 1000, i * 4919],
			"path": "", "shot": "", "meta": "",
			"mtime": 1787000000 - i * 60, "bytes": 4096 * (i + 1),
		})
	return out


# ---------------------------------------------------------------------------

func _test_tab_order() -> void:
	var ui := _ui()
	var tabs := _tabs_of(ui)
	_ok("tabs/there is a tab strip", tabs != null)
	if tabs != null:
		# The asked-for position: between Saves and Achievements.
		_eq("tabs/order", _titles(tabs), ["Saves", "States", "Achievements"])
	ui.free()


func _test_active_scroll_follows_the_tab() -> void:
	var ui := _ui()
	var tabs := _tabs_of(ui)
	if tabs == null:
		ui.free()
		return
	for i in range(tabs.get_tab_count()):
		tabs.current_tab = i
		# tab_changed drives _sync_active_scroll; call it too so the case does not
		# depend on the signal having been emitted for an unchanged index.
		ui._sync_active_scroll()
		var scroll: ScrollContainer = ui._active_scroll
		var page := tabs.get_current_tab_control()
		_ok("scroll/%s drives its own list" % tabs.get_tab_title(i),
			scroll != null and (scroll == page or page.is_ancestor_of(scroll)),
			"tab %d got %s" % [i, str(scroll)])
	ui.free()


func _test_rows() -> void:
	var ui := _ui()
	ui.populate_states(_rows(3), 3 * 4096)
	_eq("rows/one plate per state", _live_children(ui._states_box), 3)
	_ok("rows/the header counts them", ui._state_total_lbl.text.begins_with("3 states"),
		ui._state_total_lbl.text)
	_ok("rows/and sizes them", ui._state_total_lbl.text.ends_with("KB"),
		ui._state_total_lbl.text)

	# The singular matters: "1 states" is the kind of thing nobody notices until
	# it ships.
	ui.populate_states(_rows(1), 4096)
	_ok("rows/one state, not one states", ui._state_total_lbl.text.begins_with("1 state  "),
		ui._state_total_lbl.text)

	ui.populate_states([], 0)
	_eq("rows/empty says so", _live_children(ui._states_box), 1)

	# A server row is offered even with nothing local, or a state pulled to a new
	# device would be invisible.
	ui.populate_states([], 0, {}, [{"state_id": "1787000000000-000001",
		"updated_at": "2026-08-17T21:00:00", "size": 4096}])
	_ok("rows/a server-only state is listed", _live_children(ui._states_box) >= 2)
	ui.free()


func _test_blocked() -> void:
	var ui := _ui()
	ui.capture_blocked = "no machine is running this game"
	ui.populate_states(_rows(2), 8192)
	_ok("blocked/capture is disabled", ui._state_capture_btn.disabled)
	_eq("blocked/and says why", ui._state_capture_btn.tooltip_text,
		"no machine is running this game")
	# Overwrite writes too, so the same blocker has to reach it. Missing this is
	# how a greyed-out header sits above three live overwrite buttons.
	var disabled := 0
	var enabled := 0
	for b: Variant in _buttons(ui._states_box):
		if (b as Button).tooltip_text == "no machine is running this game":
			disabled += 1
		elif (b as Button).tooltip_text.begins_with("Save over"):
			enabled += 1
	_eq("blocked/every overwrite button too", [disabled, enabled], [2, 0])

	ui.capture_blocked = ""
	ui.populate_states(_rows(2), 8192)
	_ok("blocked/and they come back", not ui._state_capture_btn.disabled)
	ui.free()


func _test_armed_row() -> void:
	var ui := _ui()
	var rows := _rows(3)
	ui.states_armed_id = str(rows[1]["state_id"])
	ui.states_armed_action = "overwrite"
	ui.populate_states(rows, 3 * 4096)
	var warned := 0
	for lbl: Variant in _labels(ui._states_box):
		if str((lbl as Label).text).begins_with("Press again to save over"):
			warned += 1
	_eq("armed/exactly one row asks again", warned, 1)

	ui.states_armed_action = "delete"
	ui.populate_states(rows, 3 * 4096)
	var bins := 0
	for lbl: Variant in _labels(ui._states_box):
		if str((lbl as Label).text).begins_with("Press the bin again"):
			bins += 1
	_eq("armed/the bin asks its own question", bins, 1)
	ui.free()


func _labels(node: Node, into: Array = []) -> Array:
	if node is Label:
		into.append(node)
	for child in node.get_children():
		_labels(child, into)
	return into


## Arm, then do — and one arm slot between the two destructive actions, so a row
## is never waiting on two different confirmations at once.
func _test_arm_ladder() -> void:
	var panel := CartridgeOptionsPanel.new()
	add_child(panel)

	_ok("arm/the first press only arms", not panel._arm_state("A", "overwrite"))
	_eq("arm/and the row remembers which", [panel._states_armed_id, panel._states_armed_action],
		["A", "overwrite"])
	_ok("arm/the second press confirms", panel._arm_state("A", "overwrite"))
	_eq("arm/and disarms", panel._states_armed_id, "")

	# The other action on the SAME row: arming it must not inherit the first
	# one's confirmation.
	_ok("arm/overwrite arms", not panel._arm_state("A", "overwrite"))
	_ok("arm/then the bin only arms", not panel._arm_state("A", "delete"))
	_eq("arm/the bin took the slot", panel._states_armed_action, "delete")
	_ok("arm/and overwrite is no longer confirmable",
		not panel._arm_state("A", "overwrite"))

	# A different row takes the slot rather than sharing it.
	_ok("arm/another row only arms", not panel._arm_state("B", "overwrite"))
	_eq("arm/and owns the slot now", panel._states_armed_id, "B")
	panel.free()


## Why there is no RomM column, when there isn't one.
##
## The bug this pins shipped: with backup on and the server up, a hand-copied ROM
## has no RomM id, so the column vanished and every row read "On this device"
## with nothing anywhere saying why — indistinguishable from the feature being
## missing. Each branch has to name the one thing the player could act on.
func _test_backup_notice() -> void:
	var panel := CartridgeOptionsPanel.new()
	add_child(panel)
	var cfg := RommConfig.new()
	cfg.enabled = true
	cfg.base_url = "http://127.0.0.1:1"
	cfg.token = "x"

	# No server at all is not a problem to report — RomM simply is not part of
	# how this player uses the app, and a nag on every cartridge would be noise.
	var saved_save_cfg: RommConfig = SaveSync.config
	var saved_state_cfg: RommConfig = StateSync.config
	SaveSync.config = RommConfig.new()
	StateSync.config = cfg
	_eq("notice/an unconfigured server says nothing", panel._backup_notice("fceumm", []), "")

	# Configured, but the switch is off: name the switch, not the symptom.
	SaveSync.config = cfg
	cfg.backup_enabled = false
	var off := panel._backup_notice("fceumm", [])
	_ok("notice/the switch being off names the switch",
		off.contains("Back up saves and states") and off.contains("OPTIONS"), off)

	# Switch on, server up, but this game is not on RomM. _rom_id() is 0 here
	# because the panel has no cartridge bound at all, which is the same answer a
	# hand-copied ROM gives.
	cfg.backup_enabled = true
	var unknown := panel._backup_notice("fceumm", [])
	_ok("notice/a game RomM does not have says so",
		unknown.contains("RomM does not have this game"), unknown)

	SaveSync.config = saved_save_cfg
	StateSync.config = saved_state_cfg
	panel.free()


func _test_thumb_cache() -> void:
	var ui := _ui()
	# A path that decodes to nothing still caches, or every repopulate retries a
	# file that is not there.
	var missing := "user://__no_such_state_shot.png"
	_eq("thumb/a missing picture is null", ui._thumb(missing), null)
	_ok("thumb/and is remembered as null", ui._thumb_cache.has(missing))

	var path := "user://__state_tests_shot.png"
	var img := Image.create(32, 24, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.4, 0.8))
	img.save_png(path)
	var first := ui._thumb(path)
	_ok("thumb/a real picture decodes", first != null)
	_ok("thumb/and is not decoded twice", ui._thumb(path) == first)
	# An overwrite writes a NEW picture to the SAME path, so the cache has to be
	# told or the row keeps showing the frame it replaced.
	ui.forget_thumb(path)
	_ok("thumb/forgetting it forces a re-read", not ui._thumb_cache.has(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	ui.free()
