## RommFirmware — the firmware RomM is holding, indexed so a core's declared
## BIOS can be looked up by name.
##
## RomM 5.x mirrors its ROM endpoints for firmware:
##   GET /api/firmware[?platform_id=N]        list
##   GET /api/firmware/{id}/content/{name}    download
##
## The list response carries no platform_id field — only `file_path`, which is
## "bios/<platform slug>". Since the join we actually want is against the
## filenames each .info declares, one unfiltered call is enough; filtering per
## platform would mean one request per platform for no extra information.
class_name RommFirmware
extends Node


signal listed(ok: bool, count: int)

var config: RommConfig = null

## lowercase basename -> {id, file_name, size, md5}
var _by_name: Dictionary = {}
var _loaded := false
var _in_flight := false


func setup(cfg: RommConfig) -> void:
	config = cfg


func is_loaded() -> bool:
	return _loaded


## Look a declared firmware path up on the server.
##
## Matching is on the basename, case-insensitively: the .info path may be
## nested ("Machines/Shared Roms/MSX.rom") while the server stores a flat
## name, and the two disagree on case (server "MSX.ROM").
## Returns {} when the server does not have it.
func find(firmware_path: String) -> Dictionary:
	if not _loaded:
		return {}
	return _by_name.get(firmware_path.get_file().to_lower(), {})


## Request path for a firmware entry's content.
static func content_path(id: int, file_name: String) -> String:
	return "/api/firmware/%d/content/%s" % [id, file_name.uri_encode()]


## Fetch the list once per session. `force` re-fetches (the Re-check button).
##
## `listed` announces the ARRIVAL of new data, so the already-loaded path stays
## silent. Emitting it here would re-enter any handler that redraws a view whose
## rebuild calls refresh() — which is exactly what the BIOS tab does, and it
## recursed until the stack blew.
func refresh(force: bool = false) -> void:
	if _in_flight:
		return
	if _loaded and not force:
		return
	if config == null or not config.is_configured():
		return

	_in_flight = true
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	req.request_completed.connect(
		func(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			_in_flight = false
			req.queue_free()
			if code != 200:
				listed.emit(false, 0)
				return
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if not (parsed is Array):
				listed.emit(false, 0)
				return
			_index(parsed as Array)
			_loaded = true
			listed.emit(true, _by_name.size())
	)
	var url: String = config.base_url + "/api/firmware"
	if req.request(url, config.auth_headers(), HTTPClient.METHOD_GET) != OK:
		_in_flight = false
		req.queue_free()
		listed.emit(false, 0)


func _index(items: Array) -> void:
	_by_name.clear()
	for item: Variant in items:
		if not (item is Dictionary):
			continue
		var d := item as Dictionary
		var name := str(d.get("file_name", ""))
		if name.is_empty():
			continue
		# A file the server has a record of but no longer holds cannot be
		# fetched; leaving it out means the row reads "not on the server",
		# which is the truth, rather than offering a download that 404s.
		if bool(d.get("missing_from_fs", false)):
			continue
		_by_name[name.to_lower()] = {
			"id": int(d.get("id", 0)),
			"file_name": name,
			"size": int(d.get("file_size_bytes", 0)),
			"md5": str(d.get("md5_hash", "")).to_lower(),
		}
