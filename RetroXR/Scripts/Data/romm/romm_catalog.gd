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

## RomM caps `limit` at 10000. 1000 keeps each body around 3 MB — parseable
## off-thread without a hitch.
const PAGE_LIMIT := 1000

## The server charges a large fixed cost per /api/roms request on a big platform,
## independent of `limit`: a 59k-ROM PlayStation page measured ~5 s ungrouped and
## ~75 s grouped whether it returned 250 rows or 5000. Past this size the only
## lever is asking for fewer, bigger pages.
const LARGE_PLATFORM_ROWS := 20000
## Held well below the 10000 cap: the body is decoded to a Godot String (UTF-32
## internally, so ~4x the wire size) before JSON.parse sees it, and that transient
## is the binding constraint on Quest.
const PAGE_LIMIT_LARGE := 2500

## A page is a database query, not a static file, and a grouped query over a very
## large platform measured 90-100 s of server think time before the first header
## byte. The 30 s default reported that as a lost connection, which is what made
## PlayStation impossible to sync at all.
##
## The *final* page is far worse than the rest — 271 s measured against 94 s for
## the page before it, on a fresh connection, so it is the tail rows themselves
## and not a deep OFFSET or a stale socket. This ceiling clears that with margin.
const SYNC_RESPONSE_TIMEOUT_SEC := 480.0

## Attempts per page, including the first. A large platform is ~20 pages over
## half an hour, and one failure used to discard the entire run.
const PAGE_RETRIES := 3
## Multiplied by the attempt number, so 2 s then 4 s.
const PAGE_RETRY_BACKOFF_MS := 2000

var config: RommConfig = null

# ── Loaded platform (one at a time — whichever the user is browsing) ──────────
var _loaded_systemid: String = ""
var _offsets := PackedInt64Array()
var _ids := PackedInt32Array()
var _names := PackedStringArray()
## Parallel sidecars, so filtering and dedupe never parse JSON.
var _fs_names := PackedStringArray()
var _regions := PackedStringArray()
var _index_file: FileAccess = null

## Platforms whose sidecars have been pulled into the file cache this session.
var _prewarmed: Dictionary = {}
var _warm_queue: Array[String] = []
var _warm_thread: Thread = null
var _warming := false

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
	if _warm_thread != null and _warm_thread.is_started():
		_warm_thread.wait_to_finish()
		_warm_thread = null


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

## Read a platform's sidecar files on a worker thread, purely to pull them into
## the OS file cache. Nothing is kept — the point is that the load_index() the
## UI does moments later hits warm pages.
##
## Measured on desktop NVMe: cold 25-37 ms, warm 1.3-2.0 ms for 3-7k rows. The
## work is I/O, not parsing, so this is worth doing off-thread even though the
## parse itself is trivial. Quest internal storage is far slower again, which is
## where the stutter on opening a platform came from.
func prewarm_index(systemid: String) -> void:
	if systemid.is_empty() or _loaded_systemid == systemid:
		return
	if _prewarmed.has(systemid) or systemid in _warm_queue:
		return
	if not has_index(systemid):
		return
	_warm_queue.append(systemid)
	_warm_pump()


func _warm_pump() -> void:
	if _warming or _warm_queue.is_empty():
		return
	if _warm_thread != null and _warm_thread.is_started():
		_warm_thread.wait_to_finish()
	var sid: String = _warm_queue.pop_front()
	# Marked only once it is actually being read, so a platform dropped from a
	# busy queue is not remembered as warmed.
	_prewarmed[sid] = true
	_warming = true
	_warm_thread = Thread.new()
	_warm_thread.start(_warm_worker.bind(index_dir(sid)))


func _warm_worker(dir: String) -> void:
	# An index synced before the fsnames/regions sidecars existed still works,
	# but only through a fallback that parses one JSON line per row. Measured on
	# Quest that is 543 ms to open a 3.1k platform against ~10 ms with them —
	# the single biggest stutter in the menu, and invisible on a dev machine
	# whose indexes have all been re-synced. Everything needed is already in
	# index.jsonl, so rebuild them here rather than making the user re-sync.
	_backfill_sidecars(dir)

	for f: String in ["index.off", "index.ids", "index.names",
					  "index.fsnames", "index.regions"]:
		# Read and discarded: the file cache is the whole product.
		var _b := FileAccess.get_file_as_bytes(dir.path_join(f))
	_warm_done.call_deferred()


