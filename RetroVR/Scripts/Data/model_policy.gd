## RetroModelPolicy — the one switch between the store-safe stand-in models and
## the detailed hardware models we do not yet have a licence for.
##
## The detailed console, handheld and controller models replicate real hardware
## trade dress and no licence has been granted for them, so they cannot go out
## the door. Every build is one of two shapes, and the SAFE one is the default:
##
##   placeholder (default) — consoles use the generic grey box
##                           (default_model.gd + system.tscn's SystemBody);
##                           handhelds KEEP their device scene, because it also
##                           owns the live screen and the on-device controls, and
##                           wear their primitive stand-in shell; every bespoke
##                           controller spawns the procedural RetroPad; carts,
##                           memory cards and plug connectors keep their
##                           procedural stand-ins.
##   unbundled (opt-in)   — the detailed models as authored. FOR DEVELOPMENT AND
##                           TESTING ONLY. Never ship a build in this shape.
##
## Nothing has to be remembered or set to get a shippable build: do nothing and
## you get placeholder. Reaching for the unbundled models is always an explicit,
## deliberate act, and it is named after what it is.
##
## Three ways to ask for them, highest priority first:
##
##   1. `--unbundled-models` on the command line. This is the everyday one — it
##      works in a plain editor run, so a dev can see the real hardware without
##      changing any project state. (`--placeholder-models` forces the default
##      back, e.g. to override the project setting below.)
##   2. The `unbundled_models` custom feature tag on an export preset — how a
##      dev/test BUILD gets them, since there is no command line there. Only the
##      "Quest (Dev - unbundled models)" preset sets it.
##   3. The `retrovr/models/unbundled_models` project setting, for a dev who
##      wants the editor to stay in that mode without passing a flag every time.
##
## WHEN PROPERLY LICENSED MODELS ARRIVE they do not belong behind this switch at
## all: drop them into imported-assets/ as the normal, default-loaded models and
## let this class keep guarding only whatever is still unbundled. The placeholder
## path stays useful either way as the fallback for a system with no model yet.
##
## NOTE this switch governs which models are USED. Keeping the unbundled assets
## out of a shipped .pck is the export preset's job — they live under
## unbundled-models/, which the default preset excludes wholesale.
class_name RetroModelPolicy
extends RefCounted

## Custom feature tag that opts a BUILD into the unbundled models.
const FEATURE_TAG := "unbundled_models"
## Project setting that opts the editor into them.
const SETTING := "retrovr/models/unbundled_models"
const ARG_unbundled := "--unbundled-models"
const ARG_PLACEHOLDER := "--placeholder-models"

# Resolved once: OS.get_cmdline_args() and the feature tags cannot change for
# the life of the process, and this is called on every system spawn.
static var _resolved := false
static var _placeholder := true


## True when this build must use the stand-ins. The default.
static func placeholder_models() -> bool:
	if not _resolved:
		_placeholder = not _resolve_unbundled()
		_resolved = true
	return _placeholder


## True when the unbundled hardware models were explicitly asked for (dev/test).
static func unbundled_models() -> bool:
	return not placeholder_models()


## True when the unbundled model at `path` may be used by this build — i.e. it
## was explicitly asked for AND the asset actually shipped.
##
## Use this instead of a bare ResourceLoader.exists() at every point that reaches
## into unbundled-models/. Those two conditions used to be conflated: the props
## (cartridges, memory cards, controller plugs) all had perfectly good procedural
## stand-ins, but they were only reachable on a build where the asset was
## missing, so a placeholder run with the files still on disk quietly loaded the
## unbundled model and never exercised them.
static func may_use(path: String) -> bool:
	return unbundled_models() and not path.is_empty() and ResourceLoader.exists(path)


## One-line summary for logs and probe output.
static func describe() -> String:
	return "placeholder (store-safe stand-ins)" if placeholder_models() else "unbundled (detailed models - DEV ONLY)"


## Has anything explicitly asked for the unbundled models? Everything else — an
## unflagged run, an unflagged export, a fresh checkout — gets the stand-ins.
static func _resolve_unbundled() -> bool:
	# Both halves of the command line: engine args, and anything after a bare
	# "--" (which is where `godot --path X scene.tscn -- --unbundled-models`
	# puts it).
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	# An explicit "give me the safe models" wins over everything, so a run can
	# override the project setting without editing it.
	if args.has(ARG_PLACEHOLDER):
		return false
	if args.has(ARG_unbundled):
		return true
	if OS.has_feature(FEATURE_TAG):
		return true
	var setting: Variant = ProjectSettings.get_setting(SETTING, false)
	return bool(setting)
