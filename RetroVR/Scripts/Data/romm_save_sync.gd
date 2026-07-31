## RommSaveSync — keeps a battery save in step with RomM.
##
## Sync is per-save and off by default: a cartridge can hold both synced and
## local-only saves, and nothing touches the network unless it was asked to.
##
## Direction is decided by content, never by timestamps. Device clocks disagree
## and RomM's `updated_at` is server-side, so "newest wins" can silently eat a
## real save. Instead the local md5, the hash recorded at the last successful
## sync, and the server's `content_hash` are compared three ways:
##
##   local == last, server != last  ->  PULL     server moved on
##   local != last, server == last  ->  PUSH     we moved on
##   local != last, server != last  ->  CONFLICT both moved
##   local == last, server == last  ->  NOTHING
##
## A conflict never overwrites. The server copy is forked to a new local
## save_id and shows up as its own row in the cartridge menu, matching the rule
## the rest of the save system already follows: .srm files are never deleted.
class_name RommSaveSync
extends Node


signal sync_started(key: String, label: String)
signal sync_finished(key: String, action: String, ok: bool, detail: String)
## A conflict was forked. `forked_save_id` is the new local save holding the
## server's copy; the cartridge keeps the one it was already bound to.
signal conflict_forked(key: String, forked_save_id: String, label: String)

enum Action { NOTHING, PUSH, PULL, CONFLICT }

## Floor on how often one save may be uploaded, as a guard against a core that
## rewrites SAVE_RAM constantly. It is NOT the main rate limit — the C++ dirty
## check already is, and it fires on emulated frames, so on a slow device
## flushes arrive further apart than this anyway. A final flush ignores it.
const MIN_UPLOAD_GAP_SEC := 20.0

var config: RommConfig = null

## Local save path -> record. See romm_sync.json.
var _state: Dictionary = {}
var _thread: Thread = null
var _queue: Array[Dictionary] = []
var _busy := false
## Local save path -> unix seconds of the last upload, for MIN_UPLOAD_GAP_SEC.
var _last_upload: Dictionary = {}


func setup(cfg: RommConfig) -> void:
	config = cfg
	load_state()


func _exit_tree() -> void:
	_queue.clear()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null


# ── Per-save opt-in ───────────────────────────────────────────────────────────

static func key_for(sram_path: String) -> String:
	## Relative to the save root, so the key survives the app moving.
	var root := CoreDownloadManager.default_core_root().path_join("save")
	return sram_path.trim_prefix(root).trim_prefix("/")


func is_enabled(sram_path: String) -> bool:
	return bool(_record(sram_path).get("enabled", false))


func set_enabled(sram_path: String, on: bool, rom_id: int = 0) -> void:
	var k := key_for(sram_path)
	var rec: Dictionary = _state.get(k, {})
	rec["enabled"] = on
	if rom_id > 0:
		rec["rom_id"] = rom_id
	_state[k] = rec
	save_state()


func record_for(sram_path: String) -> Dictionary:
	return _record(sram_path)


func _record(sram_path: String) -> Dictionary:
	return _state.get(key_for(sram_path), {})


# ── The decision ──────────────────────────────────────────────────────────────

## Pure, so it can be probed without a server.
## `last_hash` empty means this save has never synced: with a server copy
## present that is a conflict, not a pull — adopting the server's bytes would
## discard local progress nobody has ever seen.
static func decide(local_hash: String, last_hash: String, server_hash: String) -> Action:
	var have_local := not local_hash.is_empty()
	var have_server := not server_hash.is_empty()

	if not have_server:
		return Action.PUSH if have_local else Action.NOTHING
	if not have_local:
		return Action.PULL

	if last_hash.is_empty():
		return Action.NOTHING if local_hash == server_hash else Action.CONFLICT

	var local_moved := local_hash != last_hash
	var server_moved := server_hash != last_hash
	if local_moved and server_moved:
		return Action.NOTHING if local_hash == server_hash else Action.CONFLICT
	if server_moved:
		return Action.PULL
	if local_moved:
		return Action.PUSH
	return Action.NOTHING


# ── Queue ─────────────────────────────────────────────────────────────────────

## Called from the sram_flushed signal. `final` bypasses the upload floor.
func on_sram_flushed(sram_path: String, rom_id: int, core_name: String,
					 slot: String, label: String, final: bool) -> void:
	if not is_enabled(sram_path) or rom_id <= 0:
		return
	if not final:
		var last := float(_last_upload.get(key_for(sram_path), 0.0))
		if Time.get_unix_time_from_system() - last < MIN_UPLOAD_GAP_SEC:
			return
	enqueue(sram_path, rom_id, core_name, slot, label)


## Reconcile one save with the server.
func enqueue(sram_path: String, rom_id: int, core_name: String,
			 slot: String, label: String) -> void:
	if config == null or not config.is_configured() or rom_id <= 0:
		return
	var k := key_for(sram_path)
	for j: Dictionary in _queue:
		if str(j["key"]) == k:
			return
	_queue.append({
		"key": k, "path": sram_path, "rom_id": rom_id, "core": core_name,
		"slot": slot, "label": label,
		"base_url": config.base_url, "headers": config.auth_headers(),
		"record": _record(sram_path).duplicate(),
	})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	var job: Dictionary = _queue.pop_front()
	_busy = true
	sync_started.emit(str(job["key"]), str(job["label"]))
	_thread = Thread.new()
	_thread.start(_worker.bind(job))