## Regenerate index.fsnames and index.regions from index.jsonl. One pass, no
## network. Worker-thread only.
static func _backfill_sidecars(dir: String) -> void:
	var fs_path := dir.path_join("index.fsnames")
	var rg_path := dir.path_join("index.regions")
	if FileAccess.file_exists(fs_path) and FileAccess.file_exists(rg_path):
		return

	var offsets := _read_offsets(dir)
	if offsets.is_empty():
		return
	var jsonl := FileAccess.open(dir.path_join("index.jsonl"), FileAccess.READ)
	if jsonl == null:
		return

	var fsnames := ""
	var regions := ""
	for off: int in offsets:
		jsonl.seek(off)
		var parsed: Variant = JSON.parse_string(jsonl.get_line())
		var fs_base := ""
		var joined := ""
		if parsed is Dictionary:
			var pd := parsed as Dictionary
			fs_base = str(pd.get("fs_name", "")).get_basename().to_lower()
			var rl: Array = pd.get("regions", []) if pd.get("regions") is Array else []
			var parts := PackedStringArray()
			for r: Variant in rl:
				parts.append(str(r))
			joined = "".join(parts)
		fsnames += fs_base + "\n"
		regions += joined + "\n"
	jsonl.close()

	# Written only once both are built: a half-backfilled index would report
	# fast sidecars it does not have. Through a temp file and a rename, because
	# two catalog instances can each decide to backfill the same platform and a
	# reader must never see one of them mid-write.
	_write_text_atomic(fs_path, fsnames)
	_write_text_atomic(rg_path, regions)
	print("[RommCatalog] backfilled sidecars for %d rows in %s" % [offsets.size(), dir])


static func _read_offsets(dir: String) -> PackedInt64Array:
	var b := FileAccess.get_file_as_bytes(dir.path_join("index.off"))
	return b.to_int64_array() if not b.is_empty() else PackedInt64Array()


func _warm_done() -> void:
	_warming = false
	_warm_pump()


## Load a platform's sidecars into memory. Cheap once warm: two binary reads and
## one text split. Cold, it is dominated by disk I/O — see prewarm_index().
## Returns false when that platform has never been synced.
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
		_fs_names = PackedStringArray()
		_regions = PackedStringArray()

	_fs_names = _read_lines(dir.path_join("index.fsnames"))
	_regions = _read_lines(dir.path_join("index.regions"))

	_index_file = FileAccess.open(jsonl, FileAccess.READ)
	if _index_file == null:
		return false

	# A half-swapped index (offsets from one write, jsonl from another) produces
	# seeks into the middle of lines and rows that silently parse to nothing.
	if _names.size() != _offsets.size() or _ids.size() != _offsets.size():
		push_warning("[RommCatalog] %s index is inconsistent (%d offsets, %d names, %d ids) — needs a re-sync"
			% [systemid, _offsets.size(), _names.size(), _ids.size()])
		unload_index()
		return false

	_loaded_systemid = systemid
	return true


func unload_index() -> void:
	_index_file = null
	_loaded_systemid = ""
	_offsets = PackedInt64Array()
	_ids = PackedInt32Array()
	_names = PackedStringArray()
	# Cleared too, or has_fast_sidecars() compares the previous platform's
	# arrays against the new one's offsets and can claim a fast path that is
	# not there.
	_fs_names = PackedStringArray()
	_regions = PackedStringArray()


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


## Display name, lowercase fs_name basename and regions for row i, all
## from sidecars already in RAM: a full rebuild costs no seeks, no parses.
func name_at(i: int) -> String:
	return _names[i] if i >= 0 and i < _names.size() else ""


func fs_basename_at(i: int) -> String:
	return _fs_names[i] if i >= 0 and i < _fs_names.size() else ""


func regions_at(i: int) -> PackedStringArray:
	if i < 0 or i >= _regions.size() or _regions[i].is_empty():
		return PackedStringArray()
	return _regions[i].split("", false)


