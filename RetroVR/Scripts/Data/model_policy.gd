## RetroModelPolicy — the one switch between shipping the licensed hardware
## models and shipping the store-safe stand-ins.
##
## The detailed console and handheld shells are imported-derived and replicate real
## hardware trade dress, so they cannot go out the door until the licence lands.
## Until then every build is one of two shapes:
##
##   licensed    (dev)   — every bespoke model exactly as authored: the baked
##                         "Shell" subtrees and the imported-assets/ GLBs.
##   placeholder (store) — consoles fall back to the generic grey box
##                         (default_model.gd + the SystemBody mesh already in
##                         system.tscn); handhelds KEEP their device scene,
##                         because that scene also owns the live screen and the
##                         on-device controls, and swap only the shell for their
##                         primitive stand-in.
##
## Three ways to ask for placeholder mode, highest priority first:
##
##   1. `--placeholder-models` on the command line (and `--licensed-models` to
##      force the other way). This is what the validation probes flip: it works
##      in a plain editor run with every GLB still sitting on disk, so the
##      store-safe path can be exercised without doing an export first.
##   2. The `placeholder_models` custom feature tag on the export preset — how a
##      real store build selects it, since there is no command line there.
##   3. The `retrovr/models/placeholder_models` project setting.
##
## With none of them set the answer is "licensed", so day-to-day development in
## the editor is unchanged.
##
## NOTE this switch governs which models are USED. Keeping them out of the
## shipped .pck is the export preset's job (exclude_filter) — see the header
## comment in export_presets.cfg for which files still have to be excluded, and
## why excluding imported-assets/ alone is not enough.
class_name RetroModelPolicy
extends RefCounted

## Custom feature tag set on the store export preset.
const FEATURE_TAG := "placeholder_models"
## Project setting checked last, for flipping the whole editor into store mode.
const SETTING := "retrovr/models/placeholder_models"
const ARG_PLACEHOLDER := "--placeholder-models"
const ARG_LICENSED := "--licensed-models"

# Resolved once: OS.get_cmdline_args() and the feature tags cannot change for
# the life of the process, and this is called on every system spawn.
static var _resolved := false
static var _placeholder := false


## True when this build must not use the licensed hardware models.
static func placeholder_models() -> bool:
	if not _resolved:
		_placeholder = _resolve()
		_resolved = true
	return _placeholder


## True when the licensed hardware models may be used (the inverse; reads better
## at most call sites).
static func licensed_models() -> bool:
	return not placeholder_models()


## True when a licensed model at `path` may be used by this build — i.e. this is
## a licensed build AND the asset actually shipped.
##
## Use this instead of a bare ResourceLoader.exists() at every point that reaches
## into imported-assets/. Those two conditions used to be conflated: the props
## (cartridges, memory cards, controller plugs) all had perfectly good procedural
## stand-ins, but they were only reachable on a build where the GLB was missing,
## so `--placeholder-models` in the editor still loaded the licensed model and
## quietly failed to exercise them.
static func may_use(path: String) -> bool:
	return licensed_models() and not path.is_empty() and ResourceLoader.exists(path)


## One-line summary for logs and probe output.
static func describe() -> String:
	return "placeholder (store-safe stand-ins)" if placeholder_models() else "licensed (detailed shells)"


static func _resolve() -> bool:
	# Both halves of the command line: engine args, and anything after a bare
	# "--" (which is where `godot --path X scene.tscn -- --placeholder-models`
	# puts it).
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	# Explicit "use the real models" wins, so a dev build can override a project
	# setting without editing it.
	if args.has(ARG_LICENSED):
		return false
	if args.has(ARG_PLACEHOLDER):
		return true
	if OS.has_feature(FEATURE_TAG):
		return true
	var setting: Variant = ProjectSettings.get_setting(SETTING, false)
	return bool(setting)
