## CoreDownloadManager — HTTP fetch, zip extraction, and download orchestration.
##
## Must be added to the scene tree (it creates HTTPRequest child nodes).
## Usage:
##   var mgr := CoreDownloadManager.new()
##   add_child(mgr)
##   mgr.fetch_available_cores(func(cores): ...)
##   mgr.download_core("fceumm", func(p): ..., func(ok, err): ...)
class_name CoreDownloadManager
extends Node


static func _buildbot_url() -> String:
	if OS.get_name() == "Android":
		return "https://buildbot.libretro.com/nightly/android/latest/arm64-v8a/"
	return "https://buildbot.libretro.com/nightly/windows/x86_64/latest/"

static func _core_lib_suffix() -> String:
	if OS.get_name() == "Android":
		return "_libretro_android"
	return "_libretro"

static func _core_lib_ext() -> String:
	if OS.get_name() == "Android":
		return ".so"
	return ".dll"

## Default root directory for libretro data.
## On Android: same parent dir as ROMs (/sdcard/Android/data/com.xenu.retrovr/files/libretro). On Windows: %USERPROFILE%/retrovr/libretro.
static func default_core_root() -> String:
	if OS.get_name() == "Android":
		return OS.get_user_data_dir() + "/libretro"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retrovr/libretro"


## Absolute path to the cores subdirectory (where DLLs live).
static func default_cores_dir() -> String:
	return default_core_root().path_join("cores")


## The manifest lives in the root (not cores/) so it isn't confused for a DLL.
static func default_manifest_dir() -> String:
	return default_core_root()


# ---------------------------------------------------------------------------
# Public state
# ---------------------------------------------------------------------------

## Populated after fetch_available_cores() completes.
## Array of { core_name, filename, remote_date } dicts, sorted by core_name.
var available_cores: Array[Dictionary] = []

var manifest: DownloadManifest = null

## core_name -> { "http": HTTPRequest, "progress_cb": Callable, "done_cb": Callable,
##                "zip_path": String, "remote_date": String }
var _active_downloads: Dictionary = {}

## Single HTTPRequest used for the directory listing fetch.
var _listing_request: HTTPRequest = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	ensure_directories()
	manifest = DownloadManifest.new()
	manifest.setup(default_manifest_dir())


func ensure_directories() -> void:
	var err := DirAccess.make_dir_recursive_absolute(default_cores_dir())
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("CoreDownloadManager: failed to create cores dir '%s' (err %d)" % [default_cores_dir(), err])


# ---------------------------------------------------------------------------
# Fetch available cores from buildbot
# ---------------------------------------------------------------------------

## Fetches the buildbot HTML index and calls callback(cores: Array[Dictionary])
## where each dict has: core_name, filename, remote_date.
## On failure calls callback([]).
func fetch_available_cores(callback: Callable) -> void:
	if _listing_request != null:
		_listing_request.queue_free()

	_listing_request = HTTPRequest.new()
	_listing_request.use_threads = true
	add_child(_listing_request)
	_listing_request.request_completed.connect(
		func(result, response_code, _headers, body):
			_on_listing_completed(result, response_code, body, callback)
	)
	var err := _listing_request.request(_buildbot_url())
	if err != OK:
		push_error("CoreDownloadManager: failed to start listing request (err %d)" % err)
		callback.call([])


func _on_listing_completed(result: int, response_code: int,
							body: PackedByteArray, callback: Callable) -> void:
	if _listing_request:
		_listing_request.queue_free()
		_listing_request = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("CoreDownloadManager: listing fetch failed result=%d code=%d" % [result, response_code])
		callback.call([])
		return

	var html := body.get_string_from_utf8()
	available_cores = _parse_listing_html(html)
	print("[CoreDownloadManager] Found %d downloadable cores on buildbot" % available_cores.size())
	callback.call(available_cores)


## Parse the h5ai fallback table embedded in the raw HTML.
## The page always includes a <div id="fallback"> table for non-JS browsers with:
##   <a href="/nightly/.../fceumm_libretro.dll.zip">fceumm_libretro.dll.zip</a>
##   <td class="fb-d">2026-03-06 03:10</td>
func _parse_listing_html(html: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []

	# Match relative hrefs that end in the platform-appropriate zip pattern
	var zip_ext := _core_lib_ext() + "\\.zip"
	var lib_suffix := _core_lib_suffix()
	var href_regex := RegEx.new()
	href_regex.compile('href="[^"]*?/([^"/_][^"]*?' + lib_suffix.replace("_", "\\_") + zip_ext + ')"')

	# Date in the adjacent fb-d cell: "2026-03-06 03:10"
	var date_regex := RegEx.new()
	date_regex.compile('<td class="fb-d">(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2})</td>')

	var href_matches := href_regex.search_all(html)
	var date_matches := date_regex.search_all(html)

	# Build a list of (position, date_string) so we can match each file to its nearest date
	var dates: Array = []
	for dm: RegExMatch in date_matches:
		dates.append({"pos": dm.get_start(), "date": dm.get_string(1)})

	for m: RegExMatch in href_matches:
		var filename: String = m.get_string(1).get_file()  # strip any leading path

		var core_name: String = filename
		var zip_suffix := _core_lib_ext() + ".zip"
		if core_name.ends_with(zip_suffix):
			core_name = core_name.left(core_name.length() - zip_suffix.length())
		if core_name.ends_with(_core_lib_suffix()):
			core_name = core_name.left(core_name.length() - _core_lib_suffix().length())

		# Find closest date entry that comes after this href in the HTML
		var href_pos := m.get_start()
		var remote_date := ""
		for d in dates:
			if d["pos"] > href_pos:
				remote_date = d["date"]
				break

		results.append({
			"core_name":   core_name,
			"filename":    filename,
			"remote_date": remote_date
		})

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["core_name"] < b["core_name"]
	)
	return results


