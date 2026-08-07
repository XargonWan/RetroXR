## RommPlatforms — maps RomM platform slugs to project systemids.
##
## RomM identifies a platform two ways: `slug` (IGDB-style, e.g. "genesis-slash-
## megadrive") and `fs_slug` (the folder name on the server, e.g. "megadrive").
## Either can appear, and users pick their own folder names, so the map below
## carries every alias worth recognising and lookup tries both.
##
## A systemid is required, not cosmetic: it decides cart-vs-disc
## (MediaDimensions.is_disc_system), physical size, and which 3D model spawns.
## Platforms that don't resolve are reported to the user rather than dropped, so
## they can add a RommConfig.platform_overrides entry.
##
## Mirrors the shape of screenscraper_systems.gd.
class_name RommPlatforms
extends RefCounted


## RomM slug (or fs_slug), lowercase → project systemid.
const SLUG_MAP := {
	# Nintendo
	"nes": "nes",
	"famicom": "nes",
	"fds": "nes",
	"snes": "super_nes",
	"sfc": "super_nes",
	"superfamicom": "super_nes",
	"snes-msu1": "super_nes",
	"satellaview": "super_nes",
	"sufami": "super_nes",
	"sgb": "super_nes",
	"sgb-msu1": "super_nes",
	"n64": "nintendo_64",
	"n64dd": "nintendo_64",
	"gb": "game_boy",
	"gb2players": "game_boy",
	# The project has no separate Game Boy Color systemid — gambatte reports
	# "game_boy" for both, and the cart shell is the same.
	"gbc": "game_boy",
	"gbc2players": "game_boy",
	"gba": "game_boy_advance",
	"nds": "nds",
	"3ds": "3ds",
	"gc": "gamecube",
	"gamecube": "gamecube",
	"triforce": "gamecube",
	"virtualboy": "virtual_boy",
	"pokemini": "pokemon_mini",

	# Sony
	"psx": "playstation",
	"ps": "playstation",
	"ps1": "playstation",
	"playstation": "playstation",
	"ps2": "playstation2",
	"playstation-2": "playstation2",
	"psp": "playstation_portable",

	# Sega
	"megadrive": "mega_drive",
	"megadrive-msu": "mega_drive",
	"msu-md": "mega_drive",
	"genesis": "mega_drive",
	"genesis-slash-megadrive": "mega_drive",
	"md": "mega_drive",
	"mastersystem": "master_system",
	"sms": "master_system",
	"saturn": "sega_saturn",
	"sega-saturn": "sega_saturn",
	"dreamcast": "dreamcast",
	"dc": "dreamcast",

	# Atari
	"atari2600": "atari_2600",
	"atari5200": "atari_5200",
	"atari7800": "atari_7800",
	"atarilynx": "atari_lynx",
	"lynx": "atari_lynx",
	"atarijaguar": "atari_jaguar",
	"jaguar": "atari_jaguar",
	"atarijaguarcd": "atari_jaguar",
	"jaguarcd": "atari_jaguar",
	"atarist": "atari_st",

	# NEC
	"pcengine": "pc_engine",
	"pce": "pc_engine",
	"pcenginecd": "pc_engine",
	"pcecd": "pc_engine",
	"supergrafx": "pc_engine",
	"turbografx-16-slash-pc-engine": "pc_engine",
	"pcfx": "pc_fx",
	"pc88": "pc_88",
	"pc80": "pc_88",
	"pc98": "pc_98",

	# SNK
	"neogeo": "neogeo",
	"neogeocd": "neogeo",
	"ngp": "neo_geo_pocket",
	"ngpc": "neo_geo_pocket",

	# Bandai / Watara / other handhelds
	"wonderswan": "wonderswan",
	"wswan": "wonderswan",
	"wonderswancolor": "wonderswan",
	"wswanc": "wonderswan",
	"supervision": "supervision",
	"megaduck": "mega_duck",

	# Consoles, misc
	"3do": "3do",
	"cdi": "cdi",
	"cdimono1": "cdi",
	"channelf": "channel_f",
	"fairchild-channel-f": "channel_f",
	"colecovision": "colecovision",
	"coleco": "colecovision",
	"intellivision": "intellivision",
	"odyssey2": "odyssey2",
	"o2em": "odyssey2",
	"videopac": "odyssey2",
	"videopacplus": "odyssey2",
	"vectrex": "vectrex",
	"arcadia": "arcadia",
	"uzebox": "uzebox",

	# Arcade
	"arcade": "mame",
	"mame": "mame",
	"mame-libretro": "mame",
	"mame-advmame": "mame",
	"mame-mame4all": "mame",
	"naomi": "mame",
	"naomi2": "mame",
	"atomiswave": "mame",
	"model3": "mame",
	"fba": "fb_alpha",
	"fbneo": "fb_alpha",

	# Computers
	"c64": "commodore_c64",
	"commodore-64": "commodore_c64",
	"c128": "commodore_c128",
	"c20": "commodore_vic20",
	"amiga": "commodore_amiga",
	"amiga500": "commodore_amiga",
	"amiga1200": "commodore_amiga",
	"amigacd32": "commodore_amiga",
	"amigacdtv": "commodore_amiga",
	"amstradcpc": "cpc",
	"cpc": "cpc",
	"gx4000": "cpc",
	"zxspectrum": "zx_spectrum",
	"zx-spectrum": "zx_spectrum",
	"spectrum": "zx_spectrum",
	"zx81": "zx81",
	"msx": "msx",
	"msx1": "msx",
	"msx2": "msx",
	"msx2+": "msx",
	"msxturbor": "msx",
	"x68000": "sharp_x68000",
	"x1": "sharp_x1",
	"apple2": "apple_ii",
	"dos": "dos",
	"pc": "dos",

	# Engines / fantasy consoles
	"scummvm": "scummvm",
	"pico8": "pico8",
	"tic80": "tic80",
}


