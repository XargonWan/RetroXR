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

static var _shared: CoreInfoDatabase = null


## Lazily-loaded process-wide instance, for callers that want a single lookup and
## should not pay to re-parse all 306 .info files to get it. Safe to cache: the
## directory ships inside the pck and cannot change at runtime.
static func shared() -> CoreInfoDatabase:
	if _shared == null:
		_shared = CoreInfoDatabase.new()
		_shared.load_from_project()
	return _shared


## Union of supported_extensions (lowercase, no dots) across every core that
## serves this systemid.
static func extensions_for_systemid(systemid: String) -> Array[String]:
	var exts: Array[String] = []
	for entry: Dictionary in shared().get_by_systemid(systemid):
		for e: String in str(entry.get("supported_extensions", "")).split("|"):
			var s := e.strip_edges().to_lower()
			if not s.is_empty() and s not in exts:
				exts.append(s)
	return exts


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
	var info_dir: String = "res://libretro-core-info"
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


## Display-name overrides for systemids the bundled core-info database names
## poorly (or not at all). Kept here rather than patched into the core-info
## submodule, which we do not own — see plans/known-issues.md "Core-Info".
const _NAME_OVERRIDES := {
	"playstation_portable": "PlayStation Portable",
}


## Return the human-readable systemname for a given systemid.
## Overrides win; then the core-info entry; then a prettified fallback so a raw
## "playstation_portable"-style id never reaches the UI verbatim.
func get_systemname_for_id(systemid: String) -> String:
	if _NAME_OVERRIDES.has(systemid):
		return _NAME_OVERRIDES[systemid]
	var entries := get_by_systemid(systemid)
	if entries.is_empty():
		return _prettify_systemid(systemid)
	var nm: String = entries[0].get("systemname", systemid)
	# The DB returns the raw id when it has no systemname — prettify that.
	return _prettify_systemid(systemid) if nm == systemid else nm


## Title-case an underscore systemid as a last-resort display name.
func _prettify_systemid(systemid: String) -> String:
	if systemid.is_empty():
		return systemid
	var words := PackedStringArray()
	for w in systemid.split("_", false):
		words.append(w.capitalize() if w.length() > 0 else w)
	return " ".join(words)


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
