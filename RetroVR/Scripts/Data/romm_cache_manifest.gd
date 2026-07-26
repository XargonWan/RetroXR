## RommCacheManifest — records which ROM files came from the RomM server.
##
## This is what makes eviction safe: a downloaded ROM is written into
## roms/<systemid>/ under its real filename so it is indistinguishable from a
## hand-copied one to every other system (scan_roms, gamelist, SRAM paths, scene
## restore, netplay MD5). The manifest is the only thing that knows which of
## those files may be deleted to reclaim space — anything not listed here was put
## there by the user and is never touched.
##
## Mirrors download_manifest.gd's shape.
class_name RommCacheManifest
extends RefCounted


## Emitted after any mutation, so visible rows can re-bind. Without this,
## background eviction removes a file behind a row and its icon starts lying.
signal changed


## "<systemid>/<fs_name>" -> {rom_id, size, md5, downloaded_at, last_used_at}
var _entries: Dictionary = {}


func load_manifest() -> void:
	var path := manifest_path()
	if not FileAccess.file_exists(path):
		_entries = {}
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_warning("[RommCache] JSON parse error, starting empty")
		_entries = {}
		return
	var data: Dictionary = json.data if json.data is Dictionary else {}
	var e: Variant = data.get("entries", {})
	_entries = e if e is Dictionary else {}


func save_manifest() -> void:
	var path := manifest_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[RommCache] cannot write %s" % path)
		return
	f.store_string(JSON.stringify({"version": 1, "entries": _entries}, "\t"))


static func manifest_path() -> String:
	return RomLibrary.default_roms_root().path_join("romm_cache.json")


static func make_key(systemid: String, fs_name: String) -> String:
	return "%s/%s" % [systemid, fs_name]


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func is_cached(systemid: String, fs_name: String) -> bool:
	var key := make_key(systemid, fs_name)
	if not _entries.has(key):
		return false
	# The file could have been deleted outside the app; trust the disk.
	return FileAccess.file_exists(local_path(systemid, fs_name))


func entry(systemid: String, fs_name: String) -> Dictionary:
	var v: Variant = _entries.get(make_key(systemid, fs_name), {})
	return v if v is Dictionary else {}


static func local_path(systemid: String, fs_name: String) -> String:
	return RomLibrary.rom_dir_for_system(systemid).path_join(fs_name)


## Total bytes attributable to server-sourced ROMs.
func total_bytes() -> int:
	var sum := 0
	for key: String in _entries:
		var e: Dictionary = _entries[key]
		sum += int(e.get("size", 0))
	return sum


## Every cached file, oldest use first — the eviction order.
func lru_keys() -> Array[String]:
	var keys: Array[String] = []
	for k: String in _entries:
		keys.append(k)
	keys.sort_custom(func(a: String, b: String) -> bool:
		var ea: Dictionary = _entries[a]
		var eb: Dictionary = _entries[b]
		return float(ea.get("last_used_at", 0.0)) < float(eb.get("last_used_at", 0.0))
	)
	return keys


# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------

func add(systemid: String, fs_name: String, rom_id: int, size: int, md5: String) -> void:
	_entries[make_key(systemid, fs_name)] = {
		"rom_id": rom_id,
		"systemid": systemid,
		"fs_name": fs_name,
		"size": size,
		"md5": md5,
		"downloaded_at": Time.get_datetime_string_from_system(true),
		"last_used_at": Time.get_unix_time_from_system(),
	}
	save_manifest()
	changed.emit()


## Stamp a file as just used, so eviction prefers colder ones.
##
## Sub-second resolution matters: a datetime STRING only ticks once a second, so
## several downloads (or a download then a launch) inside the same second all
## compared equal and the LRU order collapsed to insertion order.
func touch(systemid: String, fs_name: String) -> void:
	var key := make_key(systemid, fs_name)
	if not _entries.has(key):
		return
	var e: Dictionary = _entries[key]
	e["last_used_at"] = Time.get_unix_time_from_system()
	_entries[key] = e
	save_manifest()


## Delete the file and forget it. Returns bytes reclaimed.
## The media/, gamelist.json and .srm sidecars are deliberately KEPT — they are
## kilobytes, they make a re-download instant, and dropping saves would be
## actual data loss.
func evict(key: String) -> int:
	if not _entries.has(key):
		return 0
	var e: Dictionary = _entries[key]
	var size := int(e.get("size", 0))
	var path := local_path(str(e.get("systemid", "")), str(e.get("fs_name", "")))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_entries.erase(key)
	save_manifest()
	changed.emit()
	return size


func forget(systemid: String, fs_name: String) -> void:
	_entries.erase(make_key(systemid, fs_name))
	save_manifest()
	changed.emit()


## Free space until `needed_bytes` fits inside `budget_bytes`.
## `protected` holds keys that must not be evicted (currently inserted in a
## powered-on system, or the download in flight).
## Returns {freed: int, count: int, enough: bool}.
func evict_to_fit(needed_bytes: int, budget_bytes: int,
				  protected_keys: Array = []) -> Dictionary:
	var freed := 0
	var count := 0
	var used := total_bytes()

	if used + needed_bytes <= budget_bytes:
		return {"freed": 0, "count": 0, "enough": true}

	for key: String in lru_keys():
		if key in protected_keys:
			continue
		var size := evict(key)
		if size > 0:
			freed += size
			count += 1
			used -= size
		if used + needed_bytes <= budget_bytes:
			break

	return {
		"freed": freed,
		"count": count,
		"enough": used + needed_bytes <= budget_bytes,
	}
