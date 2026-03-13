## GamelistManager — loads, saves, and queries per-system gamelist.json files.
class_name GamelistManager
extends RefCounted


## Cached gamelists keyed by systemid.
var _gamelists: Dictionary = {}


## Load (or return cached) gamelist for a system. Returns the root dict {"games": [...]}.
func load_gamelist(systemid: String) -> Dictionary:
	if _gamelists.has(systemid):
		return _gamelists[systemid]

	var path := _gamelist_path(systemid)
	if not FileAccess.file_exists(path):
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_warning("[GamelistManager] Failed to open: %s" % path)
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	if err != OK:
		push_warning("[GamelistManager] JSON parse error in %s: %s" % [path, json.get_error_message()])
		var empty := {"games": []}
		_gamelists[systemid] = empty
		return empty

	var data: Dictionary = json.data if json.data is Dictionary else {"games": []}
	if not data.has("games"):
		data["games"] = []
	_gamelists[systemid] = data
	return data


## Save a gamelist to disk.
func save_gamelist(systemid: String) -> void:
	if not _gamelists.has(systemid):
		return

	var path := _gamelist_path(systemid)
	var dir_path := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("[GamelistManager] Failed to write: %s" % path)
		return

	file.store_string(JSON.stringify(_gamelists[systemid], "\t"))
	print("[GamelistManager] Saved %s" % path)


## Add or merge a ROM into the gamelist. If a game with the same game_id exists,
## the ROM is appended (or updated if same path). Otherwise a new game entry is created.
## game_data: {game_id, name, desc, developer, publisher, genre}
## rom_data: {path, romname, releasedate, region}
func add_or_merge_rom(systemid: String, game_data: Dictionary, rom_data: Dictionary) -> void:
	var gamelist := load_gamelist(systemid)
	var games: Array = gamelist["games"]
	var game_id: String = game_data.get("game_id", "")

	var existing_game: Dictionary = {}
	for g: Dictionary in games:
		if g.get("game_id", "") == game_id:
			existing_game = g
			break

	if existing_game.is_empty():
		# New game entry — first ROM is preferred
		rom_data["preferred"] = true
		var new_game := {
			"game_id": game_data.get("game_id", ""),
			"name": game_data.get("name", ""),
			"desc": game_data.get("desc", ""),
			"developer": game_data.get("developer", ""),
			"publisher": game_data.get("publisher", ""),
			"genre": game_data.get("genre", ""),
			"roms": [rom_data],
		}
		games.append(new_game)
	else:
		# Update game-level metadata
		existing_game["name"] = game_data.get("name", existing_game.get("name", ""))
		existing_game["desc"] = game_data.get("desc", existing_game.get("desc", ""))
		existing_game["developer"] = game_data.get("developer", existing_game.get("developer", ""))
		existing_game["publisher"] = game_data.get("publisher", existing_game.get("publisher", ""))
		existing_game["genre"] = game_data.get("genre", existing_game.get("genre", ""))

		# Find existing ROM by path or add new
		var roms: Array = existing_game.get("roms", [])
		var rom_path: String = rom_data.get("path", "")
		var found := false
		for i in roms.size():
			if (roms[i] as Dictionary).get("path", "") == rom_path:
				# Update existing ROM entry (re-scrape)
				var was_preferred: bool = (roms[i] as Dictionary).get("preferred", false)
				roms[i] = rom_data
				if was_preferred:
					(roms[i] as Dictionary)["preferred"] = true
				found = true
				break
		if not found:
			roms.append(rom_data)
		existing_game["roms"] = roms


## Find the game entry containing a ROM with the given path. Returns empty dict if not found.
func get_game_for_rom(systemid: String, rom_path: String) -> Dictionary:
	var relative := _to_relative_path(systemid, rom_path)
	var gamelist := load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		for r: Dictionary in g.get("roms", []):
			if r.get("path", "") == relative:
				return g
	return {}


## Get the preferred ROM dict from a game entry. Returns empty dict if none found.
static func get_preferred_rom(game: Dictionary) -> Dictionary:
	for r: Dictionary in game.get("roms", []):
		if r.get("preferred", false):
			return r
	# Fallback to first ROM
	var roms: Array = game.get("roms", [])
	if not roms.is_empty():
		return roms[0]
	return {}


## Set one ROM as preferred and clear the flag on all others.
func set_preferred_rom(systemid: String, game_id: String, rom_path: String) -> void:
	var gamelist := load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		if g.get("game_id", "") == game_id:
			for r: Dictionary in g.get("roms", []):
				r["preferred"] = (r.get("path", "") == rom_path)
			break


## Invalidate cached data for a system (forces reload on next access).
func invalidate(systemid: String) -> void:
	_gamelists.erase(systemid)


## Convert an absolute ROM path to a relative path (./filename) for storage.
static func _to_relative_path(systemid: String, rom_path: String) -> String:
	var filename := rom_path.get_file()
	return "./" + filename


## Convert a relative path from gamelist to absolute.
static func to_absolute_path(systemid: String, relative_path: String) -> String:
	var rom_dir := RomLibrary.rom_dir_for_system(systemid)
	var filename := relative_path.get_file()
	return rom_dir.path_join(filename)


func _gamelist_path(systemid: String) -> String:
	return RomLibrary.rom_dir_for_system(systemid).path_join("gamelist.json")
