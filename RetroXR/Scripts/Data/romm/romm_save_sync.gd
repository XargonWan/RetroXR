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
var _current_key := ""
## Separate from the sync queue: opening the cartridge menu must not wait
## behind a save being uploaded.
var _list_thread: Thread = null
var _list_busy := false
## Local save path -> unix seconds of the last upload, for MIN_UPLOAD_GAP_SEC.
var _last_upload: Dictionary = {}
## rom_path -> RomM rom_id (0 = not on the server). Resolved once per path;
## the flush path must not re-read gamelist.json every save.
var _rom_ids: Dictionary = {}
## "<systemid>/<serial>" -> rom_id, 0 meaning "looked and it is not here". Holds
## the misses too, so a game that is not in the library costs one sweep, not one
## per press.
var _serial_ids: Dictionary = {}


## Autoloaded as `SaveSync`: both the console (which sees sram_flushed) and the
## cartridge menu (which offers the toggle) need this, and they are unrelated
## nodes with no shared parent to hang it off.
func _ready() -> void:
	config = RommConfig.new()
	config.load_config()
	load_state()


## Re-read the config after the OPTIONS panel changes it.
func setup(cfg: RommConfig) -> void:
	config = cfg
	load_state()


func is_available() -> bool:
	return config != null and config.is_configured()


# ── ROM identity ──────────────────────────────────────────────────────────────

## RomM's id for a local ROM, or 0.
##
## ROMs pulled from RomM carry it in gamelist.json as "romm:<id>", written by
## RommDownloader. A ROM that arrived some other way has none, and resolving it
## would mean hashing the file against /api/roms/by-hash — deliberately not done
## here, because this is called from the flush path and hashing a 4 GB ISO
## there would stall the emulation thread's listener. The cartridge menu can
## offer that lookup explicitly instead.
func rom_id_for(systemid: String, rom_path: String) -> int:
	if systemid.is_empty() or rom_path.is_empty():
		return 0
	var cached := int(_rom_ids.get(rom_path, -1))
	if cached >= 0:
		return cached

	var resolved := 0
	var gl := GamelistManager.new()
	var game: Dictionary = gl.get_game_for_rom(systemid, rom_path)
	var gid := str(game.get("game_id", ""))
	if gid.begins_with("romm:"):
		resolved = int(gid.substr(5))
	_rom_ids[rom_path] = resolved
	return resolved


func _exit_tree() -> void:
	_queue.clear()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	if _list_thread != null and _list_thread.is_started():
		_list_thread.wait_to_finish()
		_list_thread = null


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


## The state key for one save INSIDE a memory card.
##
## A card is one file holding many games' saves, and each backs up as its own
## server slot, so the opt-in has to name the save rather than the card it
## happens to be sitting on.
static func card_save_key(card_path: String, slot: String) -> String:
	return "%s#%s" % [key_for(card_path), slot]


func is_key_enabled(key: String) -> bool:
	return bool((_state.get(key, {}) as Dictionary).get("enabled", false))


## Remember which game wrote a card save, whether or not it is opted in.
##
## A save names its game only by product code, and nothing maps that to a RomM
## id — the serial is not in gamelist.json and RomM does not index it either
## (searching one returns nothing). The only moment the owner is known for
## certain is while that game is running, so it is recorded then. Without this,
## opting a save in later could not upload it until the game happened to run
## again, which is a strange thing to ask of a button that says "back this up".
func note_card_save_owner(key: String, rom_id: int) -> void:
	if key.is_empty() or rom_id <= 0:
		return
	var rec: Dictionary = _state.get(key, {})
	if int(rec.get("rom_id", 0)) == rom_id:
		return
	rec["rom_id"] = rom_id
	_state[key] = rec
	save_state()


## The game a card save belongs to, as last observed, or 0 if never seen.
func card_save_owner(key: String) -> int:
	return int((_state.get(key, {}) as Dictionary).get("rom_id", 0))


