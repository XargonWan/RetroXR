## ScreenscraperSystems — maps project systemid strings to screenscraper.fr numeric systemeid values.
class_name ScreenscraperSystems
extends RefCounted


## Mapping from project systemid → screenscraper systemeid.
## Source: https://www.screenscraper.fr/webapi2.php (system list)
const SYSTEM_MAP := {
	"3do": 29,
	"3ds": 17,
	"apple_ii": 86,
	"arcadia": 94,
	"atari_2600": 26,
	"atari_5200": 40,
	"atari_7800": 41,
	"atari_jaguar": 27,
	"atari_lynx": 28,
	"atari_st": 42,
	"cdi": 133,
	"channel_f": 80,
	"colecovision": 48,
	"commodore_amiga": 64,
	"commodore_c64": 66,
	"commodore_c128": 263,
	"commodore_vic20": 73,
	"cpc": 65,
	"dos": 135,
	"dreamcast": 23,
	"fb_alpha": 75,
	"game_boy": 9,
	"game_boy_advance": 12,
	"game_gear": 21,
	"gamecube": 13,
	# Screenscraper has no generic handheld-electronic platform, only Nintendo's
	# Game & Watch. A Tiger or Acclaim title reaches it as a name search and
	# usually misses, which costs it art rather than giving it the wrong art.
	"handheld_electronic": 52,
	"intellivision": 115,
	"mame": 75,
	"master_system": 2,
	"mega_drive": 1,
	"mega_duck": 90,
	"msx": 113,
	"nds": 15,
	"neo_geo_pocket": 25,
	"neogeo": 142,
	"nes": 3,
	"nintendo_64": 14,
	"odyssey2": 104,
	"pc_88": 221,
	"pc_98": 208,
	"pc_engine": 31,
	"pc_fx": 72,
	"pico8": 234,
	"playstation": 57,
	"playstation2": 58,
	"playstation_portable": 61,
	"pokemon_mini": 211,
	"scummvm": 123,
	"sega_cd": 20,
	"sega_saturn": 22,
	"sharp_x1": 220,
	"sharp_x68000": 79,
	"super_nes": 4,
	"supervision": 207,
	"ti_83": 205,
	"tic80": 222,
	"uzebox": 216,
	"vectrex": 102,
	"virtual_boy": 11,
	"wonderswan": 45,
	"zx81": 77,
	"zx_spectrum": 76,
}


## Returns the screenscraper systemeid for a project systemid, or -1 if unmapped.
static func get_systemeid(systemid: String) -> int:
	return SYSTEM_MAP.get(systemid, -1)
