## CoreInfoDatabase — in-memory store of all parsed libretro .info entries.
##
## Usage:
##   var db := CoreInfoDatabase.new()
##   db.load_from_project()  # auto-resolves path to libretro-core-info/
##   # or:
##   db.load(absolute_dir)
##
## The database is a plain RefCounted; create one instance and pass it around
## (e.g. owned by SpawnMenu2D, shared with download/manager tabs).
class_name CoreInfoDatabase
extends RefCounted


## All parsed core info entries. Each is a Dictionary with keys from the .info
## format (display_name, corename, systemname, systemid, license, description,
## supported_extensions, manufacturer, core_name, info_path, ...).
var cores: Array[Dictionary] = []

# Internal fast-lookup indices built during load().
var _by_core_name: Dictionary  = {}  # core_name -> Dictionary
var _by_systemid:  Dictionary  = {}  # systemid  -> Array[Dictionary]


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

## Load all .info files from an absolute directory path.
func load_directory(info_dir: String) -> void:
	cores = CoreInfoParser.parse_all(info_dir)
	_rebuild_indices()
	print("[CoreInfoDatabase] Loaded %d cores from: %s" % [cores.size(), info_dir])


## Convenience: load from the libretro-core-info submodule, which now lives
## inside the RetroVR project at res://libretro-core-info/.
func load_from_project() -> void:
	var info_dir: String = ProjectSettings.globalize_path("res://libretro-core-info")
	print("[CoreInfoDatabase] Resolved info dir: %s" % info_dir)
	load_directory(info_dir)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Return the entry for a core by its core_name stem (e.g. "fceumm").
## Returns an empty Dictionary if not found.
func get_by_core_name(core_name: String) -> Dictionary:
	return _by_core_name.get(core_name, {})


## Return all entries whose systemid matches (e.g. "nes").
## Returns an empty array if no entries match.
func get_by_systemid(systemid: String) -> Array[Dictionary]:
	if _by_systemid.has(systemid):
		var result: Array[Dictionary] = []
		result.assign(_by_systemid[systemid])
		return result
	return []


## Return sorted list of all distinct systemid strings present in the database.
func get_unique_systemids() -> Array[String]:
	var ids: Array[String] = []
	for key: String in _by_systemid.keys():
		if key != "":
			ids.append(key)
	ids.sort()
	return ids


## Return the human-readable systemname for a given systemid.
## Uses the first matching entry. Returns the systemid itself if not found.
func get_systemname_for_id(systemid: String) -> String:
	var entries := get_by_systemid(systemid)
	if entries.is_empty():
		return systemid
	return entries[0].get("systemname", systemid)


# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------

## Print a summary to the Godot Output panel. Useful during development.
func debug_print_summary() -> void:
	print("=== CoreInfoDatabase Summary ===")
	print("  Total cores : %d" % cores.size())
	print("  Unique systemids: %d" % get_unique_systemids().size())
	print("")
	print("  Sample entry (fceumm):")
	var sample := get_by_core_name("fceumm")
	if not sample.is_empty():
		for k: String in ["core_name","display_name","systemname","systemid","license","description"]:
			print("    %-25s = %s" % [k, sample.get(k, "<missing>")])
	else:
		print("    (not found)")
	print("")
	print("  Systems with 3+ cores:")
	for sid: String in get_unique_systemids():
		var entries := get_by_systemid(sid)
		if entries.size() >= 3:
			print("    %-30s (%d cores)  systemname='%s'" % [
				sid,
				entries.size(),
				get_systemname_for_id(sid)
			])
	print("================================")


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _rebuild_indices() -> void:
	_by_core_name.clear()
	_by_systemid.clear()

	for entry: Dictionary in cores:
		var cn: String = entry.get("core_name", "")
		if cn != "":
			_by_core_name[cn] = entry

		var sid: String = entry.get("systemid", "")
		if sid != "":
			if not _by_systemid.has(sid):
				_by_systemid[sid] = []
			(_by_systemid[sid] as Array).append(entry)