## Resolve a RomM platform object to a project systemid, or "" when unmapped.
##
## Precedence: explicit user override (by either slug), then fs_slug, then slug.
## fs_slug beats slug because it's the folder the user named themselves — it may
## already BE our systemid (e.g. a folder literally called "super_nes").
static func systemid_for(platform: Dictionary, overrides: Dictionary = {}) -> String:
	var slug_v: Variant = platform.get("slug")
	var fs_v: Variant = platform.get("fs_slug")
	var slug := ("" if slug_v == null else str(slug_v)).to_lower().strip_edges()
	var fs_slug := ("" if fs_v == null else str(fs_v)).to_lower().strip_edges()

	for key: String in [slug, fs_slug]:
		if not key.is_empty() and overrides.has(key):
			return str(overrides[key])

	for key: String in [fs_slug, slug]:
		if key.is_empty():
			continue
		if SLUG_MAP.has(key):
			return str(SLUG_MAP[key])

	return ""


## Display name for a platform, preferring RomM's own resolved label.
static func display_name(platform: Dictionary) -> String:
	for key: String in ["display_name", "custom_name", "name", "slug"]:
		var v := str(platform.get(key, "")).strip_edges()
		if not v.is_empty():
			return v
	return "Unknown platform"


## Split a /api/platforms response into mapped and unmapped.
## Returns {mapped: Array[Dictionary], unmapped: Array[Dictionary]} where each
## mapped entry gains a "systemid" key. Platforms with no ROMs are dropped —
## an empty platform is noise in both lists.
static func partition(platforms: Array, overrides: Dictionary = {}) -> Dictionary:
	var mapped: Array[Dictionary] = []
	var unmapped: Array[Dictionary] = []

	for p: Dictionary in platforms:
		# rom_count can arrive as JSON null; Dictionary.get()'s default only
		# covers an absent key, and int(null) is a hard error.
		var count: Variant = p.get("rom_count")
		if count == null or int(count) <= 0:
			continue
		var sid := systemid_for(p, overrides)
		if sid.is_empty():
			unmapped.append(p)
		else:
			var entry := p.duplicate()
			entry["systemid"] = sid
			mapped.append(entry)

	return {"mapped": mapped, "unmapped": unmapped}