## The RomM id of the game whose product code is `serial`, or 0.
##
## Found by asking the discs themselves — each one carries its serial in its boot
## line — which is the only mapping available: gamelist.json records no serial,
## and RomM does not index one either. So a save can be attributed to its game
## even on a device that has never watched that game write it, which is what a
## save restored from the server, or a card copied in from elsewhere, looks like.
##
## Stops at the first match, reads each disc once, and remembers a miss.
##
## Cost is a ~2 MB read per disc — sub-millisecond warm, a few ms cold. A HIT
## usually stops after a handful; a MISS is the expensive case because it has
## looked at everything, so it is remembered: pressing the button again on a game
## that is not in the library must not sweep the whole shelf a second time.
func rom_id_for_serial(systemid: String, serial: String) -> int:
	if systemid.is_empty() or serial.is_empty():
		return 0
	var memo := "%s/%s" % [systemid, serial]
	if _serial_ids.has(memo):
		return int(_serial_ids[memo])
	var dir := RomLibrary.default_roms_root().path_join(systemid)
	if not DirAccess.dir_exists_absolute(dir):
		return 0

	# A .cue and the .bin it names are the same disc. Scanning both reads every
	# image twice, so the raw files a cue already speaks for are skipped.
	var files := DirAccess.get_files_at(dir)
	var order: Array[String] = []
	var covered: Dictionary = {}
	for fname: String in files:
		if fname.get_extension().to_lower() == "cue":
			order.append(fname)
			covered[PS1Disc.data_track(dir.path_join(fname)).get_file()] = true
	for fname: String in files:
		var ext := fname.get_extension().to_lower()
		if ext in ["bin", "img", "iso"] and not covered.has(fname):
			order.append(fname)

	var found := 0
	for fname: String in order:
		var path := dir.path_join(fname)
		if PS1Disc.serial_of(path) != serial:
			continue
		found = rom_id_for(systemid, path)
		if found > 0:
			break
	_serial_ids[memo] = found
	return found


func set_key_enabled(key: String, on: bool) -> void:
	if key.is_empty():
		return
	var rec: Dictionary = _state.get(key, {})
	rec["enabled"] = on
	_state[key] = rec
	save_state()


## Does the server hold this save, as of the last sync?
##
## Not the same question as is_key_enabled: opting in is a wish, and a save whose
## game is not in the library stays opted in and never uploads. The server's own
## id for it is only recorded once a push, a pull or a matching hash has proved
## the bytes are there — which is what a row may safely call "backed up".
func key_backed_up(key: String) -> bool:
	return int((_state.get(key, {}) as Dictionary).get("server_save_id", 0)) > 0


## How many saves from one memory card the server is known to hold.
##
## Read from what the last sync recorded, not by asking RomM — this is for a menu
## row, and a list that stalls on the network to say where something lives is
## worse than one that answers from what it already knows. A card's saves are
## keyed "<card>#<slot>", so they share a prefix.
func card_backup_count(card_path: String) -> int:
	if card_path.is_empty():
		return 0
	var prefix := key_for(card_path) + "#"
	var n := 0
	for k: String in _state:
		if k.begins_with(prefix) and key_backed_up(k):
			n += 1
	return n


## The save currently being reconciled, or "" — lets a row show "syncing".
func current_key() -> String:
	return _current_key


# ── Listing ───────────────────────────────────────────────────────────────────

## What the server holds for one ROM, delivered to `callback(ok, saves)` on the
## main thread. Its own short-lived thread rather than the sync queue: opening
## the cartridge menu must not wait behind a save being uploaded.
func list_server_saves(rom_id: int, callback: Callable) -> void:
	if config == null or not config.is_configured() or rom_id <= 0:
		callback.call(false, [])
		return
	if _list_thread != null and _list_thread.is_started():
		if _list_busy:
			return
		_list_thread.wait_to_finish()
	_list_busy = true
	_list_thread = Thread.new()
	_list_thread.start(_list_worker.bind(rom_id, callback,
		config.base_url, config.auth_headers()))


## RomM's numeric platform id for one of our systemids, or 0. Read from the
## platform list the config already caches, so this costs no request.
func platform_id_for(systemid: String) -> int:
	if config == null:
		return 0
	var p: Variant = config.cached_platforms.get(systemid)
	return int((p as Dictionary).get("id", 0)) if p is Dictionary else 0


