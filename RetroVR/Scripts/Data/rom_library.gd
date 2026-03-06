## RomLibrary — manages the %USERPROFILE%/roms/{systemid}/ directory structure.
##
## ROM directories are created automatically at startup (via CoreDefaults.load_defaults())
## and on core download completion. scan_roms() filters by supported_extensions.
class_name RomLibrary
extends RefCounted


## Root directory: %USERPROFILE%/retrovr/roms
static func default_roms_root() -> String:
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retrovr/roms"


## Absolute path for a single system's ROM folder.
static func rom_dir_for_system(systemid: String) -> String:
	return default_roms_root().path_join(systemid)


## Create just the top-level roms/ root (no systemid). Safe to call any time.
static func ensure_roms_root() -> void:
	var path := default_roms_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured roms root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create roms root '%s' (err %d)" % [path, err])


## Create the ROM folder for a system (idempotent — always calls make_dir_recursive).
static func ensure_rom_dir(systemid: String) -> void:
	if systemid.is_empty():
		return
	var path := rom_dir_for_system(systemid)
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured rom dir: ", path)
	else:
		push_warning("[RomLibrary] Failed to create rom dir '%s' (err %d)" % [path, err])


## Scan a system's ROM folder and return all matching files.
## extensions: lowercase strings without dots, e.g. ["nes", "fds"].
## Returns Array of {path: String, label: String} sorted by label, or [] if folder missing.
static func scan_roms(systemid: String, extensions: Array[String]) -> Array[Dictionary]:
	var dir_path := rom_dir_for_system(systemid)
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []

	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and not fname.begins_with("."):
			var ext := fname.get_extension().to_lower()
			if extensions.is_empty() or ext in extensions:
				results.append({"path": dir_path.path_join(fname), "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results
