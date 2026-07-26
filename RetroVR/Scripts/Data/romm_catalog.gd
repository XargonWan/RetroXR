## RommCatalog — a browsable index of a RomM platform that scales to 100k+ ROMs.
##
## The library is never held in RAM as Dictionaries. Each platform is synced once
## into an on-disk JSON-lines file, plus three compact sidecars that make random
## access O(1):
##
##   roms/<systemid>/.romm/index.jsonl   one slim ROM object per line, server order
##   roms/<systemid>/.romm/index.off     int64 byte offset of each line
##   roms/<systemid>/.romm/index.ids     int32 RomM rom id of each row
##   roms/<systemid>/.romm/index.names   lowercased name per line, for local search
##   roms/<systemid>/.romm/index.meta.json  {total, updated_after, synced_at, ...}
##
## At 100k rows the in-RAM cost is ~800 KB + 400 KB + a couple of MB of strings,
## and row N is one seek + one line parse. Sync runs on its own Thread with a
## blocking HTTPClient (see RommHttp) so neither the transfer nor the JSON parse
## ever touches the main thread.
class_name RommCatalog
extends Node


## sync_started(systemid, total) — total is 0 until the first page lands.
signal sync_started(systemid: String, total: int)
signal sync_progress(systemid: String, done: int, total: int)
## sync_finished(systemid, ok, added, removed, error)
signal sync_finished(systemid: String, ok: bool, added: int, removed: int, error: String)

## RomM caps `limit` at 10000, but every /api/roms response also carries the full
## ordered rom_id_index for the whole result set (~700 KB at 100k ROMs) with no
## opt-out in 5.0.0. Per-item JSON dominates above ~300, so 1000 balances the two
## and keeps each body around 3 MB — parseable off-thread without a hitch.
const PAGE_LIMIT := 1000

var config: RommConfig = null

# ── Loaded platform (one at a time — whichever the user is browsing) ──────────
var _loaded_systemid: String = ""
var _offsets := PackedInt64Array()
var _ids := PackedInt32Array()
var _names := PackedStringArray()
var _index_file: FileAccess = null

# ── Sync thread ──────────────────────────────────────────────────────────────
var _thread: Thread = null
var _abort := false
var _mutex := Mutex.new()
var _syncing_systemid: String = ""


func setup(cfg: RommConfig) -> void:
	config = cfg


func _exit_tree() -> void:
	# Without this, quitting mid-sync hangs the app on the socket.
	abort_sync()


## Signal the sync thread to stop and join it. Safe to call when idle.
func abort_sync() -> void:
	_abort = true
	if _thread != null:
		if _thread.is_started():
			_thread.wait_to_finish()
		_thread = null
	_abort = false
	_syncing_systemid = ""


func is_syncing() -> bool:
	return _thread != null and _thread.is_alive()


func syncing_systemid() -> String:
	return _syncing_systemid


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

static func index_dir(systemid: String) -> String:
	return RomLibrary.rom_dir_for_system(systemid).path_join(".romm")


static func index_path(systemid: String) -> String:
	return index_dir(systemid).path_join("index.jsonl")


static func meta_path(systemid: String) -> String:
	return index_dir(systemid).path_join("index.meta.json")


static func has_index(systemid: String) -> bool:
	return FileAccess.file_exists(index_path(systemid))


static func read_meta(systemid: String) -> Dictionary:
	var path := meta_path(systemid)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


# ---------------------------------------------------------------------------
# Reading a synced platform
# ---------------------------------------------------------------------------

