## Core option persistence, plus reading a core's option set without starting it.
##
## `<root>/core_options/<core>.opt` is the same file a running core loads at start
## and writes back on shutdown, so an edit made here is what the next launch sees.
## That makes it the meeting point for the two pre-launch editors — the system's
## own menu and the core manager — and for a running core's live changes.
class_name CoreOptionsStore
extends RefCounted


## Option keys the hardware models pin so their screens work at all — dual-screen
## layout, the 3DS depth slider, the Virtual Boy's stereo split. A reset must skip
## these or it restores a broken picture rather than a default one.
##
## The in-world panel asks the live model (RetroSystemModel.get_forced_core_options),
## which stays authoritative. The core manager has no system instance to ask and
## reads this instead, so keep it in step with n3ds_model.gd, nds_model.gd and
## virtual_boy_model.gd.
const HARDWARE_PINNED := {
	"citra_render_3d": true,
	"citra_layout_option": true,
	"citra_swap_screen": true,
	"citra_factor_3d": true,
	"melonds_touch_mode": true,
	"melonds_screen_layout": true,
	"melonds_screen_gap": true,
	"desmume_pointer_type": true,
	"desmume_screens_layout": true,
	"vb_3dmode": true,
	"vb_sidebyside_separation": true,
}


## Where option files live when a system has no core_directory of its own.
static func default_root() -> String:
	return CoreDownloadManager.default_core_root()


static func opt_dir(root: String) -> String:
	return root.path_join("core_options")


static func opt_path(root: String, core_name: String) -> String:
	return opt_dir(root).path_join(core_name + ".opt")


## Parse `<core>.opt` into {key: value}. Empty when nothing has been saved for
## this core yet, which is the normal state before its first launch.
static func load_values(root: String, core_name: String) -> Dictionary:
	var out: Dictionary = {}
	var path := opt_path(root, core_name)
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("CoreOptionsStore: cannot read %s" % path)
		return out
	for line: String in f.get_as_text().split("\n"):
		var eq := line.find("=")
		if eq > 0:
			out[line.substr(0, eq).strip_edges()] = \
				line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return out


## Write {key: value} back, creating the directory if needed.
static func save_values(root: String, core_name: String, values: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(opt_dir(root))
	var path := opt_path(root, core_name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("CoreOptionsStore: cannot write %s" % path)
		return false
	var keys: Array = values.keys()
	keys.sort()
	for k: String in keys:
		f.store_string("%s = \"%s\"\n" % [k, str(values[k])])
	return true


## Force a set of keys into the file, leaving every other key alone, and write
## only if something actually moved. Returns true when the file was rewritten.
##
## This is the shape a caller pinning options wants — a system pins what its
## shell demands before every launch — and having it here is what keeps one
## writer on the file. A caller that loaded, merged and wrote for itself had the
## same three steps with one difference: it did not sort the keys, so the file
## reshuffled depending on which writer touched it last.
static func merge_values(root: String, core_name: String, forced: Dictionary) -> bool:
	if forced.is_empty():
		return false
	var values := load_values(root, core_name)
	var changed := false
	for k: Variant in forced:
		var key := str(k)
		var val := str(forced[k])
		if values.get(key, null) != val:
			values[key] = val
			changed = true
	if not changed:
		return false
	return save_values(root, core_name, values)


## Set one key and persist, leaving every other key alone.
static func set_value(root: String, core_name: String, key: String, value: String) -> bool:
	var values := load_values(root, core_name)
	values[key] = value
	return save_values(root, core_name, values)


## Read a core's option definitions without starting it.
##
## Returns {"categories": {}, "definitions": {}, "values": {}} — the same shape as
## the Libretro node's options_ready signal, with each option at its core-declared
## default. Empty when the core cannot be read, or when it publishes nothing until
## content is loaded (fceumm is one; see `peek_failure_reason`).
##
## Costs a dlopen plus the core's static initialisers — about 150 ms for a core
## the size of azahar, so call it on a menu opening rather than per frame.
static func peek(root: String, core_name: String) -> Dictionary:
	if core_name.is_empty():
		return {}
	var node: Libretro = Libretro.new()
	var result: Dictionary = node.PeekCoreOptions(root, core_name)
	node.free()
	return result


## What to tell the player when peek() came back empty.
static func peek_failure_reason(root: String, core_name: String) -> String:
	if core_name.is_empty():
		return "No core is set for this system yet."
	if not FileAccess.file_exists(opt_path(root, core_name)):
		var cores_dir := root.path_join("cores")
		if not DirAccess.dir_exists_absolute(cores_dir):
			return "Core '%s' is not installed." % core_name
	return "'%s' only publishes its options once it has started.\nPower the system on to change them." % core_name


## Reset every option a core declares back to its own default, leaving the pinned
## ones at whatever the hardware set them to.
static func reset_to_defaults(root: String, core_name: String, peeked: Dictionary) -> bool:
	var defaults: Dictionary = peeked.get("values", {})
	var out: Dictionary = load_values(root, core_name)
	for key: String in defaults:
		if HARDWARE_PINNED.has(key):
			continue
		out[key] = defaults[key]
	return save_values(root, core_name, out)


## Merge a peeked option set with what is already saved, so the editor shows the
## values the core will actually boot with. Saved keys the core no longer declares
## are dropped — they cannot be represented in the UI and only confuse the core.
static func effective_values(peeked: Dictionary, saved: Dictionary) -> Dictionary:
	var defaults: Dictionary = peeked.get("values", {})
	var definitions: Dictionary = peeked.get("definitions", {})
	var out: Dictionary = defaults.duplicate()
	for key: String in saved:
		if definitions.has(key):
			out[key] = saved[key]
	return out
