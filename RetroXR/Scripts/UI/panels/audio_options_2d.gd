## AudioOptions2D — 2D UI for a CD or cassette player's settings.
## Loaded into AudioOptionsPanel's SubViewport via XRToolsViewport2DIn3D.
## Built programmatically, mirroring MouseOptions2D.
##
## The decks had no panel at all until float-in-place needed somewhere to live.
## Kept deliberately thin: the transport is on the unit's own face and on the
## remote, so this is for the properties of the OBJECT, not of the playback.
##
## Emits:
##   ignore_gravity_toggled(enabled) — float-in-place toggled
##   close_requested                 — user pressed ✕
class_name AudioOptions2D
extends Control

signal ignore_gravity_toggled(enabled: bool)
signal close_requested

const COLOR_BG    := Color(0.08, 0.08, 0.16, 0.96)
const COLOR_TITLE := Color(0.9,  0.9,  1.0)

var _title_lbl: Label = null
var _float_check: CheckBox = null
## Guard so populate() doesn't re-emit while it sets the control.
var _suppress := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()


func _build_ui() -> void:
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

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	var title_row := HBoxContainer.new()
	root.add_child(title_row)

	_title_lbl = Label.new()
	_title_lbl.text = "Player"
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.add_theme_font_size_override("font_size", 26)
	_title_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	title_row.add_child(_title_lbl)

	var close_btn := Button.new()
	close_btn.text = "  ✕  "
	close_btn.add_theme_font_size_override("font_size", 22)
	close_btn.pressed.connect(func(): close_requested.emit())
	title_row.add_child(close_btn)

	root.add_child(HSeparator.new())

	_float_check = MenuStyle.float_toggle()
	_float_check.toggled.connect(func(on: bool):
		if not _suppress:
			ignore_gravity_toggled.emit(on)
	)
	root.add_child(_float_check)


## Sync to the player's current state without re-emitting signals.
func populate(title: String, ignore_gravity: bool) -> void:
	_suppress = true
	if _title_lbl and not title.is_empty():
		_title_lbl.text = title
	if _float_check:
		_float_check.button_pressed = ignore_gravity
	_suppress = false