## Load a platform's sidecars into memory. Cheap: two binary reads and one text
## split. Returns false when that platform has never been synced.
func load_index(systemid: String) -> bool:
	if _loaded_systemid == systemid and _index_file != null:
		return true

	unload_index()

	var dir := index_dir(systemid)
	var jsonl := index_path(systemid)
	if not FileAccess.file_exists(jsonl):
		return false

	var off_bytes := _read_file_bytes(dir.path_join("index.off"))
	var id_bytes := _read_file_bytes(dir.path_join("index.ids"))
	if off_bytes.is_empty():
		return false

	_offsets = off_bytes.to_int64_array()
	_ids = id_bytes.to_int32_array() if not id_bytes.is_empty() else PackedInt32Array()

	var names_file := FileAccess.open(dir.path_join("index.names"), FileAccess.READ)
	if names_file != null:
		var text := names_file.get_as_text()
		_names = PackedStringArray(text.split("\n", false))
	else:
		_names = PackedStringArray()

	_index_file = FileAccess.open(jsonl, FileAccess.READ)
	if _index_file == null:
		return false

	_loaded_systemid = systemid
	return true


func unload_index() -> void:
	_index_file = null
	_loaded_systemid = ""
	_offsets = PackedInt64Array()
	_ids = PackedInt32Array()
	_names = PackedStringArray()


func loaded_systemid() -> String:
	return _loaded_systemid


## Number of rows in the loaded platform.
func count() -> int:
	return _offsets.size()


## Row N as a Dictionary — one seek and one line parse, microseconds.
## Only call for rows that are actually on screen.
func row(i: int) -> Dictionary:
	if _index_file == null or i < 0 or i >= _offsets.size():
		return {}
	_index_file.seek(_offsets[i])
	var line := _index_file.get_line()
	if line.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(line)
	return parsed if parsed is Dictionary else {}


func rom_id_at(i: int) -> int:
	if i < 0 or i >= _ids.size():
		return 0
	return _ids[i]


## Case-insensitive substring search over the cached names — no server round
## trip, works offline, and instant even at 100k rows. Returns row indices.
## `limit` caps the result so a one-letter query can't build a huge array.
func search(term: String, limit: int = 5000) -> PackedInt32Array:
	var out := PackedInt32Array()
	var needle := term.strip_edges().to_lower()
	if needle.is_empty():
		return out
	for i in _names.size():
		if _names[i].contains(needle):
			out.append(i)
			if out.size() >= limit:
				break
	return out


# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

## Start a full or delta sync of one platform on a worker thread.
## Only one sync runs at a time; a second call while busy is ignored.
func sync_platform(systemid: String, platform_id: int, full: bool = false) -> bool:
	if config == null or not config.is_configured():
		return false
	if is_syncing():
		return false

	abort_sync()  # joins any finished-but-unjoined thread

	_syncing_systemid = systemid
	_thread = Thread.new()
	var args := {
		"systemid": systemid,
		"platform_id": platform_id,
		"full": full,
		"base_url": config.base_url,
		"headers": config.auth_headers(),
		"group": config.group_by_meta_id,
		"updated_after": "" if full else str(config.get_sync_state(systemid).get("updated_after", "")),
	}
	var err := _thread.start(_sync_worker.bind(args))
	if err != OK:
		_thread = null
		_syncing_systemid = ""
		return false
	return true


# --- worker thread ---------------------------------------------------------

