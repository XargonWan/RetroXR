## RommArtCache — async cover art for the ROM browser.
##
## Three things make this safe to drive from a fast-scrolling virtual list:
##
##  1. Covers are fetched with HTTPRequest.download_file, so bytes go straight to
##     disk instead of arriving as a PackedByteArray on the main thread.
##  2. PNG/JPEG decode runs on WorkerThreadPool. Decoding inline is how this kind
##     of grid stutters — 20 rows scrolling into view is ~40 ms of decode, four
##     dropped frames at 90 Hz.
##  3. Only ImageTexture.create_from_image touches the main thread, budgeted per
##     frame.
##
## RomM's nginx serves /assets with no auth gate (verified), so NO Authorization
## header is sent for artwork. Cover URLs already carry a ?ts=<updated_at> buster
## that changes whenever the ROM does, so cached files are treated as immutable
## and never revalidated.
class_name RommArtCache
extends Node


## Emitted when a texture becomes available for a rom id, so visible rows can
## swap their placeholder out.
signal art_ready(rom_id: int, texture: Texture2D)

## Concurrent HTTP fetches. Small images, but the Quest is CPU-bound — a wide
## fan-out costs more in poll overhead than it gains.
const MAX_CONCURRENT := 4
## Textures held in RAM. Modelled on pdf_book.gd's _trim_texture_cache.
const MAX_TEXTURES := 200
## Textures promoted per frame, so a burst of decodes can't stall the frame.
const DECODE_BUDGET_PER_FRAME := 4

var base_url: String = ""

## rom_id -> ImageTexture (LRU; _lru_order holds the recency list)
var _textures: Dictionary = {}
var _lru_order: Array[int] = []

## rom_id -> {url, path, systemid}
var _queue: Array[Dictionary] = []
var _active: Dictionary = {}          ## rom_id -> HTTPRequest
var _decoding: Dictionary = {}        ## rom_id -> WorkerThreadPool task id
var _decoded: Array[Dictionary] = []  ## [{rom_id, image}] awaiting main-thread promotion
var _decoded_mutex := Mutex.new()
## Fetches that failed or produced nothing — never retried, the row just falls
## back to its title text.
var _dead: Dictionary = {}


func setup(url: String) -> void:
	base_url = url


func _process(_delta: float) -> void:
	_promote_decoded()
	_pump()


# ---------------------------------------------------------------------------
# Public
# ---------------------------------------------------------------------------

## Texture for a rom id if it is already in RAM, else null (and a fetch starts).
## `cover_path` is RomM's path_cover_small, used verbatim.
func get_or_request(rom_id: int, cover_path: String, systemid: String) -> Texture2D:
	if rom_id <= 0:
		return null

	if _textures.has(rom_id):
		_mark_used(rom_id)
		return _textures[rom_id]

	if _dead.has(rom_id) or _active.has(rom_id) or _decoding.has(rom_id):
		return null

	# Absent art is "" (not null) in RomM's schema despite the declared type.
	if cover_path.is_empty():
		_dead[rom_id] = true
		return null

	var disk := _disk_path(systemid, rom_id, cover_path)
	if FileAccess.file_exists(disk):
		_start_decode(rom_id, disk)
		return null

	for q: Dictionary in _queue:
		if int(q["rom_id"]) == rom_id:
			return null

	_queue.append({"rom_id": rom_id, "url": base_url + _encode_query(cover_path), "path": disk})
	return null


## Drop pending work for rows that scrolled away — otherwise a fast scroll
## queues hundreds of fetches for covers nobody is looking at any more.
func cancel_outside(keep_ids: PackedInt32Array) -> void:
	var keep: Dictionary = {}
	for id: int in keep_ids:
		keep[id] = true

	var kept: Array[Dictionary] = []
	for q: Dictionary in _queue:
		if keep.has(int(q["rom_id"])):
			kept.append(q)
	_queue = kept


