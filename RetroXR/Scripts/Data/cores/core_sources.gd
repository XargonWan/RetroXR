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
		# The release this app was built knowing about. NOT part of the download
		# URL — see base_url. It is only the version to show when GitHub cannot be
		# reached, so an offline player still sees something truthful rather than
		# a blank.
		"known_tag": "retroxr-dolphin-libretro-v3",
		"label": "Dolphin (retroXR build)",
		# Per platform, because we only publish what we build. A platform absent
		# here is not an error — the manager falls back to the buildbot for it,
		# which is why Linux players still get a working Dolphin.
		"assets": {
			"Windows": "dolphin_libretro.dll.zip",
			"Android": "dolphin_libretro_android.so.zip",
		},
	},
	# Azahar, for the same shape of reason. The 3DS renders two eyes and always
	# did — Settings::values.render_3d and factor_3d were honoured all the way
	# down to the renderer — but the libretro glue was the one place that never
	# surfaced them, so no frontend could ask for a side-by-side frame. Without
	# that a 3DS in this room is flat, which is the one thing a 3DS is not.
	#
	# Upstream has the change as an open pull request (azahar-emu/azahar#2339).
	# When it merges this entry can go, and the buildbot's build will do.
	#
	# Note the asset has no "_android" infix: azahar's CMake never set an Android
	# OUTPUT_NAME, so its Android core is plain azahar_libretro.so and it is the
	# only one on the buildbot like that. core_lib_suffixes() already accepts
	# both spellings for exactly this core.
	"azahar": {
		"repo":  "XenuIsWatching/azahar",
		"known_tag": "retroxr-azahar-libretro-v1",
		"label": "Azahar (retroXR build)",
		"assets": {
			"Windows": "azahar_libretro.dll.zip",
			"Android": "azahar_libretro.so.zip",
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
##
## Deliberately the /releases/latest/ form and NOT a tagged one. A tag in here
## would mean every new core build needed a new app build to point at it, and an
## installed copy of retroXR could never be given a fixed core — which is the
## whole point of having a download manager. GitHub resolves `latest` to the
## newest non-prerelease release, so publishing a build is enough to ship it.
##
## The consequence to know: `latest` is per REPOSITORY, not per product. A
## release cut on that fork for anything other than a core build would capture
## this URL. Mark such releases as pre-releases — GitHub's `latest` skips those.
static func base_url(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://github.com/%s/releases/latest/download/" % src.get("repo", "")


## Where to ASK what the newest build is called. A stable download URL is only
## half of shipping updates: the manager decides whether to offer one by
## comparing versions, so without this the app would keep fetching whatever is
## latest while insisting the player is already up to date.
static func api_url(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://api.github.com/repos/%s/releases/latest" % src.get("repo", "")


## Stands in for the buildbot's timestamp. The download manager only ever tests
## it for INEQUALITY against what the manifest stored, to decide whether to offer
## an update — so a release tag serves as well as a date, and unlike a date it
## only changes when the build does.
##
## This is the fallback; the live value comes from api_url.
static func version_of(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	return str(src.get("known_tag", ""))


static func label_for(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	return str(src.get("label", ""))


## The human-readable page, for a player who wants to see what they are about to
## install before they install it. Also the `latest` form, for the same reason.
static func release_page(core_name: String) -> String:
	var src: Dictionary = SOURCES.get(core_name, {})
	if src.is_empty():
		return ""
	return "https://github.com/%s/releases/latest" % src.get("repo", "")


## Core names we publish AND build for this platform, for callers that need to
## walk them (the version probe).
static func active_core_names() -> Array[String]:
	var out: Array[String] = []
	for core_name: Variant in SOURCES:
		if has(str(core_name)):
			out.append(str(core_name))
	return out