func _sync_worker(args: Dictionary) -> void:
	var systemid: String = args["systemid"]
	var platform_id: int = args["platform_id"]
	var headers: PackedStringArray = args["headers"]
	var updated_after: String = args["updated_after"]
	var is_delta := not updated_after.is_empty()

	var http := RommHttp.new()
	if http.open(args["base_url"]) != RommHttp.Result.OK:
		_finish.call_deferred(systemid, false, 0, 0, "Could not reach the server")
		return

	var dir := index_dir(systemid)
	DirAccess.make_dir_recursive_absolute(dir)

	# A delta rewrites the whole index from the merged result, so both paths
	# build a fresh file and swap it in atomically at the end. Partial index
	# files must never be readable — a truncated .jsonl would desync the
	# offsets sidecar and show wrong rows.
	var tmp_jsonl := dir.path_join("index.jsonl.part")
	var out := FileAccess.open(tmp_jsonl, FileAccess.WRITE)
	if out == null:
		http.close()
		_finish.call_deferred(systemid, false, 0, 0, "Cannot write to %s" % dir)
		return

	# Existing rows, kept when this is a delta (id -> line).
	var existing: Dictionary = {}
	if is_delta:
		existing = _read_existing_rows(index_path(systemid))

	var fetched: Dictionary = {}     # id -> slim row line
	var order: Array[String] = []    # names in server order, for stable sorting
	var offset := 0
	var total := 0
	var max_updated := updated_after
	var first_page := true
	var error := ""

	while true:
		if _abort:
			out.close()
			http.close()
			DirAccess.remove_absolute(tmp_jsonl)
			return

		var path := _page_path(platform_id, offset, args["group"], updated_after, first_page)
		var resp := http.get_json(path, headers, func() -> bool: return _abort)
		var result := int(resp["result"])

		if result != RommHttp.Result.OK:
			var code := int(resp["code"])
			if code == 401 or code == 403:
				error = "Sign-in rejected by RomM"
			elif code > 0:
				error = "Server error (HTTP %d)" % code
			else:
				error = "Connection lost during sync"
			break

		var page: Dictionary = resp["data"] if resp["data"] is Dictionary else {}
		var items: Array = page.get("items", []) if page.get("items") is Array else []
		if first_page:
			total = int(page.get("total", 0))
			_started.call_deferred(systemid, total)
			first_page = false

		if items.is_empty():
			break

		for item: Dictionary in items:
			var slim := _slim_row(item)
			var id := int(slim.get("id", 0))
			if id == 0:
				continue
			fetched[id] = JSON.stringify(slim)
			var upd := str(slim.get("updated_at", ""))
			if upd > max_updated:
				max_updated = upd

		offset += items.size()
		_progress.call_deferred(systemid, offset, total)

		if offset >= total or items.size() < PAGE_LIMIT:
			break

	http.close()

	if not error.is_empty():
		out.close()
		DirAccess.remove_absolute(tmp_jsonl)
		_finish.call_deferred(systemid, false, 0, 0, error)
		return

	# Merge: fetched rows win over existing ones with the same id.
	var merged: Dictionary = existing.duplicate()
	var added := 0
	for id: int in fetched:
		if not merged.has(id):
			added += 1
		merged[id] = fetched[id]

	# Sort by name so the list reads alphabetically the way the server would
	# order it (RomM sorts on an article-stripped name_sort_key; close enough
	# locally, and it keeps delta merges stable).
	var rows: Array = []
	for id: int in merged:
		var line: String = merged[id]
		var parsed: Variant = JSON.parse_string(line)
		var name := ""
		if parsed is Dictionary:
			name = str((parsed as Dictionary).get("sort_name", ""))
		rows.append({"name": name, "line": line, "id": id})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["name"] as String).naturalnocasecmp_to(b["name"] as String) < 0
	)

	# Write the index plus its three sidecars in one pass.
	var offsets := PackedInt64Array()
	var ids := PackedInt32Array()
	var names_text := ""
	var pos := 0
	for r: Dictionary in rows:
		var line: String = r["line"]
		offsets.append(pos)
		ids.append(int(r["id"]))
		names_text += str(r["name"]) + "\n"
		var bytes := (line + "\n").to_utf8_buffer()
		out.store_buffer(bytes)
		pos += bytes.size()
	out.close()

	_write_bytes(dir.path_join("index.off"), _int64_bytes(offsets))
	_write_bytes(dir.path_join("index.ids"), _int32_bytes(ids))
	_write_text(dir.path_join("index.names"), names_text)

	# Atomic swap — readers never see a half-written index.
	var final_path := index_path(systemid)
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	DirAccess.rename_absolute(tmp_jsonl, final_path)

	_write_text(meta_path(systemid), JSON.stringify({
		"total": rows.size(),
		"updated_after": max_updated,
		"synced_at": Time.get_datetime_string_from_system(true),
		"group_by_meta_id": args["group"],
		"platform_id": platform_id,
	}, "\t"))

	var removed := 0  # deletions are reconciled separately via /api/roms/identifiers
	_finish.call_deferred(systemid, true, added, removed, "")


