## SystemInfo — per-system hardware descriptor (one .tres per systemid under
## res://SystemInfo/). Records how many controller ports the real console has,
## how its games load (cartridge / disc tray / disc insert), whether a multitap
## accessory applies, and — eventually — a custom hardware model scene.
##
## The MediaType enum values intentionally match MediaDimensions.LOADER_* so the
## loader mechanic (tray lid vs front slot vs no loader) and this descriptor
## never disagree. Look one up with SystemInfo.for_system("nes").
class_name SystemInfo
extends Resource

## Games load from a cartridge, a lidded disc tray (PS1/GameCube), or a front
## disc slot (PS2/PSP UMD). Values match MediaDimensions.LOADER_NONE/TRAY/SLOT.
enum MediaType { CARTRIDGE = 0, DISC_TRAY = 1, DISC_INSERT = 2 }

## Project systemid (e.g. "nes"); the filename stem of this resource.
@export var systemid: String = ""

## Human-readable console name for UI.
@export var display_name: String = ""

## Controller ports built into the console itself (before any multitap). Drives
## how many port snap-zones the cabinet exposes.
@export var native_ports: int = 2

## How this system's games are loaded.
@export var media_type: MediaType = MediaType.CARTRIDGE

## True when this hardware saves to a removable memory card rather than to the
## media itself. Shows the console's card slot, and makes the seated card — not
## the disc — decide which save image is mounted. With no card in, nothing
## persists, which is why the card slot and the save path are the same switch.
@export var memory_cards: bool = false

## True when a multitap accessory extended the console past its native ports.
@export var supports_multitap: bool = false

## Player ports a multitap exposes for this system (NES Four Score = 4,
## PC Engine = 5, PlayStation = 8…). Only meaningful when supports_multitap.
@export var multitap_ports: int = 4

## Home computer whose libretro core reads the mouse on port 0 and takes keyboard
## input globally (ScummVM, DOS, Amiga, C64, MSX…). When true a plugged mouse
## always drives libretro port 0 regardless of which cabinet slot it's in, and a
## plugged keyboard doesn't occupy a numbered port device (its keys are global to
## port 0 anyway) — so a mouse and a keyboard can be used at once. Consoles leave
## this false: their mouse peripherals stay on the port they're plugged into.
@export var computer: bool = false

## One game is a FOLDER, not a file (ScummVM). The content the core is handed is a
## small marker file sitting inside the game's data folder, so a flat scan of the
## system's rom dir sees only directories and reports an empty library. When true
## RomLibrary.scan_roms() descends one level and the folder name becomes the label.
## When true the marker is identified by the system's own core-declared
## supported_extensions, so no extension is recorded here.
@export var folder_content: bool = false

## Custom hardware model scene for this console. Empty for now — this is the
## slot the bespoke per-console models get dropped into later.
@export var console_model: PackedScene = null


static var _cache: Dictionary = {}

## Load the descriptor for a systemid, or null when none exists. Cached.
static func for_system(a_systemid: String) -> SystemInfo:
	if a_systemid.is_empty():
		return null
	if _cache.has(a_systemid):
		return _cache[a_systemid]
	var path := "res://SystemInfo/%s.tres" % a_systemid
	var info: SystemInfo = null
	if ResourceLoader.exists(path):
		info = ResourceLoader.load(path) as SystemInfo
	_cache[a_systemid] = info
	return info


## "cartridge" / "disc_tray" / "disc_insert" for logging and UI.
func media_type_name() -> String:
	match media_type:
		MediaType.DISC_TRAY:   return "disc_tray"
		MediaType.DISC_INSERT: return "disc_insert"
		_:                     return "cartridge"
