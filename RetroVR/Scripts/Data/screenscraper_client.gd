## ScreenscraperClient — queries screenscraper.fr API and downloads media.
##
## Must be added to the scene tree (creates HTTPRequest child nodes).
class_name ScreenscraperClient
extends Node


const API_BASE := "https://www.screenscraper.fr/api2/jeuInfos.php"
const MIN_REQUEST_INTERVAL_MS := 1200
const MAX_RETRIES := 3
const REQUEST_TIMEOUT := 75.0
const MIN_MEDIA_SIZE := 256  # bytes — reject placeholder/error responses


signal scrape_completed(result: Dictionary)
signal scrape_failed(error: String)
signal media_download_completed(media_type: String, path: String)
signal media_download_failed(media_type: String, error: String)


var config: ScraperConfig = null

var _last_request_time_ms: int = 0
var _scrape_http: HTTPRequest = null
var _media_downloads: Dictionary = {}  # media_type -> HTTPRequest


func _ready() -> void:
	if config == null:
		config = ScraperConfig.new()
		config.load_config()


## Scrape a ROM by its checksums. Emits scrape_completed or scrape_failed.
## checksums: {crc, md5, sha1, size} from RomHasher.
func scrape_rom(rom_path: String, systemid: String, checksums: Dictionary) -> void:
	print("[ScreenscraperClient] scrape_rom: %s (system=%s)" % [rom_path.get_file(), systemid])
	var systemeid := ScreenscraperSystems.get_systemeid(systemid)
	if systemeid < 0:
		push_warning("[ScreenscraperClient] No screenscraper systemeid for '%s'" % systemid)
		scrape_failed.emit("System '%s' is not supported for scraping" % systemid)
		return

	if checksums.is_empty():
		push_warning("[ScreenscraperClient] Checksums empty for: %s" % rom_path)
		scrape_failed.emit("Could not read ROM file checksums")
		return

	print("[ScreenscraperClient] systemeid=%d  CRC=%s" % [systemeid, checksums.get("crc", "?")])
	# Rate limit
	await _wait_for_rate_limit()

	var url := _build_query_url(rom_path, systemeid, checksums)
	print("[ScreenscraperClient] Requesting: %s" % url)
	_do_scrape_request(url, rom_path, 0)


func _build_query_url(rom_path: String, systemeid: int, checksums: Dictionary) -> String:
	var params := PackedStringArray()
	params.append("devid=%s" % ScraperConfig.DEV_ID)
	params.append("devpassword=%s" % ScraperConfig.DEV_PASSWORD)
	params.append("softname=%s" % ScraperConfig.SOFT_NAME)

	if not config.ssid.is_empty():
		params.append("ssid=%s" % config.ssid.uri_encode())
	if not config.sspassword.is_empty():
		params.append("sspassword=%s" % config.sspassword.uri_encode())

	params.append("systemeid=%d" % systemeid)
	params.append("output=json")
	params.append("crc=%s" % checksums.get("crc", ""))
	params.append("md5=%s" % checksums.get("md5", ""))
	params.append("sha1=%s" % checksums.get("sha1", ""))
	params.append("romnom=%s" % rom_path.get_file().uri_encode())
	params.append("romtaille=%d" % checksums.get("size", 0))

	return API_BASE + "?" + "&".join(params)


func _do_scrape_request(url: String, rom_path: String, retry_count: int) -> void:
	if _scrape_http != null:
		_scrape_http.queue_free()

	_scrape_http = HTTPRequest.new()
	_scrape_http.use_threads = true
	_scrape_http.timeout = REQUEST_TIMEOUT
	add_child(_scrape_http)

	_scrape_http.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
			_on_scrape_completed(result, response_code, body, url, rom_path, retry_count)
	)

	_last_request_time_ms = Time.get_ticks_msec()
	var err := _scrape_http.request(url)
	if err != OK:
		_cleanup_scrape_http()
		scrape_failed.emit("Failed to start HTTP request (err %d)" % err)


