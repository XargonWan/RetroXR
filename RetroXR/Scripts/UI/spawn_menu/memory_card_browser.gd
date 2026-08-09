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
## Something worth saying out loud — forwarded to the menu's toast.
signal notice(text: String, seconds: float)
## Where the shelf now is, and what going back from here means.
##
## The shelf lives inside a page that already has a Back button and a title, so
## it draws neither: it says where it is and lets the one header do the walking.
signal page_changed(title: String, on_back: Callable)

## Only the PlayStation has removable cards, so this browses its folder rather
## than asking which console was meant.
const SYSTEMID := "playstation"

## How long a delete stays armed. Matches the ROM rows' confirm window.
const ARM_SECONDS := 3.0

## card_id of the row currently showing its rename field, or "".
var _editing_id := ""
## Save slot whose delete has been armed and is waiting for a second press.
var _armed_slot := ""
## The upload this page is waiting on, and the card to redraw when it lands.
var _pending_key := ""
var _pending_card: Dictionary = {}


## Any card images on disk? With none there is nothing to choose between, and
## the caller should just spawn a blank one.
static func has_cards() -> bool:
	# A directory listing, not list_cards: that reads and parses every image, and
	# the answer here is only whether any file exists.
	var dir := SramPaths.cards_dir(SYSTEMID)
	if not DirAccess.dir_exists_absolute(dir):
		return false
	for f: String in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "mcr":
			return true
	return false


## Show the card list (rebuilt each time — cards are written as you play).
func open() -> void:
	_build_list()


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()


## Say where the shelf is now. The host's header renders it and owns Back.
func _page(title_text: String, on_back: Callable) -> void:
	page_changed.emit(title_text, on_back)


func _build_list() -> void:
	_clear()
	_page("PlayStation Memory Cards", func() -> void: closed.emit())

	# Where the cards actually are. They are ordinary .mcr images that any PS1
	# card tool opens, so saying where they live is the difference between a
	# closed box and a folder you can back up, copy or edit outside RetroXR.
	add_child(MenuStyle.hint(SramPaths.cards_dir(SYSTEMID)))

	for card: Dictionary in SramPaths.list_cards(SYSTEMID):
		add_child(_card_row(card))

	add_child(MenuStyle.spacer(6))
	var new_btn := MenuStyle.row_button("  +  New Memory Card", 26, 0, 80, false)
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
	var spawn_btn := MenuStyle.row_button("")
	spawn_btn.text = "  +  %s      %d save%s · %d block%s free%s" \
		% [card["label"], saves, "" if saves == 1 else "s",
		   free, "" if free == 1 else "s", _where(card, saves)]
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


## Where this card's saves live, in the same spirit as a ROM row saying whether
## it is here or on the server.
##
## A card is always on this device — the row would not exist otherwise — so what
## is worth saying is whether anything is ALSO on RomM, and stays quiet about it
## entirely when there is no server configured.
func _where(card: Dictionary, saves: int) -> String:
	if not SaveSync.is_available():
		return ""
	var path := str(card["path"])
	var backed := SaveSync.card_backup_count(path)
	if backed <= 0:
		return "   ·   on this device only"
	if backed >= saves:
		return "   ·   backed up to RomM"
	return "   ·   %d of %d on RomM" % [backed, saves]


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
		_refresh_holder(new_id)
		return


## The console holding this card, or null. One walk: menu code reaching into
## console internals is a surface worth having exactly one copy of, and the three
## hand-written copies had already drifted over whether "powered off" counts.
func _holder_of(card_id: String) -> Node:
	for sys: Node in get_tree().get_nodes_in_group("retro_system"):
		if not sys.has_method("get_snapped_memcard"):
			continue
		var seated: Node = sys.get_snapped_memcard()
		if seated != null and str(seated.get("card_id")) == card_id:
			return sys
	return null


## Tell whichever console holds this card that its image changed underneath.
func _refresh_holder(card_id: String) -> void:
	var sys := _holder_of(card_id)
	if sys != null and sys.has_method("refresh_memcard_path"):
		sys.refresh_memcard_path()