## False for an index synced before these sidecars existed.
func has_fast_sidecars() -> bool:
	return _fs_names.size() == _offsets.size() and _regions.size() == _offsets.size()


func rom_id_at(i: int) -> int:
	if i < 0 or i >= _ids.size():
		return 0
	return _ids[i]


## Case-insensitive substring search over the cached names — no server round
## trip, works offline, and instant even at 100k rows. Returns row indices.
## `limit` caps the result so a one-letter query can't build a huge array.
func search(term: String, limit: int = 5000) -> PackedInt32Array:
	var out := PackedInt32Array()
	var needle := term.strip_edges()
	if needle.is_empty():
		return out
	for i in _names.size():
		if _names[i].containsn(needle):
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

	# The worker replaces index.jsonl by rename. Windows will not rename over a
	# file we still hold open, and the failure is silent — leaving new sidecars
	# describing the old index, so every offset points at the wrong line.
	if _loaded_systemid == systemid:
		unload_index()

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

	# Announce before the first request goes out. `total` is only known once
	# page one lands, and on a large platform that is several seconds of a ~3 MB
	# body — long enough to look like nothing is happening.
	sync_started.emit(systemid, 0)
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
	var page_limit := PAGE_LIMIT

	while true:
		if _abort:
			out.close()
			http.close()
			DirAccess.remove_absolute(tmp_jsonl)
			return

		# The limit this request actually asked for. page_limit can change below
		# once `total` is known, and the short-page test must compare against what
		# was requested or the switch itself looks like the last page.
		var req_limit := page_limit
		var path := _page_path(platform_id, offset, args["group"], updated_after, first_page, req_limit)
		var resp := _fetch_page_with_retry(http, args["base_url"], path, headers)
		var result := int(resp["result"])

		# A cancelled sync is not a failure — leave without a toast.
		if result == RommHttp.Result.ABORTED or _abort:
			out.close()
			http.close()
			DirAccess.remove_absolute(tmp_jsonl)
			return

		if result != RommHttp.Result.OK:
			var code := int(resp["code"])
			if code == 401 or code == 403:
				error = "Sign-in rejected by RomM"
			elif code > 0:
				error = "Server error (HTTP %d)" % code
			elif result == RommHttp.Result.TIMED_OUT:
				# Naming this "connection lost" sent a whole debugging session
				# after the network when the server was simply still working.
				error = "The server took too long on this list"
			else:
				error = "Connection lost during sync"
			break

		var page: Dictionary = resp["data"] if resp["data"] is Dictionary else {}
		var items: Array = page.get("items", []) if page.get("items") is Array else []
		if first_page:
			total = int(page.get("total", 0))
			_started.call_deferred(systemid, total)
			first_page = false
			if total > LARGE_PLATFORM_ROWS:
				page_limit = PAGE_LIMIT_LARGE

		if items.is_empty():
			break

		for item: Dictionary in items:
			# RomM happily scans dot-directories (".media", ".media2") as ROMs:
			# 600 MB entries with no name and no cover. RomLibrary.scan_roms
			# already skips dot-prefixed files locally; do the same here.
			if str(item.get("fs_name", "")).begins_with("."):
				continue
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

		if offset >= total or items.size() < req_limit:
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
		var sort_key := ""
		var display := ""
		if parsed is Dictionary:
			sort_key = str((parsed as Dictionary).get("sort_name", ""))
			display = str((parsed as Dictionary).get("name", ""))
		var fs_base := ""
		var regions_joined := ""
		if parsed is Dictionary:
			var pd := parsed as Dictionary
			fs_base = str(pd.get("fs_name", "")).get_basename().to_lower()
			var rl: Array = pd.get("regions", []) if pd.get("regions") is Array else []
			var parts := PackedStringArray()
			for r: Variant in rl:
				parts.append(str(r))
			regions_joined = "".join(parts)
		rows.append({"sort": sort_key, "display": display, "line": line, "id": id,
			"fs_base": fs_base, "regions": regions_joined})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["sort"] as String).naturalnocasecmp_to(b["sort"] as String) < 0
	)

	# Write the index plus its three sidecars in one pass.
	var offsets := PackedInt64Array()
	var ids := PackedInt32Array()
	var names_text := ""
	var fsnames_text := ""
	var regions_text := ""
	var pos := 0
	for r: Dictionary in rows:
		var line: String = r["line"]
		offsets.append(pos)
		ids.append(int(r["id"]))
		# Search index is the lowercased DISPLAY name, not name_sort_key —
		# RomM's sort key zero-pads every number ("2in1" -> "000000000002in
		# 000000000001"), which sorts correctly but is unsearchable as text.
		names_text += str(r["display"]) + "\n"
		fsnames_text += str(r["fs_base"]) + "
