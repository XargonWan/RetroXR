## MenuToasts — the stack of status bars along the bottom of the spawn menu.
##
## Two kinds of bar live here and they are the same widget:
##
##  * toasts — one per in-flight operation, keyed, updated in place. A download,
##    a sync, a cache eviction. Several can be up at once, so they stack; past
##    MAX_VISIBLE they collapse into a "+N more" row rather than running off the
##    top of the panel.
##  * the status bar — a single bar at the bottom of the stack for whatever the
##    menu is doing right now ("Hashing ROM…"), or a transient notice ("Drop
##    Item From Hand First"). Never counted toward the cap and never hidden by
##    it, and pinned last because that is where it sat when it was anchored
##    straight onto the page.
##
## The whole stack is lifted onto its own quad in front of the menu by
## ToastPanel, the same way a dropdown's option list is — so it reads as
## floating in front of the panel rather than painted on it. Falls back to the
## anchors below when there is no 3D host (a plain 2D scene, or a probe).
class_name MenuToasts
extends VBoxContainer

## Bars visible before the rest collapse into "+N more".
const MAX_VISIBLE := 4

## How long an auto-dismissing bar stays up. A failure gets far longer than a
## success: 2.5 s is not enough to read a failure reason through a headset.
const DWELL_OK   := 2.5
const DWELL_INFO := 3.0
const DWELL_FAIL := 6.0

const BAR_BG := Color(0.05, 0.10, 0.28, 0.96)
const OVERFLOW_BG := Color(0.05, 0.10, 0.28, 0.80)
const PROGRESS_FILL := Color(0.45, 0.70, 1.0)
const PROGRESS_TRACK := Color(0.25, 0.25, 0.38)

## key -> { bar, label, icon, progress }
var _toasts: Dictionary = {}
var _panel: ToastPanel = null
var _overflow_bar: PanelContainer = null
var _overflow_label: Label = null

var _status_bar: PanelContainer = null
var _status_label: Label = null
## Bumped per notice so a stale auto-hide can't clear a newer message.
var _notice_token := 0


static func create() -> MenuToasts:
	var t := MenuToasts.new()
	t.add_theme_constant_override("separation", 6)
	t.alignment = BoxContainer.ALIGNMENT_END
	# Anchored to the bottom, above where the status bar used to sit alone.
	t.anchor_left   = 0.1
	t.anchor_right  = 0.9
	t.anchor_top    = 1.0
	t.anchor_bottom = 1.0
	t.offset_top    = -300.0
	t.offset_bottom = -62.0
	t.grow_vertical = Control.GROW_DIRECTION_BEGIN
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## Adopt onto the 3D quad. Deferred to the first bar rather than done on entry:
## the host Viewport2Din3D is one hop out through the viewport, and that is only
## resolvable once this is in the tree.
func _ensure_panel() -> void:
	if _panel != null and is_instance_valid(_panel):
		return
	var vp := get_viewport()
	if vp == null:
		return
	_panel = ToastPanel.adopt(vp.get_parent() as XRToolsViewport2DIn3D, self)


## Re-measure the quad. Deferred so it lands after _enforce_cap's visibility
## pass and after any other bars raised in the same frame; refresh() is
## idempotent, so extra calls cost nothing.
func refresh() -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.refresh.call_deferred()


# ── Toasts ────────────────────────────────────────────────────────────────────

## Keyed so each concurrent operation owns one bar and updates it in place —
## never one bar per progress tick or per retry.
##
## key      : stable per operation, e.g. "romm:dl:1289". Use a namespace prefix
##            so it can't collide with the scraper's "box"/"wheel"/… keys.
## progress : 0.0-1.0 to show a bar, or <0 for none.
## seconds  : >0 auto-dismisses after that long; <=0 keeps it until replaced.
func notify(key: String, icon_text: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _toasts.has(key):
		_update(key, icon_text, msg, progress)
	else:
		_add(key, icon_text, msg, progress)
	if seconds > 0.0:
		get_tree().create_timer(seconds).timeout.connect(clear.bind(key))


## Drop a toast immediately (e.g. an operation was cancelled).
func clear(key: String) -> void:
	if not _toasts.has(key):
		return
	var toast: Dictionary = _toasts[key]
	var bar: PanelContainer = toast.get("bar")
	if bar != null and is_instance_valid(bar):
		remove_child(bar)
		bar.queue_free()
	_toasts.erase(key)
	_enforce_cap()
	refresh()


## Replace a toast's text with an outcome and let it expire. `seconds` defaults
## to 2.5; failures pass a longer dwell, because 2.5 s is not enough to read a
## failure reason through a headset.
func finish(key: String, icon_text: String, msg: String, seconds: float = 2.5) -> void:
	if not _toasts.has(key):
		# No "started" toast (e.g. failed before the request began) — make one so
		# the outcome is still surfaced.
		_add(key, icon_text, msg, -1.0)
	else:
		_update(key, icon_text, msg, -1.0)
	get_tree().create_timer(seconds).timeout.connect(clear.bind(key))


func _update(key: String, icon_text: String, msg: String, progress: float = -1.0) -> void:
	if not _toasts.has(key):
		return
	var toast: Dictionary = _toasts[key]
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
	refresh()


func _add(key: String, icon_text: String, msg: String, progress: float) -> void:
	_ensure_panel()
	var built := _make_bar(icon_text, msg, progress, true)
	add_child(built["bar"])
	_toasts[key] = built
	_enforce_cap()
	refresh()


# ── Status bar / notices ──────────────────────────────────────────────────────

## Show or replace the single bar at the bottom of the stack.
func status(msg: String) -> void:
	if _status_bar != null and is_instance_valid(_status_bar):
		if _status_label != null:
			_status_label.text = msg
			refresh()
		return
	_ensure_panel()
	var built := _make_bar("⏳", msg, -1.0, false)
	_status_bar = built["bar"]
	_status_label = built["label"]
	# Last child: it always sat below the toasts, and the stack grows upward.
	add_child(_status_bar)
	move_child(_status_bar, -1)
	refresh()


## Update the text only, if the bar is up. Connected to the scraper's progress.
func status_update(msg: String) -> void:
	if _status_label != null and is_instance_valid(_status_label):
		_status_label.text = msg
		refresh()


func status_clear() -> void:
	if _status_bar != null and is_instance_valid(_status_bar):
		if _status_bar.get_parent() != null:
			_status_bar.get_parent().remove_child(_status_bar)
		_status_bar.queue_free()
	_status_bar = null
	_status_label = null
	refresh()


## A transient message in the status slot — e.g. "Drop Item From Hand First".
## Auto-hides, but only if nothing newer has replaced the text meanwhile.
func notice(msg: String, seconds := 2.5) -> void:
	status(msg)
	_notice_token += 1
	var tok := _notice_token
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if tok == _notice_token and _status_label != null \
				and is_instance_valid(_status_label) \
				and _status_label.text == msg:
			status_clear())