func _worker(job: Dictionary) -> void:
	var path := str(job["path"])
	var headers := PackedStringArray(job["headers"])
	var rec: Dictionary = job["record"]

	var local_hash := ""
	if FileAccess.file_exists(path):
		local_hash = FileAccess.get_md5(path).to_lower()
	var last_hash := str(rec.get("last_hash", ""))

	var http := RommHttp.new()
	if http.open(str(job["base_url"])) != RommHttp.Result.OK:
		_done.call_deferred(job, "none", false, "Cannot reach RomM", {})
		return

	var listed := RommSaves.list(http, headers, int(job["rom_id"]))
	if not bool(listed["ok"]):
		http.close()
		_done.call_deferred(job, "none", false, str(listed["error"]), {})
		return

	# Ours is the slot matching this save's identity; other slots belong to
	# other cartridges of the same game and are not this job's business.
	var mine: Dictionary = {}
	for s: Dictionary in listed["saves"]:
		if str(s["slot"]) == str(job["slot"]):
			mine = s
			break

	var server_hash := str(mine.get("content_hash", ""))
	var action := decide(local_hash, last_hash, server_hash)

	match action:
		Action.NOTHING:
			http.close()
			# Record the agreed hash even when nothing moved: the first look at
			# an already-matching pair is what establishes the baseline.
			_done.call_deferred(job, "nothing", true, "",
				{"last_hash": local_hash, "server_save_id": int(mine.get("id", 0))})

		Action.PUSH:
			var res := _push(http, headers, job, path, mine)
			http.close()
			_done.call_deferred(job, "push", bool(res["ok"]), str(res["error"]),
				res.get("record", {}))

		Action.PULL:
			var got := RommSaves.download(http, headers, int(mine["id"]))
			http.close()
			if not bool(got["ok"]):
				_done.call_deferred(job, "pull", false, str(got["error"]), {})
				return
			if not _write_bytes(path, got["bytes"]):
				_done.call_deferred(job, "pull", false, "Cannot write the save file", {})
				return
			_done.call_deferred(job, "pull", true, "",
				{"last_hash": _md5_of(got["bytes"]), "server_save_id": int(mine["id"])})

		Action.CONFLICT:
			var theirs := RommSaves.download(http, headers, int(mine["id"]))
			if not bool(theirs["ok"]):
				http.close()
				_done.call_deferred(job, "conflict", false, str(theirs["error"]), {})
				return
			# Fork theirs alongside, then push ours so the server holds the copy
			# this device is actually playing.
			var fork_id := "%08x%08x" % [randi(), randi()]
			var fork_path := path.get_base_dir().path_join(fork_id + ".srm")
			if not _write_bytes(fork_path, theirs["bytes"]):
				http.close()
				_done.call_deferred(job, "conflict", false, "Cannot write the forked save", {})
				return
			var pushed := _push(http, headers, job, path, mine)
			http.close()
			_forked.call_deferred(job, fork_id)
			_done.call_deferred(job, "conflict", bool(pushed["ok"]), str(pushed["error"]),
				pushed.get("record", {}))


func _push(http: RommHttp, headers: PackedStringArray, job: Dictionary,
		   path: String, mine: Dictionary) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return {"ok": false, "error": "Nothing to upload"}

	var filename := "%s.srm" % str(job["slot"])
	var out: Dictionary
	if int(mine.get("id", 0)) > 0:
		out = RommSaves.update(http, headers, int(mine["id"]), filename, bytes)
	else:
		out = RommSaves.create(http, headers, int(job["rom_id"]),
			str(job["core"]), str(job["slot"]), filename, bytes)
	if not bool(out["ok"]):
		return {"ok": false, "error": str(out["error"])}

	var server: Dictionary = out["save"]
	var sid := int(server.get("id", mine.get("id", 0)))
	# Record OUR hash, not the server's echo: only a 2xx means the bytes landed,
	# and the echoed record may not carry content_hash on every RomM build.
	return {"ok": true, "error": "",
		"record": {"last_hash": _md5_of(bytes), "server_save_id": sid}}


static func _md5_of(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode().to_lower()


static func _write_bytes(path: String, bytes: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	# Through a .part then rename: a torn write here is a destroyed save.
	var tmp := path + ".part"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path) == OK


# ── Main thread ───────────────────────────────────────────────────────────────

func _forked(job: Dictionary, fork_id: String) -> void:
	conflict_forked.emit(str(job["key"]), fork_id, str(job["label"]))


func _done(job: Dictionary, action: String, ok: bool, detail: String,
		   record: Dictionary) -> void:
	_busy = false
	if ok and not record.is_empty():
		var k := str(job["key"])
		var rec: Dictionary = _state.get(k, {})
		rec["enabled"] = true
		rec["rom_id"] = int(job["rom_id"])
		rec["slot"] = str(job["slot"])
		for f: String in record:
			rec[f] = record[f]
		rec["last_sync_at"] = Time.get_unix_time_from_system()
		_state[k] = rec
		save_state()
		if action == "push" or action == "conflict":
			_last_upload[k] = Time.get_unix_time_from_system()
	sync_finished.emit(str(job["key"]), action, ok, detail)
	_pump()


# ── Persistence ───────────────────────────────────────────────────────────────

static func state_path() -> String:
	return CoreDownloadManager.default_core_root().path_join("save").path_join("romm_sync.json")


func load_state() -> void:
	_state.clear()
	var f := FileAccess.open(state_path(), FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).get("saves") is Dictionary:
		_state = (parsed as Dictionary)["saves"]


func save_state() -> void:
	DirAccess.make_dir_recursive_absolute(state_path().get_base_dir())
	var f := FileAccess.open(state_path(), FileAccess.WRITE)
	if f == null:
		push_warning("[RommSaveSync] Cannot write %s" % state_path())
		return
	f.store_string(JSON.stringify({"version": 1, "saves": _state}, "\t"))
	f.close()
