## RommDownloader — pulls a ROM from RomM onto local disk, then hands back a path
## the existing spawn/launch pipeline can use unchanged.
##
## Runs on its own Thread with a blocking HTTPClient: these are multi-GB, minutes
## long, and must never touch the main thread. Bytes stream to disk in chunks —
## a 4 GB ISO is never assembled in memory.
##
## Downloads land at roms/<systemid>/<fs_name> under the REAL filename, so
## SramPaths.game_stem, MediaDimensions.load_label_texture, ScenePersistence and
## netplay MD5 resolution all keep working with no changes. RommCacheManifest
## records which files came from the server so eviction knows what it may delete.
class_name RommDownloader
extends Node


signal download_started(rom_id: int, label: String, total_bytes: int)
signal download_progress(rom_id: int, received: int, total: int)
## attempt/max are 1-based, for "retry 2/3" in the UI.
signal download_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String)
## ok=false carries a user-facing reason; `path` is the launchable file on success.
signal download_finished(rom_id: int, ok: bool, path: String, error: String)
signal download_cancelled(rom_id: int)
## Eviction made room — surfaced so files never vanish silently.
signal cache_evicted(freed_bytes: int, count: int)

## Transient failures get this many attempts, with 2/4/8 s backoff — matching
## screenscraper_client.gd's retry shape. Because every request carries a Range
## header, a retry RESUMES from the .part instead of restarting a 4 GB pull.
const MAX_RETRIES := 3

var config: RommConfig = null
var manifest: RommCacheManifest = null

var _thread: Thread = null
var _abort := false
var _current_rom_id := 0
## Queue of pending {entry, systemid} — one download at a time; these are big.
var _queue: Array[Dictionary] = []
## Keys the eviction pass must not touch (in use right now).
var _protected_keys: Array[String] = []


func setup(cfg: RommConfig, mf: RommCacheManifest) -> void:
	config = cfg
	manifest = mf


func _exit_tree() -> void:
	cancel_all()


func is_busy() -> bool:
	return _thread != null and _thread.is_alive()


func current_rom_id() -> int:
	return _current_rom_id


func queued_count() -> int:
	return _queue.size()


## Protect a file from eviction (e.g. it is inserted in a powered-on system).
func protect(systemid: String, fs_name: String) -> void:
	var key := RommCacheManifest.make_key(systemid, fs_name)
	if key not in _protected_keys:
		_protected_keys.append(key)


func unprotect(systemid: String, fs_name: String) -> void:
	_protected_keys.erase(RommCacheManifest.make_key(systemid, fs_name))


# ---------------------------------------------------------------------------
# Queueing
# ---------------------------------------------------------------------------

## `entry` is a RommCatalog row: needs id, fs_name, fs_size_bytes, md5_hash,
## name, multi, cover_large.
func enqueue(entry: Dictionary, systemid: String) -> void:
	var rom_id := int(entry.get("id", 0))
	if rom_id == 0:
		return
	if rom_id == _current_rom_id:
		return
	for q: Dictionary in _queue:
		if int((q["entry"] as Dictionary).get("id", 0)) == rom_id:
			return
	_queue.append({"entry": entry, "systemid": systemid})
	_pump()


## Cancel the in-flight download (its .part is kept, so a later tap resumes).
func cancel_current() -> void:
	if is_busy():
		_abort = true


func cancel_all() -> void:
	_queue.clear()
	_abort = true
	if _thread != null:
		if _thread.is_started():
			_thread.wait_to_finish()
		_thread = null
	_abort = false
	_current_rom_id = 0