# ── The bar itself ────────────────────────────────────────────────────────────

## One rounded bar: icon, message, and — for a toast — a progress track under
## them. Both kinds of bar in this stack are this, which is why it is one
## function: the toast and the status bar were the same forty lines twice.
##
## `with_progress` off leaves out the track AND its VBox wrapper, so a status
## bar is built exactly as it was authored. A toast always gets the track and
## hides it when `progress` is negative, so it can appear later without a
## rebuild.
func _make_bar(icon_text: String, msg: String, progress: float,
			   with_progress: bool) -> Dictionary:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", MenuStyle.rounded(BAR_BG, 8))
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Hug the text rather than filling the stack — the quad is sized to the
	# widest bar, so a filling bar would stretch every one of them to that width.
	bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 8)
	bar.add_child(margin)

	var hbox := MenuStyle.hbox(10)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var icon := Label.new()
	icon.text = icon_text
	icon.add_theme_font_size_override("font_size", 18)
	hbox.add_child(icon)

	var label := MenuStyle.label(msg, 18, MenuStyle.COLOR_TITLE)
	hbox.add_child(label)

	var prog: ProgressBar = null
	if not with_progress:
		margin.add_child(hbox)
		return {"bar": bar, "label": label, "icon": icon, "progress": null}

	# Progress track, stacked under the icon+text line.
	var vbox := MenuStyle.vbox(4, false)
	vbox.add_child(hbox)
	margin.add_child(vbox)

	prog = ProgressBar.new()
	prog.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prog.show_percentage = false
	prog.custom_minimum_size = Vector2(0, 5)
	prog.value = maxf(progress, 0.0) * 100.0
	prog.visible = progress >= 0.0
	prog.add_theme_stylebox_override("fill", MenuStyle.rounded(PROGRESS_FILL, 3))
	prog.add_theme_stylebox_override("background", MenuStyle.rounded(PROGRESS_TRACK, 3))
	vbox.add_child(prog)

	return {"bar": bar, "label": label, "icon": icon, "progress": prog}


# ── Overflow cap ──────────────────────────────────────────────────────────────

## Keep at most MAX_VISIBLE bars on screen; older ones collapse into a single
## "+N more" row at the top. Without this, a queue of downloads pushes bars off
## the top of the menu panel.
func _enforce_cap() -> void:
	# The status bar shares the stack but is not a toast: never hidden by the
	# cap, never counted toward it, and pinned to the bottom.
	if _status_bar != null and is_instance_valid(_status_bar) \
			and _status_bar.get_parent() == self:
		move_child(_status_bar, -1)

	var bars: Array[Control] = []
	for c: Node in get_children():
		if c == _overflow_bar or c == _status_bar:
			continue
		if c is Control:
			bars.append(c)

	var overflow := maxi(0, bars.size() - MAX_VISIBLE)
	# Newest are appended last, so hide from the front.
	for i in bars.size():
		bars[i].visible = i >= overflow

	if overflow <= 0:
		if _overflow_bar != null and is_instance_valid(_overflow_bar):
			_overflow_bar.queue_free()
		_overflow_bar = null
		_overflow_label = null
		return

	if _overflow_bar == null or not is_instance_valid(_overflow_bar):
		_overflow_bar = PanelContainer.new()
		_overflow_bar.add_theme_stylebox_override("panel",
			MenuStyle.rounded(OVERFLOW_BG, 8))
		_overflow_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_overflow_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		var m := MarginContainer.new()
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			m.add_theme_constant_override(side, 6)
		_overflow_bar.add_child(m)

		_overflow_label = MenuStyle.label("", 15, MenuStyle.COLOR_DESC)
		_overflow_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		m.add_child(_overflow_label)

		add_child(_overflow_bar)

	move_child(_overflow_bar, 0)
	_overflow_label.text = "+%d more" % overflow