## Build one page request. `with_char_index` only on the first page — after that
## it's pure payload. `with_filter_values`/`with_files` are always off.
func _page_path(platform_id: int, offset: int, group: bool,
				updated_after: String, first_page: bool) -> String:
	var path := "/api/roms?limit=%d&offset=%d&order_by=name&order_dir=asc" % [PAGE_LIMIT, offset]
	if platform_id > 0:
		path += "&platform_ids=%d" % platform_id
	path += "&group_by_meta_id=%s" % ("true" if group else "false")
	path += "&with_char_index=%s" % ("true" if first_page else "false")
	path += "&with_filter_values=false&with_files=false"
	if not updated_after.is_empty():
		path += "&updated_after=" + updated_after.uri_encode()
	return path


## Keep only the fields the browser needs. The raw provider blobs
## (igdb_metadata, ss_metadata, …) are large and unused here; summary and the
## rest are fetched on demand from /api/roms/{id} when a detail panel opens.
static func _slim_row(item: Dictionary) -> Dictionary:
	var meta: Dictionary = item.get("metadatum", {}) if item.get("metadatum") is Dictionary else {}
	var name := str(item.get("name", ""))
	if name.is_empty():
		name = str(item.get("fs_name_no_tags", item.get("fs_name", "")))

	return {
		"id": int(item.get("id", 0)),
		"name": name,
		"sort_name": str(item.get("name_sort_key", name)).to_lower(),
		"fs_name": str(item.get("fs_name", "")),
		"fs_extension": str(item.get("fs_extension", "")),
		"fs_size_bytes": int(item.get("fs_size_bytes", 0)),
		"md5_hash": str(item.get("md5_hash", "")),
		"sha1_hash": str(item.get("sha1_hash", "")),
		"crc_hash": str(item.get("crc_hash", "")),
		"regions": item.get("regions", []),
		"languages": item.get("languages", []),
		"revision": str(item.get("revision", "")),
		"cover_small": str(item.get("path_cover_small", "")),
		"cover_large": str(item.get("path_cover_large", "")),
		"has_manual": bool(item.get("has_manual", false)),
		"multi": bool(item.get("has_multiple_files", false)),
		"updated_at": str(item.get("updated_at", "")),
		"first_release_date": int(meta.get("first_release_date", 0)),
		"genres": meta.get("genres", []),
		"companies": meta.get("companies", []),
	}


static func _read_existing_rows(path: String) -> Dictionary:
	var out: Dictionary = {}
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var id := int((parsed as Dictionary).get("id", 0))
			if id != 0:
				out[id] = line
	return out


# --- main-thread signal marshalling ----------------------------------------

func _started(systemid: String, total: int) -> void:
	sync_started.emit(systemid, total)


func _progress(systemid: String, done: int, total: int) -> void:
	sync_progress.emit(systemid, done, total)


func _finish(systemid: String, ok: bool, added: int, removed: int, error: String) -> void:
	_syncing_systemid = ""
	# Drop any loaded view of this platform so the next open re-reads the new index.
	if _loaded_systemid == systemid:
		unload_index()
	sync_finished.emit(systemid, ok, added, removed, error)


# --- small file helpers -----------------------------------------------------

static func _read_file_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	return f.get_buffer(f.get_length())


static func _write_bytes(path: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[RommCatalog] cannot write %s" % path)
		return
	f.store_buffer(data)


static func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[RommCatalog] cannot write %s" % path)
		return
	f.store_string(text)


static func _int64_bytes(arr: PackedInt64Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(arr.size() * 8)
	for i in arr.size():
		out.encode_s64(i * 8, arr[i])
	return out


static func _int32_bytes(arr: PackedInt32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(arr.size() * 4)
	for i in arr.size():
		out.encode_s32(i * 4, arr[i])
	return out