func clear() -> void:
	_queue.clear()
	for id: int in _active.keys():
		var http: HTTPRequest = _active[id]
		if is_instance_valid(http):
			http.cancel_request()
			http.queue_free()
	_active.clear()
	_textures.clear()
	_lru_order.clear()
	_dead.clear()


# ---------------------------------------------------------------------------
# Fetch
# ---------------------------------------------------------------------------

func _pump() -> void:
	while _active.size() < MAX_CONCURRENT and not _queue.is_empty():
		var job: Dictionary = _queue.pop_front()
		_start_fetch(int(job["rom_id"]), str(job["url"]), str(job["path"]))


func _start_fetch(rom_id: int, url: String, disk: String) -> void:
	DirAccess.make_dir_recursive_absolute(disk.get_base_dir())

	var http := HTTPRequest.new()
	http.use_threads = true
	http.download_file = disk     # straight to disk, never through the main thread
	http.timeout = 15.0
	add_child(http)
	_active[rom_id] = http

	http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
			_active.erase(rom_id)
			http.queue_free()

			if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
				_dead[rom_id] = true
				if FileAccess.file_exists(disk):
					DirAccess.remove_absolute(disk)
				return

			_start_decode(rom_id, disk)
	)

	# No auth header: /assets is served straight off disk by nginx.
	if http.request(url) != OK:
		_active.erase(rom_id)
		http.queue_free()
		_dead[rom_id] = true


# ---------------------------------------------------------------------------
# Decode (worker thread) → promote (main thread)
# ---------------------------------------------------------------------------

func _start_decode(rom_id: int, path: String) -> void:
	if _decoding.has(rom_id):
		return
	_decoding[rom_id] = WorkerThreadPool.add_task(_decode_task.bind(rom_id, path))


## Runs on a pool thread. Image.load_from_file is the expensive part; creating
## the texture is left to the main thread.
func _decode_task(rom_id: int, path: String) -> void:
	var img := Image.load_from_file(path)
	_decoded_mutex.lock()
	_decoded.append({"rom_id": rom_id, "image": img})
	_decoded_mutex.unlock()


func _promote_decoded() -> void:
	var promoted := 0
	while promoted < DECODE_BUDGET_PER_FRAME:
		_decoded_mutex.lock()
		if _decoded.is_empty():
			_decoded_mutex.unlock()
			return
		var item: Dictionary = _decoded.pop_front()
		_decoded_mutex.unlock()

		var rom_id := int(item["rom_id"])
		if _decoding.has(rom_id):
			WorkerThreadPool.wait_for_task_completion(_decoding[rom_id])
			_decoding.erase(rom_id)

		var img: Image = item["image"]
		if img == null or img.is_empty():
			_dead[rom_id] = true
			promoted += 1
			continue

		var tex := ImageTexture.create_from_image(img)
		_textures[rom_id] = tex
		_mark_used(rom_id)
		_trim_textures()
		art_ready.emit(rom_id, tex)
		promoted += 1


func _mark_used(rom_id: int) -> void:
	_lru_order.erase(rom_id)
	_lru_order.append(rom_id)


func _trim_textures() -> void:
	while _lru_order.size() > MAX_TEXTURES:
		var oldest: int = _lru_order.pop_front()
		_textures.erase(oldest)


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

## Cached beside the other per-system media so it is easy to find and purge.
static func _disk_path(systemid: String, rom_id: int, cover_path: String) -> String:
	var ext := cover_path.get_extension()
	if ext.contains("?"):
		ext = ext.split("?")[0]
	if ext.is_empty():
		ext = "png"
	return RomLibrary.rom_dir_for_system(systemid).path_join("media/romm/%d_s.%s" % [rom_id, ext])


## The ?ts= value is a raw Python datetime with spaces and colons — encode the
## query but leave the path separators alone.
static func _encode_query(path: String) -> String:
	var q := path.find("?")
	if q < 0:
		return path
	return path.substr(0, q) + "?" + path.substr(q + 1).uri_encode()
