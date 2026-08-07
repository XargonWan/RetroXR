## MediaDimensions — per-system physical media data (cartridge sizes, disc
## diameters) plus the scraped label-art loader shared by RetroCartridge and
## RetroDisc. Single source of truth for "which systems use discs" and how big
## each system's media is. Sizes are real-world approximations in metres.
class_name MediaDimensions
extends RefCounted

## Cartridge dimensions: systemid -> Vector3(width, height, thickness).
## Axes match cartridge.tscn (label faces +Z). Unlisted systems fall back to
## the generic scene size via cart_size().
const CART_SIZES: Dictionary = {
	"nes":              Vector3(0.109, 0.121, 0.017),
	"super_nes":        Vector3(0.137, 0.088, 0.020),
	"nintendo_64":      Vector3(0.116, 0.075, 0.020),
	"game_boy":         Vector3(0.057, 0.065, 0.008),
	"game_boy_advance": Vector3(0.058, 0.036, 0.007),
	"mega_drive":       Vector3(0.110, 0.070, 0.017),
	"atari_2600":       Vector3(0.079, 0.104, 0.021),
	"atari_5200":       Vector3(0.108, 0.104, 0.021),   # squarer, wider shell than the 2600 cart
	"virtual_boy":      Vector3(0.065, 0.054, 0.006),   # VB cart, measured off the model
	"nds":              Vector3(0.033, 0.035, 0.004),
	"3ds":              Vector3(0.033, 0.035, 0.004),   # 3DS Game Card = DS footprint
	"atari_lynx":       Vector3(0.073, 0.086, 0.006),   # Lynx card
	"game_gear":        Vector3(0.068, 0.047, 0.012),
	"wonderswan":       Vector3(0.048, 0.052, 0.008),
	"neo_geo_pocket":   Vector3(0.048, 0.052, 0.008),
	"nintendo_64dd":    Vector3(0.098, 0.079, 0.017),   # 64DD magnetic disk
	"pokemon_mini":     Vector3(0.022, 0.033, 0.007),
	"supervision":      Vector3(0.066, 0.070, 0.009),
	# UMD caddy — square footprint, thin. RetroUMD builds its shell straight off
	# this; without an entry it would fall back to CART_SIZE_DEFAULT (10x8 cm) and
	# hand out a caddy ~40% too big. Note the PSP appears in DISC_DIAMETERS too:
	# that is the bare platter sealed inside, this is the caddy you actually hold.
	"playstation_portable": Vector3(0.064, 0.064, 0.0042),
}

## Generic cartridge size (the original cartridge.tscn values) for systems
## without an entry above.
const CART_SIZE_DEFAULT := Vector3(0.10, 0.08, 0.015)

## Disc diameters: systemid -> diameter in metres. Doubles as the disc-system
## set — a systemid present here spawns a RetroDisc instead of a cartridge.
## (pc_engine stays a cartridge: its HuCard — the CD add-on is pc_engine_cd.
## neo_geo_cd has a systemid now but no descriptor yet.)
const DISC_DIAMETERS: Dictionary = {
	"playstation":           0.12,
	"playstation2":          0.12,
	"sega_saturn":           0.12,
	"sega_cd":               0.12,
	"pc_engine_cd":          0.12,
	"wii":                   0.12,
	"dreamcast":             0.12,
	"3do":                   0.12,
	"cdi":                   0.12,
	"pc_fx":                 0.12,
	"gamecube":              0.08,   # mini-DVD
	"playstation_portable":  0.064,  # UMD (bare disc, no caddy)
	# ScummVM is not console hardware — it stands in for a 90s PC, whose adventure
	# games shipped on CD-ROM. Listing it here is what makes the spawn menu hand
	# out a disc and RetroSystem take the tray path; the PC tower model then slides
	# that tray instead of hinging a lid.
	"scummvm":               0.12,
}

## Default disc diameter (standard CD/DVD) for a disc systemid without an entry.
const DISC_DIAMETER_DEFAULT := 0.12

## Disc loading mechanisms.
const LOADER_NONE := 0   # cartridge system — no disc loader
const LOADER_TRAY := 1   # lid/tray: OPEN button gates insert/remove (PS1, GameCube…)
const LOADER_SLOT := 2   # slot-load: disc injects on insert, EJECT slides it out (PS2)

## Systems that slot-load instead of using a lid/tray.
## NOTE: playstation2 was here (the fat PS2's front slot) but the console we model
## is the PS2 SLIM, which is top-loading (hinged disc cover) — so LOADER_TRAY.
## Slot-load = the disc injects on insert and the EJECT button slides it out
## (PS2). Everything else with a disc is a lid/tray (OPEN reveals a well). The
## PSP is a tray: its UMD sits behind a hinged door you flick open, not a slot.
const SLOT_LOAD_SYSTEMS: Dictionary = {
	# The one true slot-loader we model: the disc is drawn in and the
	# EJECT button spits it back out. No lid, no tray.
	"wii": true,
}

## Lid/tray systems whose tray SLIDES OUT THE FRONT instead of hinging open — the
## fat PS2, and any PC-style optical drive.
##
## Still LOADER_TRAY: MediaTray owns the gating, seating, spin and collision either
## way, and only the geometry and the button's word change. This is the same split
## RetroSystemModelPCTower already runs on with authored geometry — it keeps
## LOADER_TRAY and makes play_open/play_close a slide — so a system opting in here
## gets that motion built procedurally on the placeholder box instead.
const FRONT_TRAY_SYSTEMS: Dictionary = {
	"playstation2": true,
	# Model 1, the machine our icon draws — a motorised tray out of the front.
	# Model 2 is a hinged top lid, which is the other branch.
	"sega_cd": true,
}


## True when this system's tray slides out of the front face rather than hinging.
static func has_front_tray(systemid: String) -> bool:
	return FRONT_TRAY_SYSTEMS.has(systemid)


## True when the systemid's games ship on discs (spawn a RetroDisc).
static func is_disc_system(systemid: String) -> bool:
	return DISC_DIAMETERS.has(systemid)


## Cartridge body size for a system, or the generic default.
static func cart_size(systemid: String) -> Vector3:
	return CART_SIZES.get(systemid, CART_SIZE_DEFAULT)


## Disc diameter for a system, or the standard 12 cm.
static func disc_diameter(systemid: String) -> float:
	return float(DISC_DIAMETERS.get(systemid, DISC_DIAMETER_DEFAULT))


## How this system loads discs: LOADER_NONE / LOADER_TRAY / LOADER_SLOT.
static func disc_loader(systemid: String) -> int:
	if not DISC_DIAMETERS.has(systemid):
		return LOADER_NONE
	return LOADER_SLOT if SLOT_LOAD_SYSTEMS.has(systemid) else LOADER_TRAY


## Load the scraped "support" art (physical media label) for a ROM, or null.
## The scraper saves support-texture media to
## <roms_root>/<systemid>/media/label/<rom_basename>.<ext> (screenscraper_client
## download_all_media), named after the ROM file — mirror _load_wheel_texture.
static func load_label_texture(systemid: String, rom_path: String) -> Texture2D:
	if systemid.is_empty() or rom_path.is_empty():
		return null
	var base := rom_path.get_file().get_basename()
	if base.is_empty():
		return null
	var media_dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/label")
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path := media_dir.path_join(base + ext)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				return ImageTexture.create_from_image(img)
	return null
