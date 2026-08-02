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
			_show_keyboard(le.text)
	)
	le.text_submitted.connect(func(_t: String) -> void:
		DisplayServer.virtual_keyboard_hide()
		le.release_focus()
	)
	le.focus_exited.connect(func() -> void:
		DisplayServer.virtual_keyboard_hide()
	)


static func patch_text_edit(te: TextEdit) -> void:
	if te.has_meta("vr_kb_patched"):
		return
	te.set_meta("vr_kb_patched", true)

	te.virtual_keyboard_show_on_focus = false
	te.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
			_show_keyboard(te.text)
	)
	te.focus_exited.connect(func() -> void:
		DisplayServer.virtual_keyboard_hide()
	)


## No-op on desktop, where there is no virtual keyboard to show.
static func _show_keyboard(existing: String) -> void:
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show(existing)