## The saves RomM holds, and which of them will fit on this card.
##
## Restoring writes into the card, so every refusal is stated on the row rather
## than discovered after the fact: a save already on the card, or one needing
## more blocks than are free, says so and cannot be pressed.
func _build_restore(card: Dictionary) -> void:
	_clear()
	_page("Restore to %s" % card["label"], func() -> void: _build_saves(card))

	var status := MenuStyle.label("Asking RomM…", 20, MenuStyle.COLOR_DESC)
	add_child(status)

	SaveSync.list_card_saves(SYSTEMID, func(ok: bool, saves: Array) -> void:
		if not is_inside_tree():
			return
		status.queue_free()
		if not ok:
			add_child(MenuStyle.label("Could not reach RomM.", 20, Color(0.85, 0.5, 0.5)))
			return
		if saves.is_empty():
			add_child(MenuStyle.label("RomM holds no memory-card saves yet.",
				20, MenuStyle.COLOR_DESC))
			return

		var data := FileAccess.get_file_as_bytes(str(card["path"]))
		var free := PS1Card.free_blocks(data)
		var present := {}
		for s: Dictionary in PS1Card.list_saves(data, false):
			present[str(s["name"])] = true
		for s: Dictionary in saves:
			add_child(_restore_row(card, s, present, free)))


func _restore_row(card: Dictionary, s: Dictionary, present: Dictionary, free: int) -> Control:
	var row := MenuStyle.hbox(8)
	var slot := str(s["slot"])
	# .mcs is a 128-byte directory entry plus whole blocks.
	@warning_ignore("integer_division")
	var blocks: int = maxi(1, (int(s["size"]) - PS1Card.FRAME_SIZE) / PS1Card.BLOCK_SIZE)

	var reason := ""
	if present.has(slot):
		reason = "already on this card"
	elif blocks > free:
		reason = "needs %d blocks, %d free" % [blocks, free]

	var btn := MenuStyle.row_button("", 24)
	var rom_name := str(s.get("rom_name", ""))
	btn.text = "    %s      %d block%s%s" % [
		rom_name if not rom_name.is_empty() else slot,
		blocks, "" if blocks == 1 else "s",
		"" if reason.is_empty() else "   ·   " + reason]
	btn.disabled = not reason.is_empty()
	btn.pressed.connect(func() -> void: _restore(card, s))
	row.add_child(btn)
	return row


## Pull one save down and splice it into the card. Written to a temp image and
## checked before it replaces the real one: a bad splice would take every other
## save on that card with it.
func _restore(card: Dictionary, s: Dictionary) -> void:
	_clear()
	_page(str(card["label"]), func() -> void: _build_saves(card))
	var status := MenuStyle.label("Downloading…", 20, MenuStyle.COLOR_DESC)
	add_child(status)

	SaveSync.fetch_card_save(int(s["id"]), func(ok: bool, bytes: PackedByteArray) -> void:
		if not is_inside_tree():
			return
		if not ok or bytes.is_empty():
			status.text = "Download failed."
			return
		# Never splice what has not been shown to be a PS1 save. The platform
		# filter should already have ruled this out; this is the check that does
		# not depend on the server labelling things correctly.
		if not PS1Card.is_mcs(bytes):
			status.text = "That file is not a PlayStation save."
			return
		var merged := PS1Card.insert_save(FileAccess.get_file_as_bytes(str(card["path"])), bytes)
		if merged.is_empty():
			status.text = "That save will not fit on this card."
			return
		if not _write_card(card, merged):
			status.text = "The card did not verify — nothing was written."
			return

		# A save fetched from the server is already one the player wants kept
		# there, so it arrives opted in rather than making them ask again for
		# what they just asked for.
		#
		# The listing also names the game it belongs to, which is the one thing
		# this device could not otherwise work out for a save it never watched
		# being written — recorded now so a later local change uploads at once
		# instead of falling back to sweeping the disc library for its serial.
		var key := RommSaveSync.card_save_key(str(card["path"]), str(s["slot"]))
		SaveSync.set_key_enabled(key, true)
		SaveSync.note_card_save_owner(key, int(s["rom_id"]))
		notice.emit("Restored %s — kept backed up to RomM"
			% str(s.get("rom_name", s["slot"])), 3.5)
		_build_saves(card))


