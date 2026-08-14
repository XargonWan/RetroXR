## CardSaveOps — everything that changes a memory card's contents, in one place.
##
## Two menus manage the same card images: the spawn menu's card shelf and the
## card's own floating panel in the room. Every rule about them is here rather
## than in either menu, because the two drifting apart is how a card ends up
## edited under a running game, or written without being verified first.
##
## The menus keep their own layout and their own way of saying things; what they
## share is what a delete, a backup and a restore actually do.
class_name CardSaveOps

## Only the PlayStation has removable cards, so nothing here asks which console
## was meant.
const SYSTEMID := "playstation"


## The console holding this card, or null. One walk: menu code reaching into
## console internals is a surface worth having exactly one copy of.
static func holder_of(tree: SceneTree, card_id: String) -> Node:
	for sys: Node in tree.get_nodes_in_group("retro_system"):
		if not sys.has_method("get_snapped_memcard"):
			continue
		var seated: Node = sys.get_snapped_memcard()
		if seated != null and str(seated.get("card_id")) == card_id:
			return sys
	return null


## Tell whichever console holds this card that its image changed underneath.
static func refresh_holder(tree: SceneTree, card_id: String) -> void:
	var sys := holder_of(tree, card_id)
	if sys != null and sys.has_method("refresh_memcard_path"):
		sys.refresh_memcard_path()


## Why this card must not be changed right now, or "".
##
## Editing the image under a running game means the core is holding save data
## this no longer matches, and its next flush would write that back over the
## edit. Powering the console off is the honest fix, so say so rather than
## silently doing something half-applied.
static func in_use_reason(tree: SceneTree, card_id: String) -> String:
	var sys := holder_of(tree, card_id)
	if sys != null and bool(sys.get("is_powered_on")):
		return "in use — power the console off first"
	return ""


## Verify before committing: parse what is about to be written and confirm every
## save it should contain comes back out of it. A bad splice would take every
## other save on that card with it, so nothing reaches disk unproven.
static func write_card(tree: SceneTree, path: String, card_id: String,
		data: PackedByteArray) -> bool:
	if not PS1Card.is_card_image(data):
		return false
	for s: Dictionary in PS1Card.list_saves(data, false):
		if PS1Card.extract_save(data, int(s["block"])).is_empty():
			return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	# The console holding this card is now looking at a stale image.
	refresh_holder(tree, card_id)
	return true


## Delete one save. This cannot be undone — the blocks are freed and nothing
## keeps a copy — so both menus arm it and ask a second time before calling.
static func delete_save(tree: SceneTree, path: String, card_id: String,
		block: int) -> bool:
	var out := PS1Card.delete_save(FileAccess.get_file_as_bytes(path), block)
	return not out.is_empty() and write_card(tree, path, card_id, out)


## A save's game, falling back to its raw slot name.
static func title_of(s: Dictionary) -> String:
	var t := str(s.get("title", ""))
	return t if not t.is_empty() else str(s.get("name", ""))


## Which of these saves are opted in to RomM backup, as a set of slot names.
static func synced_slots(path: String, saves: Array) -> Dictionary:
	var out: Dictionary = {}
	for s: Dictionary in saves:
		if SaveSync.is_key_enabled(RommSaveSync.card_save_key(path, str(s["name"]))):
			out[str(s["name"])] = true
	return out


## How many of a card's 15 blocks one of RomM's saves will take.
## A .mcs is a 128-byte directory entry plus whole blocks.
static func blocks_of(s: Dictionary) -> int:
	@warning_ignore("integer_division")
	var blocks: int = (int(s["size"]) - PS1Card.FRAME_SIZE) / PS1Card.BLOCK_SIZE
	return maxi(1, blocks)


## Why one of RomM's saves cannot be put on this card, or "".
##
## Restoring writes into the card, so every refusal is stated on the row rather
## than discovered after the fact.
static func restore_blocker(s: Dictionary, present: Dictionary, free: int) -> String:
	if present.has(str(s["slot"])):
		return "already on this card"
	var blocks := blocks_of(s)
	if blocks > free:
		return "needs %d blocks, %d free" % [blocks, free]
	return ""


