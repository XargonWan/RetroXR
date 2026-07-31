## SystemAssetCatalog — the support archives libretro publishes for cores that
## need more than a BIOS to run.
##
## buildbot.libretro.com/assets/system/ hosts one zip per core, each extracting
## to a top-level folder that matches the prefix that core's .info firmware
## paths use ("PPSSPP/", "scummvm/", "dolphin-emu/"). Unpacked into the core's
## system dir, an archive therefore satisfies its declared rows directly — no
## per-file mapping needed.
##
## Verified against the live listing 2026-07-30: the archives carry everything
## redistributable and stop exactly at console BIOSes. Dolphin.zip supplies the
## required codehandler.bin but none of the three GameCube IPL dumps; LRPS2.zip
## supplies GameIndex.yaml but not the PS2 bios folder. Those stay the user's
## to provide, which is the correct split.
class_name SystemAssetCatalog


const BASE_URL := "https://buildbot.libretro.com"
const BASE_PATH := "/assets/system/"

## core_name -> { zip, label, bytes, marker }.
##
## `bytes` is the size measured from the live listing; it only sizes the button
## label, so being slightly stale is harmless.
##
## `marker` is a shallow file the archive always carries, relative to the system
## dir. Its presence is what tells us the archive has been unpacked — that is
## not derivable from the firmware rows, because several archives can never
## satisfy all of them (Dolphin.zip has one of dolphin's four declared files and
## never the three GameCube IPL dumps). Reading it off disk also recognises an
## archive unpacked by hand, or before this tab existed.
## Read from each archive's listing 2026-07-30.
const ARCHIVES := {
	"ppsspp":          {"zip": "PPSSPP.zip",                     "label": "PPSSPP assets",           "bytes": 10863516, "marker": "PPSSPP/compat.ini"},
	"scummvm":         {"zip": "ScummVM.zip",                    "label": "ScummVM themes + extras", "bytes": 79563252, "marker": "scummvm/extra/mm.dat"},
	"dolphin":         {"zip": "Dolphin.zip",                    "label": "Dolphin Sys folder",      "bytes": 3191036,  "marker": "dolphin-emu/license.txt"},
	"dolphin_launcher":{"zip": "Dolphin.zip",                    "label": "Dolphin Sys folder",      "bytes": 3191036,  "marker": "dolphin-emu/license.txt"},
	"pcsx2":           {"zip": "LRPS2.zip",                      "label": "PCSX2 resources",         "bytes": 319638,   "marker": "pcsx2/resources/GameIndex.yaml"},
	"bluemsx":         {"zip": "blueMSX.zip",                    "label": "blueMSX machines",        "bytes": 4465709,  "marker": "Databases/svidb.xml"},
	"mame2003":        {"zip": "MAME 2003.zip",                  "label": "MAME 2003 support",       "bytes": 994060,   "marker": "mame2003/cheat.dat"},
	"mame2003_plus":   {"zip": "MAME 2003-Plus.zip",             "label": "MAME 2003-Plus support",  "bytes": 2628894,  "marker": "mame2003-plus/cheat.dat"},
	"fbneo":           {"zip": "FinalBurn Neo (hiscore).zip",    "label": "FinalBurn Neo hiscore",   "bytes": 81898,    "marker": "fbneo/hiscore.dat"},
	"prboom":          {"zip": "PrBoom.zip",                     "label": "PrBoom data",             "bytes": 45018,    "marker": "prboom.wad"},
	"nxengine":        {"zip": "NXEngine (Cave Story).zip",      "label": "Cave Story data",         "bytes": 1101902,  "marker": "nxengine/Readme.txt"},
	"ecwolf":          {"zip": "ECWolf.zip",                     "label": "ECWolf data",             "bytes": 173151,   "marker": "ecwolf.pk3"},
	"dinothawr":       {"zip": "Dinothawr.zip",                  "label": "Dinothawr game data",     "bytes": 5763199,  "marker": "dinothawr/LICENSE"},
	"qemu":            {"zip": "QEMU.zip",                       "label": "QEMU firmware",           "bytes": 18089404, "marker": "qemu/README"},
	"dirksimple":      {"zip": "DirkSimple.zip",                 "label": "DirkSimple data",         "bytes": 175384,   "marker": "DirkSimple/LICENSE.txt"},
	"cannonball":      {"zip": "Cannonball (ROMs Required).zip", "label": "Cannonball data",         "bytes": 3741,     "marker": "cannonball/roms.txt"},
	"xrick":           {"zip": "XRick (Rick Dangerous).zip",     "label": "XRick data",              "bytes": 1456338,  "marker": "xrick/data.zip"},
}


## Has this core's support archive already been unpacked into its system dir?
static func is_installed(core_name: String) -> bool:
	var a := archive_for(core_name)
	if a.is_empty():
		return false
	var marker := str(a.get("marker", ""))
	if marker.is_empty():
		return false
	return FileAccess.file_exists(
		CoreDownloadManager.default_system_dir(core_name).path_join(marker))


static func has_archive(core_name: String) -> bool:
	return ARCHIVES.has(core_name)


static func archive_for(core_name: String) -> Dictionary:
	return ARCHIVES.get(core_name, {})


## Path component of the download URL. Zip names carry spaces and parentheses
## ("MAME 2003-Plus.zip"), so they must be percent-encoded.
static func archive_path(core_name: String) -> String:
	var a := archive_for(core_name)
	if a.is_empty():
		return ""
	return BASE_PATH + str(a["zip"]).uri_encode()


## "ScummVM themes + extras (75.9 MB)" — the size belongs on the button, since
## these run from 3.7 KB to 79 MB and one of them is worth warning about.
static func button_label(core_name: String) -> String:
	var a := archive_for(core_name)
	if a.is_empty():
		return ""
	return "%s (%s)" % [a["label"], String.humanize_size(int(a["bytes"]))]