func _build_saves(card: Dictionary) -> void:
	_clear()
	_page(str(card["label"]), _build_list)

	var data := FileAccess.get_file_as_bytes(str(card["path"]))
	var saves := PS1Card.list_saves(data)
	var free := PS1Card.free_blocks(data)

	if SaveSync.is_available():
		# No glyph: the icon font carries symbols only, so a button holding both a
		# codepoint and words can use one font or the other, never both.
		var restore := MenuStyle.row_button("Restore a save from RomM", 22, 0, 68, false)
		restore.pressed.connect(func() -> void: _build_restore(card))
		add_child(restore)

	# The card's own panel, minus its rename field and ✕: this page has its own
	# back button, and the card being read may not even be in the room. Here it
	# also manages its saves, which the card's 3D panel does not.
	var ui := MemoryCard2D.new()
	ui.show_name_field = false
	ui.show_save_actions = true
	ui.armed_slot = _armed_slot
	ui.actions_blocked = _in_use_reason(card)
	ui.custom_minimum_size = Vector2(0, 470)
	ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.save_move_requested.connect(func(s: Dictionary) -> void: _build_move(card, s))
	ui.save_delete_requested.connect(func(s: Dictionary) -> void: _delete_save(card, s))
	ui.save_sync_toggled.connect(func(s: Dictionary, on: bool) -> void:
		_toggle_save_sync(card, s, on))
	add_child(ui)
	await get_tree().process_frame
	# A second _build_saves during that frame already freed this one.
	if not is_instance_valid(ui):
		return

	# Which of these saves are already opted in.
	var synced: Dictionary = {}
	for s: Dictionary in saves:
		if SaveSync.is_key_enabled(
				RommSaveSync.card_save_key(str(card["path"]), str(s["name"]))):
			synced[str(s["name"])] = true
	ui.synced_slots = synced
	ui.sync_available = SaveSync.is_available()
	ui.populate(str(card["label"]), saves, free)


## Opt one save in or out, and on opting in send it straight away rather than
## waiting for the game to be played again — pressing "back this up" and having
## nothing happen is indistinguishable from it being broken.
##
## Uploading needs to know which game owns the save. That is recorded whenever a
## game writes it, so a save this device has never seen written has no owner yet
## and genuinely cannot be uploaded until it is; the notice says so instead of
## failing quietly.
func _toggle_save_sync(card: Dictionary, s: Dictionary, on: bool) -> void:
	var slot := str(s["name"])
	var key := RommSaveSync.card_save_key(str(card["path"]), slot)
	SaveSync.set_key_enabled(key, on)
	if not on:
		notice.emit("Stopped backing up %s" % _title_of(s), 2.5)
		_build_saves(card)
		return

	# Owner from what a running game last told us; failing that, ask the discs,
	# which is the only place a save's product code maps to a game.
	var rom_id := SaveSync.card_save_owner(key)
	if rom_id <= 0:
		rom_id = SaveSync.rom_id_for_serial(SYSTEMID, str(s.get("serial", "")))
		if rom_id > 0:
			SaveSync.note_card_save_owner(key, rom_id)
	if rom_id <= 0:
		# Only reachable when the game is not in the library at all, or is there
		# but not known to RomM — neither of which uploading can fix.
		notice.emit("%s: no matching game in your library, so there is nothing "
			% _title_of(s) + "to attach it to on RomM", 5.0)
		_build_saves(card)
		return

	var bytes := PS1Card.extract_save(FileAccess.get_file_as_bytes(str(card["path"])), int(s["block"]))
	if bytes.is_empty():
		notice.emit("Could not read %s" % _title_of(s), 3.0)
		_build_saves(card)
		return

	notice.emit("Uploading %s…" % _title_of(s), 8.0)
	_pending_key = key
	_pending_card = card
	if not SaveSync.sync_finished.is_connected(_on_sync_finished):
		SaveSync.sync_finished.connect(_on_sync_finished)
	SaveSync.push_card_save(key, rom_id, SramPaths.core_for_systemid(SYSTEMID),
		slot, _title_of(s), bytes)


func _on_sync_finished(key: String, action: String, ok: bool, detail: String) -> void:
	# sync_finished is global. Without this the card page would announce the
	# result of a cartridge save flushing in another room.
	if key != _pending_key:
		return
	_pending_key = ""
	SaveSync.sync_finished.disconnect(_on_sync_finished)
	if not ok:
		notice.emit("Upload failed: %s" % detail, 4.0)
	elif action == "nothing":
		notice.emit("Already backed up", 2.5)
	else:
		notice.emit("Backed up to RomM", 2.5)
	if not _pending_card.is_empty() and is_inside_tree():
		var card := _pending_card
		_pending_card = {}
		_build_saves(card)


func _title_of(s: Dictionary) -> String:
	var t := str(s.get("title", ""))
	return t if not t.is_empty() else str(s.get("name", ""))


## Why this card must not be changed right now, or "".
##
## Editing the image under a running game means the core is holding save data
## this no longer matches, and its next flush would write that back over the
## edit. Powering the console off is the honest fix, so say so rather than
## silently doing something half-applied.
func _in_use_reason(card: Dictionary) -> String:
	var sys := _holder_of(str(card["card_id"]))
	if sys != null and bool(sys.get("is_powered_on")):
		return "in use — power the console off first"
	return ""