func _pump() -> void:
	if is_busy() or _queue.is_empty():
		return

	# Join a finished thread before starting the next.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

	var job: Dictionary = _queue.pop_front()
	var entry: Dictionary = job["entry"]
	var systemid: String = job["systemid"]
	var rom_id := int(entry.get("id", 0))
	var fs_name := str(entry.get("fs_name", ""))
	var size := int(entry.get("fs_size_bytes", 0))

	if fs_name.is_empty():
		download_finished.emit(rom_id, false, "", "Server entry has no filename")
		_pump()
		return

	# Make room BEFORE starting. Godot exposes no free-space API, so the budget
	# is the only guard — evicting after the fact means the overflow already
	# happened, and a 4 GB pull that fails at 90% wastes the whole transfer.
	if manifest != null and config != null and size > 0:
		var key := RommCacheManifest.make_key(systemid, fs_name)
		var prot := _protected_keys.duplicate()
		prot.append(key)
		var res := manifest.evict_to_fit(size, config.cache_budget_bytes(), prot)
		if int(res["count"]) > 0:
			cache_evicted.emit(int(res["freed"]), int(res["count"]))
		if not bool(res["enough"]):
			download_finished.emit(rom_id, false, "",
				"Not enough space for %s (%s)" % [entry.get("name", fs_name), _human_size(size)])
			_pump()
			return

	_abort = false
	_current_rom_id = rom_id
	download_started.emit(rom_id, str(entry.get("name", fs_name)), size)

	_thread = Thread.new()
	var args := {
		"entry": entry,
		"systemid": systemid,
		"base_url": config.base_url,
		"headers": config.auth_headers(),
	}
	if _thread.start(_worker.bind(args)) != OK:
		_thread = null
		_current_rom_id = 0
		download_finished.emit(rom_id, false, "", "Could not start download thread")
		_pump()


# ---------------------------------------------------------------------------
# Worker thread
# ---------------------------------------------------------------------------

func _worker(args: Dictionary) -> void:
	var entry: Dictionary = args["entry"]
	var systemid: String = args["systemid"]
	var rom_id := int(entry.get("id", 0))
	var fs_name := str(entry.get("fs_name", ""))
	var expected_md5 := str(entry.get("md5_hash", "")).to_lower()
	var is_multi := bool(entry.get("multi", false))

	RomLibrary.ensure_rom_dir(systemid)
	var dest := RommCacheManifest.local_path(systemid, fs_name)
	var part := dest + ".part"

	var attempt := 0
	var last_error := ""

	while attempt < MAX_RETRIES:
		if _abort:
			_emit_cancelled.call_deferred(rom_id)
			return

		if attempt > 0:
			# 2 s, 4 s, 8 s — same backoff shape as the scraper client.
			var delay := int(pow(2.0, float(attempt)))
			_emit_retrying.call_deferred(rom_id, attempt + 1, MAX_RETRIES, last_error)
			for i in delay * 10:
				if _abort:
					_emit_cancelled.call_deferred(rom_id)
					return
				OS.delay_msec(100)

		var outcome := _attempt_download(args, dest, part, rom_id)
		var status := str(outcome["status"])

		match status:
			"ok":
				break
			"cancelled":
				_emit_cancelled.call_deferred(rom_id)
				return
			"terminal":
				_emit_finished.call_deferred(rom_id, false, "", str(outcome["error"]))
				return
			"restart":
				# Known-bad bytes (416 / size / hash / bad zip): drop the .part so
				# the next attempt starts clean rather than resuming garbage.
				if FileAccess.file_exists(part):
					DirAccess.remove_absolute(part)
				last_error = str(outcome["error"])
				attempt += 1
			_:  # "transient" — keep the .part and resume from where we stopped
				last_error = str(outcome["error"])
				attempt += 1

		if attempt >= MAX_RETRIES:
			_emit_finished.call_deferred(rom_id, false, "", last_error)
			return

	# ── Verified and in place ────────────────────────────────────────────────
	var launch_path := dest
	if is_multi:
		var extracted := _extract_multi(dest, systemid)
		if extracted.is_empty():
			_emit_finished.call_deferred(rom_id, false, "", "Could not unpack multi-file ROM")
			return
		launch_path = extracted

	var actual_size := _file_size(dest)
	_register.call_deferred(systemid, fs_name, rom_id, actual_size, expected_md5)

	# Sidecars: cover art into media/label/ so the cart/disc picks it up with no
	# code change, and metadata into gamelist.json.
	_fetch_cover(args, entry, systemid, fs_name)
	_merge_gamelist.call_deferred(systemid, entry, fs_name)

	_emit_finished.call_deferred(rom_id, true, launch_path, "")