## Every memory-card save the server holds FOR ONE PLATFORM, with the game each
## belongs to, delivered to `callback(ok, saves)` on the main thread. Entries add
## "rom_name" to the usual save fields.
##
## Narrowed on the server by platform, not just by the .mcs extension: an
## extension is a naming convention, and a save uploaded against another console
## could carry it. The restore path writes into a card, so what it offers has to
## be the platform's own saves.
func list_card_saves(systemid: String, callback: Callable) -> void:
	if config == null or not config.is_configured():
		callback.call(false, [])
		return
	var platform_id := platform_id_for(systemid)
	if platform_id <= 0:
		# Without a platform to narrow by, offering everything would be worse
		# than offering nothing.
		callback.call(false, [])
		return
	if _list_thread != null and _list_thread.is_started():
		if _list_busy:
			return
		_list_thread.wait_to_finish()
	_list_busy = true
	_list_thread = Thread.new()
	_list_thread.start(_card_list_worker.bind(platform_id, callback,
		config.base_url, config.auth_headers()))


func _card_list_worker(platform_id: int, callback: Callable, base_url: String,
					   headers: PackedStringArray) -> void:
	var http := RommHttp.new()
	if http.open(base_url) != RommHttp.Result.OK:
		_list_done.call_deferred(callback, false, [])
		return
	var out := RommSaves.list_all(http, headers, platform_id)
	var rows: Array[Dictionary] = []
	if bool(out["ok"]):
		# One name lookup per distinct ROM, not per save: a card's worth of
		# saves for one game would otherwise be a dozen round trips.
		var names: Dictionary = {}
		for s: Dictionary in out["saves"]:
			if str(s["file_name"]).get_extension().to_lower() != "mcs":
				continue
			var rid := int(s["rom_id"])
			if not names.has(rid):
				names[rid] = RommSaves.rom_name(http, headers, rid)
			var row := s.duplicate()
			row["rom_name"] = str(names[rid])
			rows.append(row)
	http.close()
	_list_done.call_deferred(callback, bool(out["ok"]), rows)


## Fetch one save's bytes -> `callback(ok, bytes)` on the main thread.
func fetch_card_save(save_id: int, callback: Callable) -> void:
	if config == null or not config.is_configured() or save_id <= 0:
		callback.call(false, PackedByteArray())
		return
	if _list_thread != null and _list_thread.is_started():
		if _list_busy:
			return
		_list_thread.wait_to_finish()
	_list_busy = true
	_list_thread = Thread.new()
	_list_thread.start(_fetch_worker.bind(save_id, callback,
		config.base_url, config.auth_headers()))


func _fetch_worker(save_id: int, callback: Callable, base_url: String,
				   headers: PackedStringArray) -> void:
	var http := RommHttp.new()
	if http.open(base_url) != RommHttp.Result.OK:
		_fetch_done.call_deferred(callback, false, PackedByteArray())
		return
	var got := RommSaves.download(http, headers, save_id)
	http.close()
	_fetch_done.call_deferred(callback, bool(got["ok"]), got["bytes"])


func _fetch_done(callback: Callable, ok: bool, bytes: PackedByteArray) -> void:
	_list_busy = false
	if callback.is_valid():
		callback.call(ok, bytes)


func _list_worker(rom_id: int, callback: Callable, base_url: String,
				  headers: PackedStringArray) -> void:
	var http := RommHttp.new()
	if http.open(base_url) != RommHttp.Result.OK:
		_list_done.call_deferred(callback, false, [])
		return
	var out := RommSaves.list(http, headers, rom_id)
	http.close()
	_list_done.call_deferred(callback, bool(out["ok"]), out["saves"])


func _list_done(callback: Callable, ok: bool, saves: Array) -> void:
	_list_busy = false
	if callback.is_valid():
		callback.call(ok, saves)


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
	_current_key = str(job["key"])
	sync_started.emit(str(job["key"]), str(job["label"]))
	_thread = Thread.new()
	_thread.start(_worker.bind(job))


