## SramPaths — the single source of truth for where battery saves live.
##
## Layout (append-only; nothing here ever deletes a file):
##   <root>/save/<core_name>/<game_stem>/<save_id>.srm   cartridge saves
##   <root>/save/memcards/<systemid>/<card_id>.mcr       memory cards
##
## A cartridge holds its own save, so its path is keyed by game. A memory card
## is the opposite: ONE image that every game on that console writes into, which
## is the whole point of a card and what lets a game read saves another game
## left behind. Splitting a card per game would defeat it.
##
## Card paths deliberately carry no core name — a card is hardware, and the raw
## 128 KB image is the same for every PS1 core, so a card survives switching
## cores the way a real one survives switching consoles.
##
## Used by RetroSystem (composing the path handed to Libretro.SetSramPath at
## power-on) and by the cartridge options panel (listing recoverable saves).
class_name SramPaths
extends RefCounted


static func game_stem(rom_path: String) -> String:
	return rom_path.get_file().get_basename()


## save/<core> root for a given core, under the libretro root directory.
static func core_save_dir(core_name: String) -> String:
	return CoreDownloadManager.default_core_root().path_join("save").path_join(core_name)


static func cart_save_dir(core_name: String, rom_path: String) -> String:
	return core_save_dir(core_name).path_join(game_stem(rom_path))


static func cart_save_path(core_name: String, rom_path: String, save_id: String) -> String:
	return cart_save_dir(core_name, rom_path).path_join(save_id + ".srm")


## save/memcards/<systemid> — every card belonging to one console family.
static func cards_dir(systemid: String) -> String:
	return CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("memcards").path_join(systemid)


## The one image this card is. No core, no game — see the header.
static func card_save_path(systemid: String, card_id: String) -> String:
	return cards_dir(systemid).path_join(card_id + ".mcr")


## A card's NAME IS ITS FILENAME, so the folder reads as a shelf of cards and can
## be managed from outside RetroXR — these are ordinary .mcr images that any PS1
## card tool opens. That makes the name the identity: renaming a card moves its
## file, and `card_id` is just the sanitised name.
##
## Strips what Windows forbids in a filename, plus the trailing dots and spaces
## it silently drops, and caps the length so a pasted essay can't produce a path
## no one can delete. Never returns "" — an all-punctuation name would otherwise
## produce a bare ".mcr".
static func sanitize_card_name(text: String) -> String:
	var out := ""
	for c in text.strip_edges():
		if c in "<>:\"/\\|?*" or c.unicode_at(0) < 32:
			continue
		out += c
	while out.ends_with(".") or out.ends_with(" "):
		out = out.substr(0, out.length() - 1)
	out = out.substr(0, 48).strip_edges()
	return out if not out.is_empty() else "MEMORY CARD"


## `base`, or `base 2`, `base 3`… until no console already has a card by that
## name. Two cards sharing a filename would share their saves.
static func unique_card_id(base: String) -> String:
	var name := sanitize_card_name(base)
	if find_card(name).is_empty():
		return name
	var n := 2
	while not find_card("%s %d" % [name, n]).is_empty():
		n += 1
	return "%s %d" % [name, n]


## Rename a card's image to match its new name. Returns the new card_id, or ""
## when the name is already taken — refused rather than merged, because two
## cards pointing at one file would silently share saves.
##
## A card with no image yet (never seated) has nothing to move; the new id is
## still returned so the object can adopt it.
static func rename_card(old_id: String, new_label: String) -> String:
	var new_id := sanitize_card_name(new_label)
	if new_id == old_id:
		return old_id
	if not find_card(new_id).is_empty():
		return ""
	var old_path := find_card(old_id)
	if old_path.is_empty():
		return new_id
	var new_path := old_path.get_base_dir().path_join(new_id + ".mcr")
	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		push_error("[SramPaths] cannot rename card %s -> %s (%d)" % [old_path, new_path, err])
		return ""
	return new_id


## Every card that exists on disk, newest first. Entries:
##   card_id, path, label, mtime, saves (int), free (int)
##
## A card only appears once it has been seated in a powered console — that is
## when its image is written — so a freshly spawned card that has never been
## used is deliberately absent.
static func list_cards(systemid: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := cards_dir(systemid)
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for fname: String in DirAccess.get_files_at(dir):
		if fname.get_extension().to_lower() != "mcr":
			continue
		var path := dir.path_join(fname)
		var card_id := fname.get_basename()
		var saves := 0
		var free := 15
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data := f.get_buffer(f.get_length())
			f.close()
			saves = PS1Card.list_saves(data).size()
			free = PS1Card.free_blocks(data)
		out.append({
			"card_id": card_id,
			"path": path,
			"label": card_id,
			"mtime": FileAccess.get_modified_time(path),
			"saves": saves,
			"free": free,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["mtime"]) > int(b["mtime"]))
	return out


## The existing image for a card id, or "" when it has never been seated in a
## powered console. A loose card in the room doesn't know which console it
## belongs to, so this looks across every console's card folder rather than
## making the card carry a systemid it would also have to persist.
static func find_card(card_id: String) -> String:
	if card_id.is_empty():
		return ""
	var root := CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("memcards")
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for sid: String in DirAccess.get_directories_at(root):
		var p := root.path_join(sid).path_join(card_id + ".mcr")
		if FileAccess.file_exists(p):
			return p
	return ""


## The card's path, creating a formatted blank first if it has none yet. A card
## has to arrive formatted because RetroXR never boots the PS1 BIOS, so the
## player has no way to format one. Never touches an image that already exists.
static func ensure_card(systemid: String, card_id: String) -> String:
	var path := card_save_path(systemid, card_id)
	if FileAccess.file_exists(path):
		return path
	DirAccess.make_dir_recursive_absolute(cards_dir(systemid))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[SramPaths] cannot create memory card %s" % path)
		return path
	f.store_buffer(PS1Card.blank_image())
	f.close()
	return path


## Resolve the default core for a cartridge's systemid ("" when unknown).
static func core_for_systemid(systemid: String) -> String:
	if systemid.is_empty():
		return ""
	var defaults := CoreDefaults.new()
	defaults.setup(CoreDefaults.default_path())
	return defaults.get_default_core(systemid)


## Erase one .srm. Nothing keeps a copy, so both menus that offer this ask twice
## first, and neither offers it while the console holding the game is on — the
## core would write the file straight back on its next flush.
static func delete_save(core_name: String, rom_path: String, save_id: String) -> bool:
	if core_name.is_empty() or save_id.is_empty():
		return false
	var path := cart_save_path(core_name, rom_path, save_id)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


## Every existing .srm for this game (save recovery list). Entries:
## {save_id, path, mtime, size}, newest first.
static func list_saves(core_name: String, rom_path: String) -> Array:
	var out: Array = []
	var dir := cart_save_dir(core_name, rom_path)
	if core_name.is_empty() or not DirAccess.dir_exists_absolute(dir):
		return out
	for fname: String in DirAccess.get_files_at(dir):
		if fname.get_extension().to_lower() != "srm":
			continue
		var path := dir.path_join(fname)
		out.append({
			"save_id": fname.get_basename(),
			"path": path,
			"mtime": FileAccess.get_modified_time(path),
			"size": NetFileTransfer.size_of(path),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["mtime"]) > int(b["mtime"]))
	return out