# ---------------------------------------------------------------------------
# Download state
# ---------------------------------------------------------------------------

## Returns one of: "Download", "Re-Download", "UPDATE", "BUSY"
func get_core_state(core_name: String, remote_date: String) -> String:
	if _active_downloads.has(core_name):
		return "BUSY"
	if not manifest.is_downloaded(core_name):
		return "Download"
	# If we have a remote date and it differs from what we stored, offer UPDATE
	var stored_date := manifest.get_remote_date(core_name)
	if remote_date != "" and stored_date != "" and remote_date != stored_date:
		return "UPDATE"
	return "Re-Download"


# ---------------------------------------------------------------------------
# Download a core
# ---------------------------------------------------------------------------

## Download core_name, extract the DLL, update the manifest.
##
## progress_callback(fraction: float)  — called periodically with 0.0..1.0
## done_callback(success: bool, error_msg: String) — called on completion
func download_core(core_name: String, remote_date: String,
				   progress_callback: Callable, done_callback: Callable) -> void:
	if _active_downloads.has(core_name):
		push_warning("CoreDownloadManager: already downloading '%s'" % core_name)
		return

	var zip_filename := core_name + _core_lib_suffix() + _core_lib_ext() + ".zip"
	var zip_url := _buildbot_url() + zip_filename
	var zip_path := default_cores_dir().path_join(zip_filename)

	var http := HTTPRequest.new()
	http.use_threads = true
	http.download_file = zip_path          # stream directly to disk
	http.download_chunk_size = 65536
	add_child(http)

	_active_downloads[core_name] = {
		"http":        http,
		"progress_cb": progress_callback,
		"done_cb":     done_callback,
		"zip_path":    zip_path,
		"remote_date": remote_date
	}

	http.request_completed.connect(
		func(result, response_code, _headers, _body):
			_on_download_completed(core_name, result, response_code)
	)

	var err := http.request(zip_url)
	if err != OK:
		push_error("CoreDownloadManager: failed to start download of '%s' (err %d)" % [core_name, err])
		_cleanup_download(core_name)
		done_callback.call(false, "Failed to start request (err %d)" % err)


func _process(_delta: float) -> void:
	# Poll progress for each active download
	for core_name: String in _active_downloads.keys():
		var info: Dictionary = _active_downloads[core_name]
		var http: HTTPRequest = info["http"]
		var downloaded := http.get_downloaded_bytes()
		var total := http.get_body_size()
		if total > 0 and info["progress_cb"].is_valid():
			info["progress_cb"].call(float(downloaded) / float(total))


func _on_download_completed(core_name: String, result: int, response_code: int) -> void:
	var info: Dictionary = _active_downloads.get(core_name, {})
	if info.is_empty():
		return

	var done_cb: Callable = info["done_cb"]
	var zip_path: String  = info["zip_path"]
	var remote_date: String = info["remote_date"]

	_cleanup_download(core_name)

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		# Remove incomplete zip if it exists
		if FileAccess.file_exists(zip_path):
			DirAccess.remove_absolute(zip_path)
		done_cb.call(false, "HTTP error result=%d code=%d" % [result, response_code])
		return

	# Extract the zip
	var extract_err := _extract_zip(zip_path, default_cores_dir())
	# Always delete the zip regardless of extraction result
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)

	if extract_err != OK:
		done_cb.call(false, "Zip extraction failed (err %d)" % extract_err)
		return

	# Update manifest
	manifest.set_downloaded(core_name, remote_date)
	print("[CoreDownloadManager] Downloaded and extracted: %s" % core_name)
	done_cb.call(true, "")


## Extract all files from zip_path into dest_dir.
## Returns OK on success, or an error code.
func _extract_zip(zip_path: String, dest_dir: String) -> int:
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		push_error("CoreDownloadManager: cannot open zip '%s' (err %d)" % [zip_path, err])
		return err

	for entry: String in reader.get_files():
		# Skip directory entries
		if entry.ends_with("/"):
			continue
		var data := reader.read_file(entry)
		# Flatten: write only the filename, not any path inside the zip
		var out_path := dest_dir.path_join(entry.get_file())
		var out := FileAccess.open(out_path, FileAccess.WRITE)
		if out == null:
			reader.close()
			push_error("CoreDownloadManager: cannot write '%s' (err %d)" % [out_path, FileAccess.get_open_error()])
			return FileAccess.get_open_error()
		out.store_buffer(data)
		out.close()

	reader.close()
	return OK


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _cleanup_download(core_name: String) -> void:
	if _active_downloads.has(core_name):
		var http: HTTPRequest = _active_downloads[core_name]["http"]
		if is_instance_valid(http):
			http.queue_free()
		_active_downloads.erase(core_name)
