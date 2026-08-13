## RomCompat — will this core accept this file, and can we make it accept it?
##
## RetroArch unpacks an archive the running core cannot read. libretro-godot
## hands the path straight to retro_load_game, so a .zip reaches a core that
## only declares "lnx", the load fails, and nothing signals back to GDScript —
## the machine sits powered on with a black screen. Everything here exists to
## settle that before StartContent rather than after.
##
## The rule that must not be broken: a core that DECLARES an archive extension
## is handed the archive untouched. For fbneo, MAME and daphne the .zip IS the
## ROM — a romset is a directory of named entries, not a wrapper around one
## file — so unpacking those would break games that work today. 67 of the 314
## vendored .info files declare zip, and every one of them means it.
class_name RomCompat


## What evaluate() decided about a (file, core) pair.
enum Verdict {
	OK,           ## The core declares this extension. Hand it over as-is.
	EXTRACT,      ## An archive the core cannot read, holding something it can.
	UNSUPPORTED,  ## Nothing in here the core can load.
	UNKNOWN,      ## No .info for this core, so no opinion — let it through.
}

## Archives we can open. Godot ships a zip reader and nothing else, so a .7z or
## .rar has to be named rather than quietly retried — otherwise it reads to the
## player as "broken game" instead of "unpack this one yourself".
const UNPACKABLE := ["zip"]
const OTHER_ARCHIVES := ["7z", "rar"]

## Preferred launch targets inside an archive, best first. A disc manifest names
## the tracks beside it, so picking a raw .bin out of an unpacked cue/bin pair
## would throw away the track layout.
const LAUNCH_PRIORITY := ["m3u", "cue", "gdi", "ccd", "mds"]


# ---------------------------------------------------------------------------
# Core facts
# ---------------------------------------------------------------------------

## Extensions this core declares, lowercase and without dots. Empty when no
## .info describes the core, which is not the same as "accepts nothing".
static func extensions_for_core(core_name: String) -> Array[String]:
	var entry := CoreInfoDatabase.shared().get_by_core_name(core_name)
	var exts: Array[String] = []
	for e: String in str(entry.get("supported_extensions", "")).split("|"):
		var s := e.strip_edges().to_lower()
		if not s.is_empty() and s not in exts:
			exts.append(s)
	return exts


## Short human name for a core ("Handy", "Azahar"), for messages a player reads.
## `corename` rather than `display_name`: the latter is "Atari - Lynx (Handy)",
## which reads as the platform's name rather than the core's.
static func core_label(core_name: String) -> String:
	var label := str(CoreInfoDatabase.shared().get_by_core_name(core_name)
		.get("corename", "")).strip_edges()
	return label if not label.is_empty() else core_name


# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

## Judge a file against a core without touching the disk.
##
## Returns {verdict, path, entry, message}:
##   path    — what the core should be handed (unchanged unless resolve() runs)
##   entry   — for EXTRACT, the name inside the archive that will be launched
##   message — one full sentence, shown to the player and logged
static func evaluate(rom_path: String, core_name: String) -> Dictionary:
	var out := {"verdict": Verdict.UNKNOWN, "path": rom_path, "entry": "",
				"message": ""}
	if rom_path.is_empty() or core_name.is_empty():
		return out

	var exts := extensions_for_core(core_name)
	if exts.is_empty():
		return out

	# A folder is content in its own right for the cores that take one (dosbox_pure
	# declares "/"), and it has no extension to judge. ScummVM hands us the marker
	# file inside the folder, so that case never reaches here.
	if DirAccess.dir_exists_absolute(rom_path):
		out["verdict"] = Verdict.OK
		return out

	var ext := rom_path.get_extension().to_lower()
	var label := core_label(core_name)

	# Declared — including a core whose content format IS an archive.
	if ext in exts:
		out["verdict"] = Verdict.OK
		return out

	if ext in UNPACKABLE:
		return _judge_archive(rom_path, core_name, exts, label, out)

	if ext in OTHER_ARCHIVES:
		out["verdict"] = Verdict.UNSUPPORTED
		out["message"] = "%s cannot run .%s files, and RetroXR can only unpack .zip. " \
			% [label, ext] + "Unpack %s yourself and keep the %s inside." \
			% [rom_path.get_file(), _ext_list(exts)]
		return out

	out["verdict"] = Verdict.UNSUPPORTED
	out["message"] = "%s cannot run .%s files. It takes %s." % [label, ext, _ext_list(exts)]
	return out


## Look inside a zip the core did not declare and decide whether unpacking it
## would produce something the core can load.
static func _judge_archive(zip_path: String, _core_name: String, exts: Array[String],
						   label: String, out: Dictionary) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		out["verdict"] = Verdict.UNSUPPORTED
		out["message"] = "%s is not a readable .zip." % zip_path.get_file()
		return out

	var names := reader.get_files()
	reader.close()

	var target := _choose_entry(names, exts)
	if not target.is_empty():
		out["verdict"] = Verdict.EXTRACT
		out["entry"] = target
		out["message"] = "%s cannot read .zip; unpacking %s to get %s." \
			% [label, zip_path.get_file(), target.get_file()]
		return out

	out["verdict"] = Verdict.UNSUPPORTED
	var inside := _distinct_extensions(names)
	out["message"] = "%s cannot run %s. It holds %s and the core takes %s." % [
		label, zip_path.get_file(),
		("nothing readable" if inside.is_empty() else _ext_list(inside)),
		_ext_list(exts)]
	return out


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