"
		regions_text += str(r["regions"]) + "
"
		var bytes := (line + "\n").to_utf8_buffer()
		out.store_buffer(bytes)
		pos += bytes.size()
	out.close()

	_write_bytes(dir.path_join("index.off"), _int64_bytes(offsets))
	_write_bytes(dir.path_join("index.ids"), _int32_bytes(ids))
	_write_text(dir.path_join("index.names"), names_text)
	_write_text(dir.path_join("index.fsnames"), fsnames_text)
	_write_text(dir.path_join("index.regions"), regions_text)

	# Atomic swap — readers never see a half-written index.
	var final_path := index_path(systemid)
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	if DirAccess.rename_absolute(tmp_jsonl, final_path) != OK:
		DirAccess.remove_absolute(tmp_jsonl)
		_finish.call_deferred(systemid, false, 0, 0,
			"Could not replace the index (is it open?)")
		return

	_write_text(meta_path(systemid), JSON.stringify({
		"total": rows.size(),
		"updated_after": max_updated,
		"synced_at": Time.get_datetime_string_from_system(true),
		"group_by_meta_id": args["group"],
		"platform_id": platform_id,
	}, "\t"))

	var removed := 0  # deletions are reconciled separately via /api/roms/identifiers
	_finish.call_deferred(systemid, true, added, removed, "")


## One page, retried on a fresh connection.
##
## A large platform is ~20 requests over half an hour on one keep-alive socket,
## and the whole sync is discarded if any single one of them fails. Reconnecting
## costs a round trip and covers both halves of that: a socket that went stale
## while held open, and a query that overran its deadline once.
##
## Auth rejections and aborts are returned immediately — neither improves by
## asking again.
func _fetch_page_with_retry(http: RommHttp, base_url: String, path: String,
							headers: PackedStringArray) -> Dictionary:
	var resp := {"result": RommHttp.Result.CONNECT_FAILED, "code": 0, "data": null}

	for attempt in PAGE_RETRIES:
		if attempt > 0:
			http.close()
			if not _sleep_abortable(PAGE_RETRY_BACKOFF_MS * attempt):
				return {"result": RommHttp.Result.ABORTED, "code": 0, "data": null}
			if http.open(base_url) != RommHttp.Result.OK:
				continue

		resp = http.get_json(path, headers, func() -> bool: return _abort,
			SYNC_RESPONSE_TIMEOUT_SEC)

		var result := int(resp["result"])
		if result == RommHttp.Result.OK or result == RommHttp.Result.ABORTED:
			return resp
		# A timeout means the server is still chewing on the query, not that
		# anything broke. Asking again buys another identical wait.
		if result == RommHttp.Result.TIMED_OUT:
			return resp
		var code := int(resp["code"])
		if code == 401 or code == 403:
			return resp

	return resp


