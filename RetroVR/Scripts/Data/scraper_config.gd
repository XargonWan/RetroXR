## ScraperConfig — stores screenscraper.fr credentials and preferences.
## Developer credentials are hardcoded; user credentials and priorities are persisted.
class_name ScraperConfig
extends RefCounted


## Developer credentials (hardcoded).
const DEV_ID := ""
const DEV_PASSWORD := ""
const SOFT_NAME := "retrovr"

## User credentials (persisted).
var ssid: String = ""
var sspassword: String = ""

## Region priority for selecting localized content (first match wins).
var region_priorities: Array[String] = ["us", "eu", "jp", "ss"]

## Language priority for selecting localized text (first match wins).
var language_priorities: Array[String] = ["en", "fr"]


func load_config() -> void:
	var path := _config_path()
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_warning("[ScraperConfig] JSON parse error: %s" % json.get_error_message())
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}
	ssid = data.get("ssid", "")
	sspassword = data.get("sspassword", "")

	if data.has("region_priorities") and data["region_priorities"] is Array:
		region_priorities.clear()
		for r in data["region_priorities"]:
			region_priorities.append(str(r))

	if data.has("language_priorities") and data["language_priorities"] is Array:
		language_priorities.clear()
		for l in data["language_priorities"]:
			language_priorities.append(str(l))

	print("[ScraperConfig] Loaded config")


func save_config() -> void:
	var path := _config_path()
	var dir_path := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("[ScraperConfig] Failed to write: %s" % path)
		return

	var data := {
		"ssid": ssid,
		"sspassword": sspassword,
		"region_priorities": region_priorities,
		"language_priorities": language_priorities,
	}
	file.store_string(JSON.stringify(data, "\t"))
	print("[ScraperConfig] Saved config")


static func _config_path() -> String:
	return RomLibrary.default_roms_root().path_join("scraper_config.json")