## The slot names already on this card, as a set, for restore_blocker().
static func present_slots(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for s: Dictionary in PS1Card.list_saves(data, false):
		out[str(s["name"])] = true
	return out


## Pull one save down from RomM and splice it into the card, calling back with
## "" or with the reason it did not happen. Written to a checked image before it
## replaces the real one — see write_card.
static func restore_save(tree: SceneTree, path: String, card_id: String,
		s: Dictionary, on_done: Callable) -> void:
	SaveSync.fetch_card_save(int(s["id"]), func(ok: bool, bytes: PackedByteArray) -> void:
		if not ok or bytes.is_empty():
			on_done.call("Download failed.")
			return
		# Never splice what has not been shown to be a PS1 save. The platform
		# filter should already have ruled this out; this is the check that does
		# not depend on the server labelling things correctly.
		if not PS1Card.is_mcs(bytes):
			on_done.call("That file is not a PlayStation save.")
			return
		var merged := PS1Card.insert_save(FileAccess.get_file_as_bytes(path), bytes)
		if merged.is_empty():
			on_done.call("That save will not fit on this card.")
			return
		if not write_card(tree, path, card_id, merged):
			on_done.call("The card did not verify — nothing was written.")
			return

		# A save fetched from the server is already one the player wants kept
		# there, so it arrives opted in rather than making them ask again for
		# what they just asked for.
		#
		# The listing also names the game it belongs to, which is the one thing
		# this device could not otherwise work out for a save it never watched
		# being written — recorded now so a later local change uploads at once
		# instead of falling back to sweeping the disc library for its serial.
		var key := RommSaveSync.card_save_key(path, str(s["slot"]))
		SaveSync.set_key_enabled(key, true)
		SaveSync.note_card_save_owner(key, int(s["rom_id"]))
		on_done.call(""))


## Stop backing one save up. Opting out is only ever local bookkeeping — what is
## already on the server stays there.
static func stop_backup(path: String, slot: String) -> void:
	SaveSync.set_key_enabled(RommSaveSync.card_save_key(path, slot), false)


## Opt one save in and send it straight away rather than waiting for the game to
## be played again — pressing "back this up" and having nothing happen is
## indistinguishable from it being broken. Calls back with (ok, message).
##
## Uploading needs to know which game owns the save. That is recorded whenever a
## game writes it, so a save this device has never seen written has no owner yet
## and genuinely cannot be uploaded until it is; the opt-in stays on and waiting
## and the message says so, rather than failing quietly.
static func backup_save(path: String, s: Dictionary, on_done: Callable) -> void:
	var slot := str(s["name"])
	var key := RommSaveSync.card_save_key(path, slot)
	SaveSync.set_key_enabled(key, true)

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
		on_done.call(false, "%s: no matching game in your library, so there is "
			% title_of(s) + "nothing to attach it to on RomM")
		return

	var bytes := PS1Card.extract_save(FileAccess.get_file_as_bytes(path), int(s["block"]))
	if bytes.is_empty():
		on_done.call(false, "Could not read %s" % title_of(s))
		return

	# sync_finished is global, so the handler has to recognise its own upload:
	# without this a card page would announce the result of a cartridge save
	# flushing in another room. The array holds the handler so it can unsubscribe
	# itself — a lambda cannot name the variable it is being assigned to.
	var self_ref: Array[Callable] = []
	var handler := func(k: String, action: String, ok: bool, detail: String) -> void:
		if k != key:
			return
		SaveSync.sync_finished.disconnect(self_ref[0])
		if not ok:
			on_done.call(false, "Upload failed: %s" % detail)
		elif action == "nothing":
			on_done.call(true, "Already backed up")
		else:
			on_done.call(true, "Backed up to RomM")
	self_ref.append(handler)
	SaveSync.sync_finished.connect(handler)
	SaveSync.push_card_save(key, rom_id, SramPaths.core_for_systemid(SYSTEMID),
		slot, title_of(s), bytes)