## evaluate(), then act on it: an EXTRACT verdict unpacks the archive beside
## itself, deletes it, and comes back pointing at the file the core wanted.
##
## `systemid` is only needed to keep the RomM cache manifest honest when the
## archive it recorded is the one being replaced; pass "" for content that did
## not come from a server.
##
## Returns the same shape as evaluate(), with `path` moved onto the unpacked
## file and the verdict downgraded to UNSUPPORTED if unpacking failed.
static func resolve(rom_path: String, core_name: String, systemid: String = "") -> Dictionary:
	var verdict := evaluate(rom_path, core_name)
	if int(verdict["verdict"]) != Verdict.EXTRACT:
		return verdict

	var started := Time.get_ticks_msec()
	var result := _unpack(rom_path, str(verdict["entry"]))
	if not str(result["error"]).is_empty():
		verdict["verdict"] = Verdict.UNSUPPORTED
		verdict["message"] = str(result["error"])
		return verdict

	print("[RomCompat] Unpacked %s -> %s in %d ms" % [
		rom_path.get_file(), str(result["path"]).get_file(),
		Time.get_ticks_msec() - started])

	if not systemid.is_empty():
		_rekey_cache(systemid, rom_path.get_file(), str(result["path"]))

	verdict["verdict"] = Verdict.OK
	verdict["path"] = result["path"]
	return verdict


## Extract every entry beside the archive, then delete the archive. All of it,
## not just the target: a .cue names the tracks next to it, and a core handed a
## lone descriptor fails exactly as opaquely as it did on the .zip.
static func _unpack(zip_path: String, target: String) -> Dictionary:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return {"path": "", "error": "Could not open %s" % zip_path.get_file()}

	var dest_dir := zip_path.get_base_dir()
	var plan := RommDownloader._archive_plan(reader, dest_dir)
	reader.close()
	if plan.is_empty():
		return {"path": "", "error": "%s contains unsafe, colliding, or unreadable files"
			% zip_path.get_file()}
	var extracted: Dictionary = RommArchiveExtractor.new().extract(zip_path, plan)
	if not bool(extracted.get("ok", false)):
		return {"path": "", "error": str(extracted.get("error", "Could not unpack archive"))}
	var launch := ""

	for item: Dictionary in extracted.get("files", []):
		if str(item.get("entry", "")) == target:
			launch = str(item.get("path", ""))

	if launch.is_empty():
		# The native extractor made every final itself, so they are all known to be
		# owned by this failed attempt and can be rolled back without touching any
		# file that predated it.
		for item: Dictionary in extracted.get("files", []):
			DirAccess.remove_absolute(str(item.get("path", "")))
		return {"path": "", "error": "%s was not in %s after unpacking"
			% [target, zip_path.get_file()]}

	DirAccess.remove_absolute(zip_path)
	return {"path": launch, "error": ""}


## Move a RomM cache entry from the archive onto what came out of it.
##
## The manifest is the only record of which files may be evicted to reclaim
## space; leaving it pointing at a deleted .zip would both re-report the game as
## "not downloaded" and orphan the unpacked file, which no longer belongs to any
## budget. Re-read from disk rather than sharing an instance, so this stays
## correct whether or not the spawn menu happens to be open.
static func _rekey_cache(systemid: String, archive_name: String, new_path: String) -> void:
	var manifest := RommCacheManifest.new()
	manifest.load_manifest()
	var entry := manifest.entry(systemid, archive_name)
	if entry.is_empty():
		return   # hand-copied, not server-sourced — nothing to re-key
	manifest.forget(systemid, archive_name)
	# The md5 carries over rather than being blanked: RomM's hash describes the
	# ROM *content*, not the container, so the value recorded against the .zip is
	# already the hash of what just came out of it.
	manifest.add(systemid, new_path.get_file(), int(entry.get("rom_id", 0)),
		_file_size(new_path), str(entry.get("md5", "")))


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Entries worth unpacking: not a directory, not editor litter, and not naming a
## path outside the ROM folder.
##
## One predicate rather than a copy per loop. When _choose_entry and _unpack
## disagreed, a poisoned first entry was picked as the launch target and then
## refused on the way out, failing an archive that had a perfectly good ROM in it.
static func _is_safe_entry(name: String) -> bool:
	if name.ends_with("/") or name.begins_with("__MACOSX/"):
		return false
	if name.begins_with("/") or ".." in name.split("/"):
		return false
	var base := name.get_file()
	return not base.is_empty() and not base.begins_with(".")


## The entry inside an archive the core would most like to be handed.
static func _choose_entry(names: PackedStringArray, exts: Array[String]) -> String:
	var best := ""
	var best_rank := LAUNCH_PRIORITY.size() + 1
	for name: String in names:
		if not _is_safe_entry(name):
			continue
		var ext := name.get_file().get_extension().to_lower()
		if ext not in exts:
			continue
		var rank := LAUNCH_PRIORITY.find(ext)
		if rank < 0:
			rank = LAUNCH_PRIORITY.size()
		if rank < best_rank:
			best_rank = rank
			best = name
	return best


## Distinct extensions present in an archive, for a message that says what was
## actually in there rather than just what was missing.
static func _distinct_extensions(names: PackedStringArray) -> Array[String]:
	var found: Array[String] = []
	for name: String in names:
		if not _is_safe_entry(name):
			continue
		var ext := name.get_file().get_extension().to_lower()
		if not ext.is_empty() and ext not in found:
			found.append(ext)
	return found


## ".lnx, .lyx or .o" — the tail of a sentence a player reads.
static func _ext_list(exts: Array[String]) -> String:
	var dotted := PackedStringArray()
	for e: String in exts:
		dotted.append("." + e)
	if dotted.is_empty():
		return "nothing"
	if dotted.size() == 1:
		return dotted[0]
	return ", ".join(dotted.slice(0, dotted.size() - 1)) \
		+ " or " + dotted[dotted.size() - 1]
