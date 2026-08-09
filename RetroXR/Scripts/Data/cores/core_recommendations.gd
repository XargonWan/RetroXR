## CoreRecommendations — the one core we suggest per system, badged in the Cores
## downloader and manager and sorted to the top of that system's list.
##
## Keyed by systemid rather than a flat set of core names: the same core can be
## the right pick for one machine and a poor one for another (the Mednafen family
## serves a dozen systems at very different quality), so a global "good cores"
## list would badge them everywhere.
##
## These are opinions formed by running the cores on this hardware — add an entry
## only after testing it, and put the reason in `why` so it can be shown or
## argued with later.
class_name CoreRecommendations
extends RefCounted

const RECOMMENDED := {
	"3ds": {
		"core": "azahar",
		"why":  "The only 3DS core that emits side-by-side stereo, which the n3ds model's screen rects rely on",
	},
	# Both Dolphin systems point at the same core, and the recommendation is
	# really about WHICH BUILD: CoreSources replaces the buildbot's Dolphin with
	# our fork, which is the only one that can do Wiimote IR passthrough. On the
	# stock build a Wii Remote still points, but by a constant fitted per game.
	"gamecube": {
		"core": "dolphin",
		"why":  "The only GameCube core here, and the retroXR build adds the Wiimote IR passthrough a Wii disc in this cabinet needs",
	},
	"wii": {
		"core": "dolphin",
		"why":  "The retroXR build takes the Wii Remote's aim from the real sensor bar in the room rather than a cursor position, which is what makes pointing land where you point",
	},
	"nintendo_64": {
		"core": "mupen64plus_next_gles3",
		"why":  "mupen64plus_next_gles2 runs at full speed on Quest but never draws a pixel — the gles3 build of the same core renders the same ROM correctly",
	},
	"playstation": {
		"core": "pcsx_rearmed",
		"why":  "Best speed-to-accuracy balance on Quest hardware",
	},
	"super_nes": {
		"core": "snes9x",
		"why":  "Drives the SNES Mouse, and runs full speed on Quest where bsnes does not",
	},
}


## The recommended core_name for a system, or "" when we have no opinion.
static func core_for(systemid: String) -> String:
	if not RECOMMENDED.has(systemid):
		return ""
	return str((RECOMMENDED[systemid] as Dictionary).get("core", ""))


static func is_recommended(systemid: String, core_name: String) -> bool:
	return not core_name.is_empty() and core_for(systemid) == core_name


## Why this system's core is the pick, or "" when there is no recommendation.
static func reason_for(systemid: String) -> String:
	if not RECOMMENDED.has(systemid):
		return ""
	return str((RECOMMENDED[systemid] as Dictionary).get("why", ""))


## Move the recommended entry to the front of a list of Dictionaries, leaving
## every other entry in the order it arrived. A partition rather than a
## sort_custom: Array.sort_custom is not stable, so ranking only by
## recommended-ness would shuffle the rest of the list arbitrarily.
static func first(systemid: String, entries: Array, key: String = "core_name") -> Array:
	var pick := core_for(systemid)
	if pick.is_empty():
		return entries
	var head: Array = []
	var tail: Array = []
	for e: Dictionary in entries:
		if str(e.get(key, "")) == pick:
			head.append(e)
		else:
			tail.append(e)
	return head + tail
