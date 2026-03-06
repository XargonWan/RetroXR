## DownloadManifest — tracks which cores have been downloaded and when.
##
## Persists to {core_dir}/cores_manifest.json.
## Schema:
##   {
##     "cores": {
##       "fceumm": {
##         "filename":      "fceumm_libretro.dll",
##         "remote_date":   "05-Mar-2026 03:12",
##         "downloaded_at": "2026-03-05T14:30:00"
##       }, ...
##     }
##   }
class_name DownloadManifest
extends RefCounted


var _core_dir: String = ""
var _data: Dictionary = {}  # "cores" -> { core_name -> { ... } }


func setup(core_dir: String) -> void:
	_core_dir = core_dir
	load_manifest()


# ---------------------------------------------------------------------------
# Load / Save
# ---------------------------------------------------------------------------

func load_manifest() -> void:
	var path := _manifest_path()
	if not FileAccess.file_exists(path):
		_data = {"cores": {}}
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("DownloadManifest: cannot open %s" % path)
		_data = {"cores": {}}
		return
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		_data = parsed
	else:
		push_warning("DownloadManifest: invalid JSON in %s, resetting" % path)
		_data = {"cores": {}}
	if not _data.has("cores"):
		_data["cores"] = {}


func save() -> void:
	var path := _manifest_path()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("DownloadManifest: cannot write to %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(_data, "\t"))
	file.close()


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func is_downloaded(core_name: String) -> bool:
	return _cores().has(core_name)


## Returns the remote_date string stored at download time, or "" if not downloaded.
func get_remote_date(core_name: String) -> String:
	return _cores().get(core_name, {}).get("remote_date", "")


## Returns the downloaded_at ISO timestamp string, or "" if not downloaded.
func get_downloaded_at(core_name: String) -> String:
	return _cores().get(core_name, {}).get("downloaded_at", "")


# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------

func set_downloaded(core_name: String, remote_date: String) -> void:
	_cores()[core_name] = {
		"filename":      core_name + "_libretro.dll",
		"remote_date":   remote_date,
		"downloaded_at": Time.get_datetime_string_from_system(false, true)
	}
	save()


func remove(core_name: String) -> void:
	_cores().erase(core_name)
	save()


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _manifest_path() -> String:
	return _core_dir.path_join("cores_manifest.json")


func _cores() -> Dictionary:
	if not _data.has("cores"):
		_data["cores"] = {}
	return _data["cores"]