## Back up ONE save lifted out of a memory card, as its own server slot.
##
## A card is a single image many games write into, so it cannot sync as a file
## the way a cartridge save does — one record per file holds one rom_id, and the
## games would fight over it. Its individual saves can, because each belongs to
## exactly one game, and RetroXR knows which game wrote it: the caller attributes
## it at flush time rather than parsing the save's serial and looking it up.
##
## `bytes` is the save's .mcs. Deliberately upload-only — see _worker_push_only.
func push_card_save(key: String, rom_id: int, core_name: String, slot: String,
					label: String, bytes: PackedByteArray) -> void:
	if config == null or not config.is_configured() or rom_id <= 0 or bytes.is_empty():
		return
	for j: Dictionary in _queue:
		if str(j["key"]) == key:
			return
	_queue.append({
		"key": key, "path": "", "bytes": bytes, "ext": "mcs",
		"rom_id": rom_id, "core": core_name, "slot": slot, "label": label,
		"base_url": config.base_url, "headers": config.auth_headers(),
		"record": (_state.get(key, {}) as Dictionary).duplicate(),
	})
	_pump()


func _worker(job: Dictionary) -> void:
	if job.has("bytes"):
		_worker_push_only(job)
		return
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
			var res := _push(http, headers, job, FileAccess.get_file_as_bytes(path), mine)
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
				{"last_hash": md5_of(got["bytes"]), "server_save_id": int(mine["id"])})

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
			var pushed := _push(http, headers, job, FileAccess.get_file_as_bytes(path), mine)
			http.close()
			_forked.call_deferred(job, fork_id)
			_done.call_deferred(job, "conflict", bool(pushed["ok"]), str(pushed["error"]),
				pushed.get("record", {}))


## Reconcile a memory-card save one way only: up.
##
## It still asks the server what it holds, so an unchanged save is not uploaded
## again — but it never downloads. Restoring a save INTO a card means splicing it
## back into the block chain, and a wrong link or checksum there corrupts every
## other save on that card. Until that is built and proven, the server is a
## backup and never a source.
func _worker_push_only(job: Dictionary) -> void:
	var bytes: PackedByteArray = job["bytes"]
	var headers := PackedStringArray(job["headers"])
	var rec: Dictionary = job["record"]
	var local_hash := md5_of(bytes)

	var http := RommHttp.new()
	if http.open(str(job["base_url"])) != RommHttp.Result.OK:
		_done.call_deferred(job, "none", false, "Cannot reach RomM", {})
		return
	var listed := RommSaves.list(http, headers, int(job["rom_id"]))
	if not bool(listed["ok"]):
		http.close()
		_done.call_deferred(job, "none", false, str(listed["error"]), {})
		return

	var mine: Dictionary = {}
	for s: Dictionary in listed["saves"]:
		if str(s["slot"]) == str(job["slot"]):
			mine = s
			break

	# Skip only when the server demonstrably holds these exact bytes. Trusting
	# our own last_hash alone would let a save deleted server-side stay missing.
	if local_hash == str(rec.get("last_hash", "")) \
			and local_hash == str(mine.get("content_hash", "")):
		http.close()
		_done.call_deferred(job, "nothing", true, "",
			{"last_hash": local_hash, "server_save_id": int(mine.get("id", 0))})
		return

	var res := _push(http, headers, job, bytes, mine)
	http.close()
	_done.call_deferred(job, "push", bool(res["ok"]), str(res["error"]),
		res.get("record", {}))


func _push(http: RommHttp, headers: PackedStringArray, job: Dictionary,
		   bytes: PackedByteArray, mine: Dictionary) -> Dictionary:
	if bytes.is_empty():
		return {"ok": false, "error": "Nothing to upload"}

	var filename := "%s.%s" % [str(job["slot"]), str(job.get("ext", "srm"))]
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
		"record": {"last_hash": md5_of(bytes), "server_save_id": sid}}


static func md5_of(bytes: PackedByteArray) -> String:
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
	_current_key = ""
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
