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

## core_name -> { zip, label, marker }.
##
## No size is recorded. buildbot rebuilds these archives in place, so any byte
## count written here is wrong the moment it lands; the server states the size
## on every request and that is the only figure anything uses.
##
## `marker` is a shallow file the archive always carries, relative to the system
## dir. Its presence is what tells us the archive has been unpacked — that is
## not derivable from the firmware rows, because several archives can never
## satisfy all of them (Dolphin.zip has one of dolphin's four declared files and
## never the three GameCube IPL dumps). Reading it off disk also recognises an
## archive unpacked by hand, or before this tab existed.
## Read from each archive's listing 2026-07-30.
const ARCHIVES := {
	"ppsspp":          {"zip": "PPSSPP.zip",                     "label": "PPSSPP assets",           "marker": "PPSSPP/compat.ini"},
	"scummvm":         {"zip": "ScummVM.zip",                    "label": "ScummVM themes + extras", "marker": "scummvm/extra/mm.dat"},
	"dolphin":         {"zip": "Dolphin.zip",                    "label": "Dolphin Sys folder",      "marker": "dolphin-emu/license.txt"},
	"dolphin_launcher":{"zip": "Dolphin.zip",                    "label": "Dolphin Sys folder",      "marker": "dolphin-emu/license.txt"},
	"pcsx2":           {"zip": "LRPS2.zip",                      "label": "PCSX2 resources",         "marker": "pcsx2/resources/GameIndex.yaml"},
	"bluemsx":         {"zip": "blueMSX.zip",                    "label": "blueMSX machines",        "marker": "Databases/svidb.xml"},
	"mame2003":        {"zip": "MAME 2003.zip",                  "label": "MAME 2003 support",       "marker": "mame2003/cheat.dat"},
	"mame2003_plus":   {"zip": "MAME 2003-Plus.zip",             "label": "MAME 2003-Plus support",  "marker": "mame2003-plus/cheat.dat"},
	"fbneo":           {"zip": "FinalBurn Neo (hiscore).zip",    "label": "FinalBurn Neo hiscore",   "marker": "fbneo/hiscore.dat"},
	"prboom":          {"zip": "PrBoom.zip",                     "label": "PrBoom data",             "marker": "prboom.wad"},
	"nxengine":        {"zip": "NXEngine (Cave Story).zip",      "label": "Cave Story data",         "marker": "nxengine/Readme.txt"},
	"ecwolf":          {"zip": "ECWolf.zip",                     "label": "ECWolf data",             "marker": "ecwolf.pk3"},
	"dinothawr":       {"zip": "Dinothawr.zip",                  "label": "Dinothawr game data",     "marker": "dinothawr/LICENSE"},
	"qemu":            {"zip": "QEMU.zip",                       "label": "QEMU firmware",           "marker": "qemu/README"},
	"dirksimple":      {"zip": "DirkSimple.zip",                 "label": "DirkSimple data",         "marker": "DirkSimple/LICENSE.txt"},
	"cannonball":      {"zip": "Cannonball (ROMs Required).zip", "label": "Cannonball data",         "marker": "cannonball/roms.txt"},
	"xrick":           {"zip": "XRick (Rick Dangerous).zip",     "label": "XRick data",              "marker": "xrick/data.zip"},
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


## These run from 3.7 KB to 79 MB, and the size is worth knowing before you
## commit to one — but only the server can state it, so the download reports it
## in its toast rather than the button carrying a number that rots.
static func button_label(core_name: String) -> String:
	var a := archive_for(core_name)
	if a.is_empty():
		return ""
	return str(a["label"])
