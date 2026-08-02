## SramPaths — the single source of truth for where battery saves (.srm) live.
##
## Layout (append-only; nothing here ever deletes a file):
##   <root>/save/<core_name>/<game_stem>/<save_id>.srm            cartridge saves
##   <root>/save/<core_name>/memcards/<card_id>/<game_stem>.srm   memory-card saves
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


static func card_save_path(core_name: String, rom_path: String, card_id: String) -> String:
	return core_save_dir(core_name).path_join("memcards").path_join(card_id) \
		.path_join(game_stem(rom_path) + ".srm")


## Resolve the default core for a cartridge's systemid ("" when unknown).
static func core_for_systemid(systemid: String) -> String:
	if systemid.is_empty():
		return ""
	var defaults := CoreDefaults.new()
	defaults.setup(CoreDefaults.default_path())
	return defaults.get_default_core(systemid)


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