## Returns false if the sync was aborted while waiting.
func _sleep_abortable(msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + msec
	while Time.get_ticks_msec() < deadline:
		if _abort:
			return false
		OS.delay_msec(100)
	return not _abort


## Build one page request. `with_char_index` only on the first page — after that
## it's pure payload. `with_filter_values`/`with_files` are always off.
##
## `with_rom_id_index` defaults to TRUE server-side and returns every id in the
## whole result set on every page — 475 KB per page on a 59k platform, 39% of the
## body, and nothing here reads it. Turning it off took a PlayStation page from
## 26.4 s to 2.5 s. It gained an opt-out in RomM 5.1.0; older servers ignore the
## parameter and simply keep sending it.
func _page_path(platform_id: int, offset: int, group: bool,
				updated_after: String, first_page: bool, limit: int) -> String:
	var path := "/api/roms?limit=%d&offset=%d&order_by=name&order_dir=asc" % [limit, offset]
	if platform_id > 0:
		path += "&platform_ids=%d" % platform_id
	path += "&group_by_meta_id=%s" % ("true" if group else "false")
	path += "&with_char_index=%s" % ("true" if first_page else "false")
	path += "&with_rom_id_index=false&with_filter_values=false&with_files=false"
	if not updated_after.is_empty():
		path += "&updated_after=" + updated_after.uri_encode()
	return path


## Keep only the fields the browser needs. The raw provider blobs
## (igdb_metadata, ss_metadata, …) are large and unused here; summary and the
## rest are fetched on demand from /api/roms/{id} when a detail panel opens.
static func _slim_row(item: Dictionary) -> Dictionary:
	var meta: Dictionary = item.get("metadatum", {}) if item.get("metadatum") is Dictionary else {}
	var name := _s(item, "name")
	if name.is_empty():
		name = _s(item, "fs_name_no_tags")
	if name.is_empty():
		name = _s(item, "fs_name")

	var sort_name := _s(item, "name_sort_key")
	if sort_name.is_empty():
		sort_name = name

	return {
		"id": _i(item, "id"),
		"name": name,
		"sort_name": sort_name.to_lower(),
		"fs_name": _s(item, "fs_name"),
		"fs_extension": _s(item, "fs_extension"),
		"fs_size_bytes": _i(item, "fs_size_bytes"),
		"md5_hash": _s(item, "md5_hash"),
		"sha1_hash": _s(item, "sha1_hash"),
		"crc_hash": _s(item, "crc_hash"),
		"regions": _a(item, "regions"),
		"languages": _a(item, "languages"),
		"revision": _s(item, "revision"),
		"cover_small": _s(item, "path_cover_small"),
		"cover_large": _s(item, "path_cover_large"),
		"has_manual": bool(item.get("has_manual", false) == true),
		"multi": bool(item.get("has_multiple_files", false) == true),
		"updated_at": _s(item, "updated_at"),
		"first_release_date": _i(meta, "first_release_date"),
		"genres": _a(meta, "genres"),
		"companies": _a(meta, "companies"),
	}


# JSON null is not the same as a missing key: Dictionary.get()'s default only
# applies when the key is ABSENT, so a field RomM sends as null comes back as a
# real null and int(null) / str(null) blow up or produce "<null>". Most nullable
# fields here (first_release_date, revision, name on unmatched ROMs, every
# metadatum member) are null in practice on a server with metadata providers
# disabled, so all server-derived reads go through these.

static func _s(d: Dictionary, key: String) -> String:
	var v: Variant = d.get(key)
	return "" if v == null else str(v)


static func _i(d: Dictionary, key: String) -> int:
	var v: Variant = d.get(key)
	if v == null:
		return 0
	if v is int or v is float:
		return int(v)
	if v is String and (v as String).is_valid_float():
		return int((v as String).to_float())
	return 0


static func _a(d: Dictionary, key: String) -> Array:
	var v: Variant = d.get(key)
	return v if v is Array else []


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

static func _read_lines(path: String) -> PackedStringArray:
	if not FileAccess.file_exists(path):
		return PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedStringArray()
	# Keep empty entries: a row with no regions writes a blank line, and dropping
	# it would shift every later row. Only the trailing newline is discarded.
	var parts := f.get_as_text().split("
")
	if parts.size() > 0 and parts[parts.size() - 1] == "":
		parts.remove_at(parts.size() - 1)
	return PackedStringArray(parts)


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


## Write via a per-thread temp file and rename, so a concurrent writer of the
## same path can never be observed half-done.
static func _write_text_atomic(path: String, text: String) -> void:
	var tmp := "%s.%d.part" % [path, OS.get_thread_caller_id()]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[RommCatalog] cannot write %s" % tmp)
		return
	f.store_string(text)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	if DirAccess.rename_absolute(tmp, path) != OK:
		DirAccess.remove_absolute(tmp)


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
