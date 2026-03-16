## RomLibrary — manages the %USERPROFILE%/roms/{systemid}/ directory structure.
##
## ROM directories are created automatically at startup (via CoreDefaults.load_defaults())
## and on core download completion. scan_roms() filters by supported_extensions.
class_name RomLibrary
extends RefCounted


## Root directory for ROMs.
## On Android: app external files dir (no permission needed). On Windows: %USERPROFILE%/retrovr/roms.
static func default_roms_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retrovr/files/roms"
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
	if DirAccess.dir_exists_absolute(path):
		return
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Created rom dir: ", path)
	else:
		push_warning("[RomLibrary] Failed to create rom dir '%s' (err %d)" % [path, err])


## Scan a system's ROM folder and return all matching files.
## extensions: lowercase strings without dots, e.g. ["nes", "fds"].
## Returns Array of {path: String, label: String} sorted by label, or [] if folder missing.
##
## Multi-file disc images (bin/cue, img/ccd, mdf/mds) are collapsed to their
## descriptor file — the data-only companion is hidden when its descriptor exists.
static func scan_roms(systemid: String, extensions: Array[String]) -> Array[Dictionary]:
	var dir_path := rom_dir_for_system(systemid)
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []

	# data ext -> descriptor ext that supersedes it
	const SHADOWED_BY := {"bin": "cue", "img": "ccd", "mdf": "mds"}

	# First pass: collect all filenames present in the directory
	var all_files: Dictionary = {}  # filename (lowercase) -> true
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			all_files[fname.to_lower()] = true
		fname = dir.get_next()
	dir.list_dir_end()

	# Second pass: build results, skipping data files whose descriptor exists
	var results: Array[Dictionary] = []
	for file: String in all_files:
		if file.begins_with("."):
			continue
		var ext := file.get_extension()
		if ext in SHADOWED_BY:
			var descriptor_ext: String = SHADOWED_BY[ext]
			var descriptor := file.get_basename() + "." + descriptor_ext
			if descriptor in all_files and (extensions.is_empty() or descriptor_ext in extensions):
				continue  # hidden — the .cue/.ccd/.mds entry covers it
		if not extensions.is_empty() and ext not in extensions:
			continue
		var full_path := dir_path.path_join(file)
		results.append({"path": full_path, "label": file.get_basename()})

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Return the scraped manual path (in media/manual/ directory).
## Prefers .pdf; falls back to .cbz; returns .pdf path if neither exists.
static func scraped_manual_path(systemid: String, romname: String) -> String:
	var base := romname.get_basename()
	var dir := rom_dir_for_system(systemid).path_join("media/manual")
	for ext in ["pdf", "cbz"]:
		var path := dir.path_join(base + "." + ext)
		if FileAccess.file_exists(path):
			return path
	return dir.path_join(base + ".pdf")


## Root directory for books (PDFs).
## Sits alongside the roms/ folder in the same files root.
static func default_books_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retrovr/files/books"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retrovr/books"


## Create the books root if it doesn't already exist.
static func ensure_books_root() -> void:
	var path := default_books_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured books root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create books root '%s' (err %d)" % [path, err])


## Scan the books root and return all PDF files sorted by name.
## Returns Array of {path: String, label: String}.
static func scan_books() -> Array[Dictionary]:
	var dir_path := default_books_root()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var ext := fname.get_extension().to_lower()
		if not dir.current_is_dir() and (ext == "pdf" or ext == "cbz"):
			results.append({"path": dir_path.path_join(fname), "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results