## Delete one save. Armed on the first press and done on the second, the way a
## ROM row asks twice, because this cannot be undone: the blocks are freed and
## nothing keeps a copy.
func _delete_save(card: Dictionary, s: Dictionary) -> void:
	var slot := str(s["name"])
	if _armed_slot != slot:
		# Same shape as deleting a ROM: arm, say so, and disarm after 3 s. The
		# glyph alone changing is easy to miss on a headset.
		_armed_slot = slot
		notice.emit("Press again to delete %s" % _title_of(s), ARM_SECONDS)
		_build_saves(card)
		get_tree().create_timer(ARM_SECONDS).timeout.connect(func() -> void:
			if _armed_slot == slot and is_inside_tree():
				_armed_slot = ""
				_build_saves(card))
		return
	_armed_slot = ""
	var out := PS1Card.delete_save(FileAccess.get_file_as_bytes(str(card["path"])), int(s["block"]))
	if out.is_empty() or not _write_card(card, out):
		push_warning("[MemoryCardBrowser] could not delete '%s'" % slot)
	_build_saves(card)


## Move a save to another card: pick the destination.
func _build_move(card: Dictionary, s: Dictionary) -> void:
	_clear()
	var title := str(s["title"])
	_page("Move %s" % (title if not title.is_empty() else s["name"]),
		func() -> void: _build_saves(card))

	var blocks := int(s["blocks"])
	var any := false
	for dest: Dictionary in SramPaths.list_cards(SYSTEMID):
		if str(dest["card_id"]) == str(card["card_id"]):
			continue
		any = true
		var reason := _in_use_reason(dest)
		var data := FileAccess.get_file_as_bytes(str(dest["path"]))
		if reason.is_empty():
			if PS1Card.block_of(data, str(s["name"])) != -1:
				reason = "already has this save"
		var free := PS1Card.free_blocks(data)
		if reason.is_empty() and free < blocks:
			reason = "needs %d blocks, %d free" % [blocks, free]

		var btn := MenuStyle.row_button("", 24)
		btn.text = "   %s      %d block%s free%s" % [dest["label"],
			free, "" if free == 1 else "s",
			"" if reason.is_empty() else "   ·   " + reason]
		btn.disabled = not reason.is_empty()
		btn.pressed.connect(func() -> void: _do_move(card, dest, s))
		add_child(btn)

	if not any:
		add_child(MenuStyle.label("There is no other card to move it to.",
			20, MenuStyle.COLOR_DESC))


## Write the destination FIRST, and only remove the source once that has landed
## and verified. Ordered this way on purpose: the failure mode is then a save
## existing on both cards, which the player can see and fix, rather than a save
## that left one card and never arrived at the other.
func _do_move(src: Dictionary, dest: Dictionary, s: Dictionary) -> void:
	var src_data := FileAccess.get_file_as_bytes(str(src["path"]))
	var mcs := PS1Card.extract_save(src_data, int(s["block"]))
	if mcs.is_empty():
		push_warning("[MemoryCardBrowser] could not read the save to move")
		_build_saves(src)
		return
	var merged := PS1Card.insert_save(FileAccess.get_file_as_bytes(str(dest["path"])), mcs)
	if merged.is_empty() or not _write_card(dest, merged):
		push_warning("[MemoryCardBrowser] move aborted — nothing was changed")
		_build_saves(src)
		return
	var trimmed := PS1Card.delete_save(src_data, int(s["block"]))
	if trimmed.is_empty() or not _write_card(src, trimmed):
		push_warning("[MemoryCardBrowser] '%s' was copied to '%s' but could not be "
			% [s["name"], dest["label"]] + "removed from '%s' — it is on both" % src["label"])
	_build_saves(src)


## Verify before committing: parse what is about to be written and confirm the
## save it should contain comes back out of it. A bad splice would take every
## other save on that card with it, so nothing reaches disk unproven.
func _write_card(card: Dictionary, data: PackedByteArray) -> bool:
	if not PS1Card.is_card_image(data):
		return false
	for s: Dictionary in PS1Card.list_saves(data, false):
		if PS1Card.extract_save(data, int(s["block"])).is_empty():
			return false
	var f := FileAccess.open(str(card["path"]), FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	# The console holding this card is now looking at a stale image.
	_refresh_holder(str(card["card_id"]))
	return true
