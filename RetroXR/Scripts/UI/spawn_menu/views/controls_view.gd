## SpawnMenuControlsView — the menu's CONTROLS tab: what every physical input
## does inside an emulated system.
##
## Three sections. Which of the first two appears depends on how the player is
## running: XR bindings in a headset, desktop key bindings at a desk. The
## physical-gamepad section is shown in both, because a USB or Bluetooth pad
## works either way.
##
## Rebinding needs help from outside — capturing "the next key press" or "the
## next pad button" has to happen where raw input arrives, not in a UI panel. So
## this asks by signal (rebind_started / pad_rebind_started) and the controller
## calls back into on_rebind_complete / on_pad_rebind_complete.
##
## The rebind buttons used to be in ACTION_MODE_BUTTON_PRESS, which a
## Viewport2Din3D turned into two presses per tap — see the note in net_view.gd.
## It did no harm here, because every handler on this tab is an assignment or an
## idempotent write, but that was luck rather than design.
class_name SpawnMenuControlsView
extends ScrollContainer

## A row wants the next key/mouse press captured for `action_name`;
## spawn_menu_controller does the capturing and calls on_rebind_complete().
signal rebind_started(action_name: String)
## Same for a physical gamepad button, answered by on_pad_rebind_complete().
signal pad_rebind_started(target: String)
## Bindings were written — anything holding a copy should re-read them.
signal controller_bindings_changed

# XR working copies, applied on every change rather than gated behind a Save.
var _edit_button_map:   Dictionary = {}
var _edit_stick_map:    Dictionary = {}
var _edit_lightgun_map: Dictionary = {}

# Desktop rebinding: which action is listening, and action_name -> its Button so
# on_rebind_complete() can relabel it.
var _rebinding_action: String = ""
var _rebind_buttons: Dictionary = {}

## key -> VRDropdown, so a reset can move a dropdown without reopening it.
var _controls_opts: Dictionary = {}

# Physical gamepad: working copies, the diagram, and the fallback list.
var _edit_pad_button_map: Dictionary = {}
var _edit_pad_stick_map:  Dictionary = {}
var _pad_diagram: GamepadDiagram = null
var _pad_list_box: VBoxContainer = null
var _pad_rebinding_target: String = ""
var _pad_rebind_buttons: Dictionary = {}
var _pad_status_label: Label = null


static func create() -> SpawnMenuControlsView:
	var v := SpawnMenuControlsView.new()
	v._build()
	return v

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


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := MenuStyle.vbox(14)
	add_child(vbox)

	vbox.add_child(MenuStyle.spacer(10))
	_build_controls_section(vbox)
	vbox.add_child(MenuStyle.spacer(10))


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
	vbox.add_child(MenuStyle.label("CONTROLS", 22, MenuStyle.COLOR_TITLE))

	if MenuStyle.is_vr_mode():
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
	vbox.add_child(MenuStyle.label("XR Joypad Buttons", 18, MenuStyle.COLOR_LICENSE))

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
	vbox.add_child(MenuStyle.label("Analog Sticks", 18, MenuStyle.COLOR_LICENSE))

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
	vbox.add_child(MenuStyle.label("Light Gun Buttons", 18, MenuStyle.COLOR_LICENSE))

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
	vbox.add_child(MenuStyle.label("Gamepad Buttons", 18, MenuStyle.COLOR_LICENSE))

	for action: String in DesktopBindings.JOYPAD_ACTIONS:
		vbox.add_child(_make_rebind_row(action))

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Analog Sticks", 18, MenuStyle.COLOR_LICENSE))

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
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var btn := Button.new()
	btn.text = DesktopBindings.event_display_name(action)
	btn.custom_minimum_size = Vector2(140, 44)
	btn.add_theme_font_size_override("font_size", 18)
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
## The event is null when the user cancelled with Escape; the binding is read
## back from DesktopBindings either way.
func on_rebind_complete(action: String, _event: InputEvent) -> void:
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
	vbox.add_child(MenuStyle.label("GAME CONTROLLER", 22, MenuStyle.COLOR_TITLE))

	# ── Connected-pad status line ─────────────────────────────────────────────
	var status := Label.new()
	status.add_theme_font_size_override("font_size", 16)
	status.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
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
	btn_hdr.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	btn_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_row.add_child(btn_hdr)

	var list_box := VBoxContainer.new()
	list_box.visible = false
	vbox.add_child(list_box)
	_pad_list_box = list_box

	list_row.add_child(VRToggle.create(false, func(on: bool) -> void:
		if is_instance_valid(_pad_list_box):
			_pad_list_box.visible = on
	))

	for target: String in GamepadBindings.TARGET_ORDER:
		list_box.add_child(_make_pad_rebind_row(target))

	# ── Analog Sticks ─────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Analog Sticks", 18, MenuStyle.COLOR_LICENSE))

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
	reset_btn.focus_mode = Control.FOCUS_NONE
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_pad_controls_reset)
	action_row.add_child(reset_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(220, 52)
	save_btn.add_theme_font_size_override("font_size", 18)
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
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var binding: String = _edit_pad_button_map.get(target, "none")
	var btn := Button.new()
	btn.text = GamepadBindings.binding_display_name(binding)
	btn.custom_minimum_size = Vector2(160, 44)
	btn.add_theme_font_size_override("font_size", 18)
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
