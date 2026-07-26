## RommConfig — connection settings and sync bookkeeping for a RomM server.
##
## Lives beside scraper_config.json in the roms root so it survives an app
## reinstall on Android and is visible through the web file manager.
class_name RommConfig
extends RefCounted


## Auth modes. TOKEN sends a long-lived client API token (rmm_<64 hex>);
## BASIC sends username/password. Both are accepted by RomM 5.x.
const AUTH_TOKEN := "token"
const AUTH_BASIC := "basic"

## Server base URL, no trailing slash — e.g. "http://192.168.0.106:8080".
var base_url: String = ""
var enabled: bool = false

var auth_mode: String = AUTH_TOKEN
var token: String = ""
var username: String = ""
var password: String = ""

## Cap on disk used by ROMs pulled from RomM. Hand-copied ROMs never count
## toward this and are never evicted.
var cache_budget_gb: float = 20.0

## Collapse multi-region duplicates into one row (RomM's group_by_meta_id).
var group_by_meta_id: bool = true

## romm platform slug (or fs_slug) -> project systemid, for platforms the
## built-in RommPlatforms map doesn't cover.
var platform_overrides: Dictionary = {}

## systemid -> {updated_after: String, total: int, synced_at: String}
var sync_state: Dictionary = {}

## Last seen /api/stats fingerprint: {ROMS: int, TOTAL_FILESIZE_BYTES: int}.
## If this hasn't moved, the library provably hasn't changed and no /api/roms
## call is needed at all.
var last_stats: Dictionary = {}


## True when there is enough configured to attempt a request.
func is_configured() -> bool:
	if not enabled or base_url.is_empty():
		return false
	if auth_mode == AUTH_TOKEN:
		return not token.is_empty()
	return not username.is_empty()


## Normalize whatever the user typed into a usable base URL.
## Adds http:// when no scheme is given, strips trailing slashes.
static func normalize_url(raw: String) -> String:
	var url := raw.strip_edges()
	if url.is_empty():
		return ""
	if not (url.begins_with("http://") or url.begins_with("https://")):
		url = "http://" + url
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url


## Authorization header value, or "" when unauthenticated.
## Note: cover art must NOT use this — RomM's nginx serves /assets with no
## auth gate, and sending credentials there is pointless overhead.
func auth_header() -> String:
	if auth_mode == AUTH_TOKEN:
		if token.is_empty():
			return ""
		return "Authorization: Bearer " + token
	if username.is_empty():
		return ""
	return "Authorization: Basic " + Marshalls.utf8_to_base64(username + ":" + password)


## Headers for any /api/** request. Empty array when unconfigured.
func auth_headers() -> PackedStringArray:
	var h := auth_header()
	if h.is_empty():
		return PackedStringArray()
	return PackedStringArray([h])


func cache_budget_bytes() -> int:
	return int(cache_budget_gb * 1024.0 * 1024.0 * 1024.0)


## Record a platform's sync watermark. `updated_after` is the max updated_at
## seen in that platform's ROMs, used for the next delta query.
func set_sync_state(systemid: String, updated_after: String, total: int) -> void:
	sync_state[systemid] = {
		"updated_after": updated_after,
		"total": total,
		"synced_at": Time.get_datetime_string_from_system(true),
	}


func get_sync_state(systemid: String) -> Dictionary:
	var v: Variant = sync_state.get(systemid, {})
	return v if v is Dictionary else {}


## True when /api/stats reports the same library as the last time we looked.
func stats_unchanged(stats: Dictionary) -> bool:
	if last_stats.is_empty() or stats.is_empty():
		return false
	return int(last_stats.get("ROMS", -1)) == int(stats.get("ROMS", -2)) \
		and int(last_stats.get("TOTAL_FILESIZE_BYTES", -1)) == int(stats.get("TOTAL_FILESIZE_BYTES", -2))


func load_config() -> void:
	var path := config_path()
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("[RommConfig] JSON parse error: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	base_url = normalize_url(str(data.get("base_url", "")))
	enabled = bool(data.get("enabled", false))
	auth_mode = str(data.get("auth_mode", AUTH_TOKEN))
	if auth_mode != AUTH_TOKEN and auth_mode != AUTH_BASIC:
		auth_mode = AUTH_TOKEN
	token = str(data.get("token", ""))
	username = str(data.get("username", ""))
	password = str(data.get("password", ""))
	cache_budget_gb = float(data.get("cache_budget_gb", 20.0))
	group_by_meta_id = bool(data.get("group_by_meta_id", true))

	if data.get("platform_overrides") is Dictionary:
		platform_overrides = data["platform_overrides"]
	if data.get("sync_state") is Dictionary:
		sync_state = data["sync_state"]
	if data.get("last_stats") is Dictionary:
		last_stats = data["last_stats"]

	print("[RommConfig] Loaded config (server=%s enabled=%s)" % [base_url, enabled])


func save_config() -> void:
	var path := config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("[RommConfig] Failed to write: %s" % path)
		return

	var data := {
		"base_url": base_url,
		"enabled": enabled,
		"auth_mode": auth_mode,
		"token": token,
		"username": username,
		"password": password,
		"cache_budget_gb": cache_budget_gb,
		"group_by_meta_id": group_by_meta_id,
		"platform_overrides": platform_overrides,
		"sync_state": sync_state,
		"last_stats": last_stats,
	}
	file.store_string(JSON.stringify(data, "\t"))


static func config_path() -> String:
	return RomLibrary.default_roms_root().path_join("romm_config.json")
