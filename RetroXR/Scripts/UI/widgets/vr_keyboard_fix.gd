## VRKeyboardFix — makes the Meta overlay keyboard dismissable, for every
## LineEdit in the app, without any per-field code.
##
## The loop: tapping a field focuses it, and Godot opens the virtual keyboard
## *because* it has focus (LineEdit.virtual_keyboard_show_on_focus). Dismissing
## the keyboard — Enter, or its own close button — makes the Meta runtime deliver
## a pointer event over the panel, which lands on the field underneath and
## re-focuses it, which opens the keyboard again. Pressing Enter can never get
## you out, because Enter is what triggers the pointer event that reopens it.
##
## The cure is to stop focus being the trigger. With show_on_focus off, the
## keyboard is opened only by a real press on the field and closed on commit, so
## a stray re-focus has nothing to reopen. The earlier per-field cooldowns were
## timing races against the runtime — they suppressed the second focus rather
## than removing the reason it opened a keyboard.
##
## Registered as an autoload: it patches every LineEdit as it enters the tree, so
## a new text field is covered with no work at the call site.
class_name VRKeyboardFix
extends Node


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	# Anything built before this autoload was ready.
	_patch_tree(get_tree().root)


func _on_node_added(node: Node) -> void:
	if node is LineEdit:
		patch(node)
	elif node is TextEdit:
		patch_text_edit(node)


func _patch_tree(root: Node) -> void:
	if root is LineEdit:
		patch(root)
	elif root is TextEdit:
		patch_text_edit(root)
	for c in root.get_children():
		_patch_tree(c)


## Idempotent, so a field that is re-parented or patched twice is unaffected.
static func patch(le: LineEdit) -> void:
	if le.has_meta("vr_kb_patched"):
		return
	le.set_meta("vr_kb_patched", true)

	le.virtual_keyboard_show_on_focus = false
	le.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_show_keyboard(le)
	)
	le.text_submitted.connect(func(_t: String) -> void:
		DisplayServer.virtual_keyboard_hide()
		le.release_focus()
	)
	le.focus_exited.connect(func() -> void:
		_hide_keyboard.call_deferred(le)
	)


static func patch_text_edit(te: TextEdit) -> void:
	if te.has_meta("vr_kb_patched"):
		return
	te.set_meta("vr_kb_patched", true)

	te.virtual_keyboard_show_on_focus = false
	te.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_show_keyboard(te)
	)
	te.focus_exited.connect(func() -> void:
		_hide_keyboard.call_deferred(te)
	)


## The viewport moves focus before it dispatches the press, so the field already
## owns focus here — and a press it did NOT end up owning must not raise a
## keyboard for it.
##
## No-op on desktop, where there is no virtual keyboard to show.
static func _show_keyboard(field: Control) -> void:
	if not is_instance_valid(field) or not field.has_focus():
		return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return
	var existing := ""
	if field is LineEdit:
		existing = (field as LineEdit).text
	elif field is TextEdit:
		existing = (field as TextEdit).text
	# A field that only accepts numbers asks for the number layout, so the
	# player is not hunting for digits on a QWERTY overlay. Set as metadata
	# rather than a call here: patching happens as the field enters the tree,
	# which is before whoever built it can tell this autoload anything.
	var type: int = DisplayServer.KEYBOARD_TYPE_DEFAULT
	if field.has_meta("vr_kb_type"):
		type = int(field.get_meta("vr_kb_type"))
	# Except on the headset. Godot maps the number layouts to InputType.TYPE_CLASS_NUMBER,
	# and the runtime raises the system numeric keypad for that — a far smaller view than
	# the text IME, which the Meta overlay puts up as a sliver you cannot type into. The
	# fields that ask for digits filter their own input anyway, so the plain keyboard
	# costs a layout the player has to hunt across, not a wrong value.
	if OS.get_name() == "Android" and type != DisplayServer.KEYBOARD_TYPE_DEFAULT:
		type = DisplayServer.KEYBOARD_TYPE_DEFAULT
	# Rect2 is the field's screen rect on platforms that scroll the view to it. Android
	# never receives it — showKeyboard() takes the text and four ints — so it is only
	# ever the "no rect" value here.
	DisplayServer.virtual_keyboard_show(existing, Rect2(), type)


## Losing focus is not on its own a reason to take the keyboard away: moving
## between two text fields blurs the first one AFTER the second has asked for a
## keyboard, so an immediate hide there closes the one the player just opened.
## Deferred and re-checked, the question becomes "does any field still want it".
static func _hide_keyboard(field: Control) -> void:
	if is_instance_valid(field):
		var vp := field.get_viewport()
		var focused: Control = vp.gui_get_focus_owner() if vp != null else null
		if focused is LineEdit or focused is TextEdit:
			return
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return
	DisplayServer.virtual_keyboard_hide()
