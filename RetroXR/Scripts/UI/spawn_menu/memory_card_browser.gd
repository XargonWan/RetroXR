## MemoryCardBrowser — the spawn menu's PlayStation memory-card shelf.
##
## Two pages, one visible at a time:
##   list   : one row per card that exists on disk. Tap it to bring that card
##            into the room; tap its right-hand button to read what is saved on
##            it without spawning anything. "New Memory Card" at the bottom.
##   saves  : that card's save list, the same view the card's own panel shows,
##            read straight off the .mcr.
##
## A card only exists on disk once it has been seated in a powered console, so a
## freshly spawned card that has never been used is deliberately not listed —
## there is nothing to distinguish it from the blank the bottom row makes.
class_name MemoryCardBrowser
extends VBoxContainer

## Carries a spawn token for SpawnMenuController: "memory_card" for a new blank
## one, "memcard:<card_id>" to bring an existing card back.
signal spawn_requested(token: String)
## The player backed out of the card list.
signal closed

## Only the PlayStation has removable cards, so this browses its folder rather
## than asking which console was meant.
const SYSTEMID := "playstation"

## card_id of the row currently showing its rename field, or "".
var _editing_id := ""


## Any card images on disk? With none there is nothing to choose between, and
## the caller should just spawn a blank one.
static func has_cards() -> bool:
	return not SramPaths.list_cards(SYSTEMID).is_empty()


## Show the card list (rebuilt each time — cards are written as you play).
func open() -> void:
	_build_list()


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()


func _header(back_text: String, title_text: String, on_back: Callable) -> void:
	var header := MenuStyle.hbox(10)
	add_child(header)
	var back := Button.new()
	back.text = back_text
	back.custom_minimum_size = Vector2(190, 64)
	back.add_theme_font_size_override("font_size", 22)
	back.pressed.connect(on_back)
	header.add_child(back)
	var title := MenuStyle.header(title_text, 24)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)


func _build_list() -> void:
	_clear()
	_header("  ◀  Back", "PlayStation Memory Cards", func() -> void: closed.emit())

	for card: Dictionary in SramPaths.list_cards(SYSTEMID):
		add_child(_card_row(card))

	add_child(MenuStyle.spacer(6))
	var new_btn := Button.new()
	new_btn.text = "  +  New Memory Card"
	new_btn.custom_minimum_size = Vector2(0, 80)
	new_btn.add_theme_font_size_override("font_size", 26)
	new_btn.pressed.connect(func() -> void: spawn_requested.emit("memory_card"))
	add_child(new_btn)
	add_child(MenuStyle.spacer(10))


func _card_row(card: Dictionary) -> Control:
	var row := MenuStyle.hbox(8)

	# The row being renamed swaps its label for the field, so the name is edited
	# where it is read instead of in a dialog over the top of it.
	if str(card["card_id"]) == _editing_id:
		var edit := LineEdit.new()
		edit.text = str(card["label"])
		edit.custom_minimum_size = Vector2(0, 80)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.add_theme_font_size_override("font_size", 26)
		edit.text_submitted.connect(func(t: String) -> void: _commit_rename(card, t))
		edit.focus_exited.connect(func() -> void: _commit_rename(card, edit.text))
		row.add_child(edit)
		edit.call_deferred("grab_focus")
		edit.call_deferred("select_all")
		return row

	var saves := int(card["saves"])
	var free := int(card["free"])
	var spawn_btn := Button.new()
	spawn_btn.custom_minimum_size = Vector2(0, 80)
	spawn_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spawn_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	spawn_btn.add_theme_font_size_override("font_size", 26)
	spawn_btn.text = "  +  %s      %d save%s · %d block%s free" \
		% [card["label"], saves, "" if saves == 1 else "s",
		   free, "" if free == 1 else "s"]
	spawn_btn.pressed.connect(
		func() -> void: spawn_requested.emit("memcard:%s" % card["card_id"]))
	row.add_child(spawn_btn)

	var view_btn := Button.new()
	view_btn.custom_minimum_size = Vector2(80, 80)
	view_btn.text = String.chr(MenuIcons.CARD_SAVES)
	view_btn.add_theme_font_override("font", MenuIcons.symbols())
	view_btn.add_theme_font_size_override("font_size", 34)
	view_btn.tooltip_text = "View the saves on this card"
	view_btn.pressed.connect(func() -> void: _build_saves(card))
	row.add_child(view_btn)

	var rename_btn := Button.new()
	rename_btn.custom_minimum_size = Vector2(80, 80)
	rename_btn.text = String.chr(MenuIcons.RENAME)
	rename_btn.add_theme_font_override("font", MenuIcons.symbols())
	rename_btn.add_theme_font_size_override("font_size", 34)
	rename_btn.tooltip_text = "Rename this card"
	rename_btn.pressed.connect(func() -> void:
		_editing_id = str(card["card_id"])
		_build_list())
	row.add_child(rename_btn)
	return row


## Rename the card, which moves its image — see SramPaths.rename_card.
func _commit_rename(card: Dictionary, text: String) -> void:
	# focus_exited fires again as the rebuilt list tears the field down, so the
	# first commit closes the edit and the second finds nothing to do.
	if _editing_id.is_empty():
		return
	_editing_id = ""
	var old_id := str(card["card_id"])
	var new_id := SramPaths.rename_card(old_id, text)
	if new_id.is_empty():
		push_warning("[MemoryCardBrowser] a card named '%s' already exists" % text)
	elif new_id != old_id:
		_adopt_rename_in_room(old_id, new_id)
	_build_list()


## The renamed card may also be sitting in the room, and its object keys off the
## filename — left alone it would point at an image that no longer exists, and
## the next save would write a second card under the old name.
func _adopt_rename_in_room(old_id: String, new_id: String) -> void:
	for n: Node in get_tree().get_nodes_in_group("memory_card"):
		var card := n as MemoryCard
		if card == null or card.card_id != old_id:
			continue
		card.card_id = new_id
		card.card_label = new_id
		for sys: Node in get_tree().get_nodes_in_group("retro_system"):
			if sys.has_method("get_snapped_memcard") and sys.get_snapped_memcard() == card \
					and sys.has_method("refresh_memcard_path"):
				sys.refresh_memcard_path()
		return


func _build_saves(card: Dictionary) -> void:
	_clear()
	_header("  ◀  Cards", str(card["label"]), _build_list)

	var saves: Array[Dictionary] = []
	var free := 15
	var f := FileAccess.open(str(card["path"]), FileAccess.READ)
	if f != null:
		var data := f.get_buffer(f.get_length())
		f.close()
		saves = PS1Card.list_saves(data)
		free = PS1Card.free_blocks(data)

	# The card's own panel, minus its rename field and ✕: this page has its own
	# back button, and the card being read may not even be in the room.
	var ui := MemoryCard2D.new()
	ui.show_name_field = false
	ui.custom_minimum_size = Vector2(0, 470)
	ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(ui)
	await get_tree().process_frame
	ui.populate(str(card["label"]), saves, free)