## One transfer attempt. Returns {status, error} where status is one of
## ok / transient / restart / terminal / cancelled.
func _attempt_download(args: Dictionary, dest: String, part: String, rom_id: int) -> Dictionary:
	var entry: Dictionary = args["entry"]
	var headers: PackedStringArray = args["headers"]
	var fs_name := str(entry.get("fs_name", ""))
	var expected_size := int(entry.get("fs_size_bytes", 0))
	var expected_md5 := str(entry.get("md5_hash", "")).to_lower()

	var http := RommHttp.new()
	if http.open(args["base_url"]) != RommHttp.Result.OK:
		return {"status": "transient", "error": "Could not reach the server"}

	# Resume when a .part is already on disk.
	var have := _file_size(part)
	var file: FileAccess
	if have > 0:
		file = FileAccess.open(part, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(part, FileAccess.WRITE)

	if file == null:
		http.close()
		return {"status": "terminal", "error": "Cannot write to %s" % part.get_base_dir()}

	var req_headers := PackedStringArray(headers)
	req_headers.append("Range: bytes=%d-" % have)

	var path := "/api/roms/%d/content/%s" % [int(entry.get("id", 0)), fs_name.uri_encode()]
	var resp := http.download_to_file(path, req_headers, file,
		func(received: int, _total: int) -> void:
			_emit_progress.call_deferred(rom_id, have + received, expected_size),
		func() -> bool: return _abort)

	file.close()
	http.close()

	var result := int(resp["result"])
	var code := int(resp["code"])

	match result:
		RommHttp.Result.ABORTED:
			return {"status": "cancelled", "error": ""}
		RommHttp.Result.WRITE_FAILED:
			return {"status": "terminal", "error": "Not enough space, or disk unwritable"}
		RommHttp.Result.CONNECT_FAILED, RommHttp.Result.REQUEST_FAILED:
			return {"status": "transient", "error": "Connection lost"}
		RommHttp.Result.HTTP_ERROR:
			# 401/403 and 404 are terminal and need distinct messages — a revoked
			# token looks identical to a network error at the transport layer.
			if code == 401 or code == 403:
				return {"status": "terminal", "error": "Sign in to RomM again"}
			if code == 404:
				if FileAccess.file_exists(part):
					DirAccess.remove_absolute(part)
				return {"status": "terminal", "error": "No longer on the server"}
			if code == 416:
				# Our .part is longer than the server's file — it changed under us.
				return {"status": "restart", "error": "File changed on the server"}
			if code >= 500:
				return {"status": "transient", "error": "Server error (%d)" % code}
			return {"status": "terminal", "error": "Server refused the download (%d)" % code}

	# Transfer completed — verify before promoting the .part.
	var got := _file_size(part)
	if expected_size > 0 and got != expected_size:
		return {"status": "restart",
				"error": "Incomplete download (%s of %s)" % [_human_size(got), _human_size(expected_size)]}

	if not expected_md5.is_empty():
		var sums := RomHasher.compute_checksums(part)
		var md5 := str(sums.get("md5", "")).to_lower()
		if not md5.is_empty() and md5 != expected_md5:
			return {"status": "restart", "error": "Downloaded file was corrupt"}

	# Atomic promote. A partial file must never be visible to RomLibrary.scan_roms
	# — it would spawn as a real cartridge and fail deep inside StartContent.
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		return {"status": "terminal", "error": "Could not finalise the download"}

	return {"status": "ok", "error": ""}


## Multi-file ROMs arrive as a zip (RomM injects a generated .m3u). Extract
## alongside, preserving subpaths, and return the file to launch.
func _extract_multi(zip_path: String, systemid: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return ""

	var dest_dir := RomLibrary.rom_dir_for_system(systemid)
	var launch := ""
	var first_playable := ""

	for name: String in reader.get_files():
		if name.ends_with("/"):
			continue
		var out_path := dest_dir.path_join(name)
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f == null:
			continue
		f.store_buffer(reader.read_file(name))
		f.close()

		var ext := name.get_extension().to_lower()
		if ext == "m3u":
			launch = out_path
		elif first_playable.is_empty() and ext in ["cue", "ccd", "mds", "iso", "chd", "gdi"]:
			first_playable = out_path

	reader.close()
	DirAccess.remove_absolute(zip_path)

	return launch if not launch.is_empty() else first_playable


## Cover art → media/label/<basename>.<ext>. MediaDimensions.load_label_texture
## then paints it on the cartridge/disc with no changes anywhere else.
## Art is served by nginx off /assets with NO auth gate, so no headers here.
func _fetch_cover(args: Dictionary, entry: Dictionary, systemid: String, fs_name: String) -> void:
	var cover := str(entry.get("cover_large", ""))
	if cover.is_empty():
		cover = str(entry.get("cover_small", ""))
	if cover.is_empty():
		return

	var http := RommHttp.new()
	if http.open(args["base_url"]) != RommHttp.Result.OK:
		return

	# The path already carries /assets/romm/resources and a ?ts= buster —
	# never rebuild it, and encode the query (ts is a raw datetime with spaces).
	var ext := cover.get_extension()
	if ext.contains("?"):
		ext = ext.split("?")[0]
	if ext.is_empty():
		ext = "png"

	var dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/label")
	DirAccess.make_dir_recursive_absolute(dir)
	var out_path := dir.path_join("%s.%s" % [fs_name.get_basename(), ext])

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		http.close()
		return

	var resp := http.download_to_file(_encode_asset_path(cover), PackedStringArray(), f,
		Callable(), func() -> bool: return _abort)
	f.close()
	http.close()

	if int(resp["result"]) != RommHttp.Result.OK or int(resp["received"]) < 256:
		if FileAccess.file_exists(out_path):
			DirAccess.remove_absolute(out_path)


## Percent-encode only the query, leaving the path separators intact.
static func _encode_asset_path(path: String) -> String:
	var q := path.find("?")
	if q < 0:
		return path
	return path.substr(0, q) + "?" + path.substr(q + 1).uri_encode()


# ---------------------------------------------------------------------------
# Main-thread marshalling
# ---------------------------------------------------------------------------

func _emit_progress(rom_id: int, received: int, total: int) -> void:
	download_progress.emit(rom_id, received, total)


func _emit_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String) -> void:
	download_retrying.emit(rom_id, attempt, max_attempts, reason)


func _emit_cancelled(rom_id: int) -> void:
	_current_rom_id = 0
	download_cancelled.emit(rom_id)
	_pump()


func _emit_finished(rom_id: int, ok: bool, path: String, error: String) -> void:
	_current_rom_id = 0
	if not ok:
		push_warning("[RommDownloader] rom %d failed: %s" % [rom_id, error])
	download_finished.emit(rom_id, ok, path, error)
	_pump()


func _register(systemid: String, fs_name: String, rom_id: int, size: int, md5: String) -> void:
	if manifest != null:
		manifest.add(systemid, fs_name, rom_id, size, md5)


## Merge RomM metadata into gamelist.json so the detail panel, wheel lookup and
## variant grouping all light up for server-sourced ROMs too. "romm:<id>" as the
## game_id keeps these from colliding with ScreenScraper entries.
func _merge_gamelist(systemid: String, entry: Dictionary, fs_name: String) -> void:
	var gl := GamelistManager.new()
	var companies: Array = entry.get("companies", []) if entry.get("companies") is Array else []
	var genres: Array = entry.get("genres", []) if entry.get("genres") is Array else []
	var regions: Array = entry.get("regions", []) if entry.get("regions") is Array else []

	var release := ""
	var epoch := int(entry.get("first_release_date", 0))
	if epoch > 0:
		release = Time.get_date_string_from_unix_time(epoch)

	gl.add_or_merge_rom(systemid, {
		"game_id": "romm:%d" % int(entry.get("id", 0)),
		"name": str(entry.get("name", fs_name.get_basename())),
		"desc": "",
		"developer": str(companies[0]) if not companies.is_empty() else "",
		"publisher": "",
		"genre": ", ".join(PackedStringArray(genres.map(func(g: Variant) -> String: return str(g)))),
	}, {
		"path": "./" + fs_name,
		"romname": fs_name,
		"releasedate": release,
		"region": str(regions[0]) if not regions.is_empty() else "",
	})
	gl.save_gamelist(systemid)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	return f.get_length()


static func _human_size(bytes: int) -> String:
	if bytes >= 1073741824:
		return "%.1f GB" % (float(bytes) / 1073741824.0)
	if bytes >= 1048576:
		return "%.0f MB" % (float(bytes) / 1048576.0)
	if bytes >= 1024:
		return "%.0f KB" % (float(bytes) / 1024.0)
	return "%d B" % bytes