func _on_scrape_completed(result: int, response_code: int, body: PackedByteArray,
						  url: String, rom_path: String, retry_count: int) -> void:
	_cleanup_scrape_http()
	print("[ScreenscraperClient] Response: result=%d code=%d body_len=%d" % [result, response_code, body.size()])

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		if retry_count < MAX_RETRIES:
			var delay := pow(2, retry_count + 1)
			print("[ScreenscraperClient] Retry %d after %.0fs (result=%d code=%d)" % [retry_count + 1, delay, result, response_code])
			await get_tree().create_timer(delay).timeout
			_do_scrape_request(url, rom_path, retry_count + 1)
			return
		scrape_failed.emit("HTTP error after %d retries (result=%d code=%d)" % [MAX_RETRIES, result, response_code])
		return

	var text := body.get_string_from_utf8()

	# Check for known error strings
	if text.find("non trouvée") >= 0 or text.find("Erreur") >= 0:
		push_warning("[ScreenscraperClient] API text error (non trouvée/Erreur): %s" % text.left(200))
		scrape_failed.emit("Game not found in screenscraper database")
		return
	if text.find("API fermé") >= 0 or text.find("API totalement fermé") >= 0:
		push_warning("[ScreenscraperClient] API closed")
		scrape_failed.emit("ScreenScraper API is currently closed")
		return
	if text.find("blacklisté") >= 0:
		push_warning("[ScreenscraperClient] Account blacklisted")
		scrape_failed.emit("Your account has been blacklisted")
		return
	if text.find("Votre quota") >= 0:
		push_warning("[ScreenscraperClient] Daily quota exceeded")
		scrape_failed.emit("Daily scrape quota exceeded")
		return

	var json := JSON.new()
	if json.parse(text) != OK:
		scrape_failed.emit("Invalid JSON response: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var header: Dictionary = data.get("header", {})
	if str(header.get("success", "")) != "true":
		var error_msg: String = str(header.get("error", "Unknown error"))
		if retry_count < MAX_RETRIES:
			var delay := pow(2, retry_count + 1)
			await get_tree().create_timer(delay).timeout
			_do_scrape_request(url, rom_path, retry_count + 1)
			return
		scrape_failed.emit("API error: %s" % error_msg)
		return

	var response: Dictionary = data.get("response", {})
	var jeu: Dictionary = response.get("jeu", {})

	if jeu.is_empty():
		scrape_failed.emit("Game not found in screenscraper database")
		return

	var parsed := _parse_jeu(jeu)
	print("[ScreenscraperClient] Scrape success: game_id=%s name=%s" % [parsed.get("game_id", "?"), parsed.get("name", "?")])
	scrape_completed.emit(parsed)


## Parse the jeu object into our normalized format.
func _parse_jeu(jeu: Dictionary) -> Dictionary:
	var result := {}

	# Game ID
	result["game_id"] = str(jeu.get("id", ""))

	# Game name — from noms array, pick by region priority
	result["name"] = _pick_by_region(jeu.get("noms", []))

	# Description — from synopsis array, pick by language priority
	result["desc"] = _pick_by_language(jeu.get("synopsis", []))

	# Developer
	var dev: Dictionary = jeu.get("developpeur", {})
	result["developer"] = str(dev.get("text", ""))

	# Publisher
	var pub: Dictionary = jeu.get("editeur", {})
	result["publisher"] = str(pub.get("text", ""))

	# Genre — array of genre objects, each has noms[]
	var genre_names := PackedStringArray()
	var genres = jeu.get("genres", [])
	if genres is Array:
		for genre in genres:
			if genre is Dictionary:
				var gname := _pick_by_language(genre.get("noms", []))
				if not gname.is_empty():
					genre_names.append(gname)
	result["genre"] = ", ".join(genre_names)

	# Matched ROM info
	var rom: Dictionary = jeu.get("rom", {})
	var regions: Dictionary = rom.get("regions", {})
	var regions_en: Array = regions.get("regions_en", [])
	result["rom_region"] = str(regions_en[0]) if not regions_en.is_empty() else ""
	var regions_short: Array = regions.get("regions_shortname", [])
	result["rom_region_codes"] = regions_short
	print("[ScreenscraperClient] ROM region codes: %s" % str(regions_short))

	# Release date
	result["releasedate"] = _pick_by_region(jeu.get("dates", []))

	# Media URLs — pass ROM region codes so media selection prefers the ROM's own region
	result["media"] = _extract_media_urls(jeu.get("medias", []), regions_short)

	return result


## Pick text from an array of {region, text} entries using region priority.
func _pick_by_region(arr) -> String:
	if not arr is Array:
		return ""
	for prio: String in config.region_priorities:
		for entry in arr:
			if entry is Dictionary and str(entry.get("region", "")) == prio:
				var val = entry.get("text", entry.get("url", ""))
				if not str(val).is_empty():
					return str(val)
	# Fallback: return first non-empty
	for entry in arr:
		if entry is Dictionary:
			var val = entry.get("text", entry.get("url", ""))
			if not str(val).is_empty():
				return str(val)
	return ""


## Pick text from an array of {langue, text} entries using language priority.
func _pick_by_language(arr) -> String:
	if not arr is Array:
		return ""
	for prio: String in config.language_priorities:
		for entry in arr:
			if entry is Dictionary and str(entry.get("langue", "")) == prio:
				var val := str(entry.get("text", ""))
				if not val.is_empty():
					return val
	# Fallback: return first non-empty
	for entry in arr:
		if entry is Dictionary:
			var val := str(entry.get("text", ""))
			if not val.is_empty():
				return val
	return ""


## Extract media URLs we care about from the medias array.
## rom_region_codes: short region codes from the matched ROM (e.g. ["us"]) — used as top priority.
## Returns {wheel: url, box: url, label: url, manual: url} (empty string if not found).
func _extract_media_urls(medias, rom_region_codes: Array = []) -> Dictionary:
	var result := {"wheel": "", "box": "", "label": "", "manual": ""}
	if not medias is Array:
		return result

	# Build effective priority: ROM's own region codes first, then "wor", then user priorities.
	var effective_priorities: Array[String] = []
	for code in rom_region_codes:
		var s := str(code)
		if not effective_priorities.has(s):
			effective_priorities.append(s)
	if not effective_priorities.has("wor"):
		effective_priorities.append("wor")
	for code: String in config.region_priorities:
		if not effective_priorities.has(code):
			effective_priorities.append(code)
	print("[ScreenscraperClient] Effective media region priorities: %s" % str(effective_priorities))

	# Collect candidates per type
	var candidates := {"wheel": [], "box": [], "label": [], "manual": []}

	for entry in medias:
		if not entry is Dictionary:
			continue
		var mtype: String = str(entry.get("type", ""))
		var url: String = str(entry.get("url", ""))
		var region: String = str(entry.get("region", ""))
		if url.is_empty():
			continue

		if mtype == "wheel" or mtype == "wheel-hd":
			candidates["wheel"].append({"url": url, "region": region, "type": mtype})
		elif mtype == "box-texture":
			candidates["box"].append({"url": url, "region": region})
		elif mtype == "support-texture":
			candidates["label"].append({"url": url, "region": region})
		elif mtype == "manuel":
			candidates["manual"].append({"url": url, "region": region})

	# For each media type, pick best by effective region priority
	for key: String in result.keys():
		var cands: Array = candidates[key]
		if cands.is_empty():
			continue
		var found := false
		for prio: String in effective_priorities:
			for c: Dictionary in cands:
				if c.get("region", "") == prio:
					result[key] = c["url"]
					found = true
					break
			if found:
				break
		if not found:
			# Fallback: first available
			result[key] = (cands[0] as Dictionary).get("url", "")
		print("[ScreenscraperClient] Media[%s] → region candidates: %s → picked: %s" % [key, str(cands.map(func(c): return c.get("region",""))), result[key].get_file()])

	return result


## Download a media file to the given destination path. Emits media_download_completed
## or media_download_failed.
func download_media(media_type: String, url: String, dest_path: String) -> void:
	if url.is_empty():
		media_download_failed.emit(media_type, "No URL")
		return

	await _wait_for_rate_limit()

	var dir_path := dest_path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REQUEST_TIMEOUT
	http.download_file = dest_path
	add_child(http)
	_media_downloads[media_type] = http

	http.request_completed.connect(
		func(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
			_on_media_download_completed(media_type, result, response_code, dest_path)
	)

	_last_request_time_ms = Time.get_ticks_msec()
	var err := http.request(url)
	if err != OK:
		_cleanup_media_download(media_type)
		media_download_failed.emit(media_type, "Failed to start request (err %d)" % err)


func _on_media_download_completed(media_type: String, result: int,
								  response_code: int, dest_path: String) -> void:
	_cleanup_media_download(media_type)
	print("[ScreenscraperClient] Media download: type=%s result=%d code=%d path=%s" % [media_type, result, response_code, dest_path])

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		if FileAccess.file_exists(dest_path):
			DirAccess.remove_absolute(dest_path)
		media_download_failed.emit(media_type, "HTTP error result=%d code=%d" % [result, response_code])
		return

	# Check minimum file size
	if FileAccess.file_exists(dest_path):
		var file := FileAccess.open(dest_path, FileAccess.READ)
		if file and file.get_length() < MIN_MEDIA_SIZE:
			file.close()
			DirAccess.remove_absolute(dest_path)
			media_download_failed.emit(media_type, "File too small (likely error response)")
			return

	media_download_completed.emit(media_type, dest_path)


## Start downloading all available media for a scraped result.
## rom_basename: e.g. "Banjo-Kazooie (USA)" (no extension)
func download_all_media(scrape_result: Dictionary, systemid: String, rom_basename: String) -> void:
	var media: Dictionary = scrape_result.get("media", {})
	var media_root := RomLibrary.rom_dir_for_system(systemid).path_join("media")

	var type_map := {
		"wheel": {"dir": "wheel", "ext": ".png"},
		"box": {"dir": "box", "ext": ".png"},
		"label": {"dir": "label", "ext": ".png"},
		"manual": {"dir": "manual", "ext": ".pdf"},
	}

	for mtype: String in type_map:
		var url: String = media.get(mtype, "")
		if url.is_empty():
			continue
		# Determine file extension from URL if possible
		var ext: String = type_map[mtype]["ext"]
		var url_ext := url.get_extension().to_lower()
		if not url_ext.is_empty() and url_ext.length() <= 4:
			ext = "." + url_ext
		var dir_name: String = type_map[mtype]["dir"]
		var dest := media_root.path_join(dir_name).path_join(rom_basename + ext)
		download_media(mtype, url, dest)


func _wait_for_rate_limit() -> void:
	var now := Time.get_ticks_msec()
	var elapsed := now - _last_request_time_ms
	if elapsed < MIN_REQUEST_INTERVAL_MS:
		var wait_ms := MIN_REQUEST_INTERVAL_MS - elapsed
		await get_tree().create_timer(float(wait_ms) / 1000.0).timeout


func _cleanup_scrape_http() -> void:
	if _scrape_http != null and is_instance_valid(_scrape_http):
		_scrape_http.queue_free()
	_scrape_http = null


func _cleanup_media_download(media_type: String) -> void:
	if _media_downloads.has(media_type):
		var http: HTTPRequest = _media_downloads[media_type]
		if is_instance_valid(http):
			http.queue_free()
		_media_downloads.erase(media_type)
