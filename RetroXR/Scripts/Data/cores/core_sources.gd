## CoreSources — cores retroXR ships itself, instead of taking from the buildbot.
##
## Almost every core comes from buildbot.libretro.com and needs nothing here. A
## core lands in this table when we maintain a fork of it, because then the
## buildbot's build is not the one we want the player to have.
##
## Right now that is Dolphin. The buildbot build cannot do Wiimote IR
## passthrough — the frontend hands the emulated camera its real view of the
## sensor bar rather than a cursor position, and the option that switches it on
## only exists in our fork. Without it a Wii Remote in this room points by a
## constant fitted per game; with it, it points where you point.
##
## The binary is published on the fork it was built from, which is also what
## keeps it honest: Dolphin is GPLv2+, so the source for a distributed binary has
## to be there beside it, and a release tag on the source repo is the simplest
## arrangement that stays true.
##
## Deliberately keyed by the SAME core_name the buildbot uses ("dolphin", not
## "dolphin_retroxr"). The frontend derives system/<core> and save/<core> from
## that name, so a new one would strand the Sys folder, every GameCube memory
## card and the whole Wii NAND. Ours replaces the stock build in place and
## inherits all of it.
class_name CoreSources
extends RefCounted


const SOURCES := {
	"dolphin": {
		"repo":  "XenuIsWatching/dolphin",
		"tag":   "retroxr-dolphin-libretro-v1",
		"label": "Dolphin (retroXR build)",
		# Per platform, because we only publish what we build. A platform absent
		# here is not an error — the manager falls back to the buildbot for it,
		# which is why Linux players still get a working Dolphin.
		"assets": {
			"Windows": "dolphin_libretro.dll.zip",
			"Android": "dolphin_libretro_android.so.zip",
		},
	},
}


## True when we publish this core ourselves AND have a build for this platform.
## Both halves matter: the Linux answer is "we know this core, but not here".
static func has(core_name: String) -> bool:
	return not asset_for(core_name).is_empty()


## The release asset filename for this platform, or "" when we do not build one.
static func asset_for(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return str((src.get("assets", {}) as Dictionary).get(OS.get_name(), ""))


## Directory URL the asset hangs off, shaped like the buildbot's so the download
## manager can concatenate a filename onto either without caring which it has.
static func base_url(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://github.com/%s/releases/download/%s/" % [src.get("repo", ""), src.get("tag", "")]


## Stands in for the buildbot's timestamp. The download manager only ever tests
## it for INEQUALITY against what the manifest stored, to decide whether to offer
## an update — so a release tag serves as well as a date, and unlike a date it
## only changes when the build does.
static func version_of(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	return str(src.get("tag", ""))


static func label_for(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	return str(src.get("label", ""))


## The human-readable page, for a player who wants to see what they are about to
## install before they install it.
static func release_page(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://github.com/%s/releases/tag/%s" % [src.get("repo", ""), src.get("tag", "")]
