## NetplayCores — allowlist of libretro cores verified safe for deterministic
## lockstep netplay, plus the deterministic options each one needs.
##
## A core only becomes netplay-capable once it has been vetted with
## Tools/netplay_spike.gd: savestate round-trip AND two cold-started processes
## must produce identical RAM-CRC streams. Cores not listed here fall back to
## the pre-netplay "LIVE on host" placeholder for remote peers.
##
## `options` are forced on every peer at cold start so a peer's local core-option
## config can't introduce divergence (e.g. threaded renderers, frameskip, RNG).
class_name NetplayCores
extends RefCounted

## core_name -> { verified: bool, systems: [systemid...], options: {key: value}, notes: String }
const CORES: Dictionary = {
	"fceumm": {
		"verified": true,
		"rollback": true,   # serialization is fast+small (13.7 KB) — per-frame savestates OK
		"systems": ["nes"],
		"options": {},   # SMB passed determinism with defaults
		"notes": "NES. Verified GREEN 2026-07-05 (savestate + cold-start cross-process CRC match; x64<->arm64 verified 2026-07-06).",
	},
	# Pending vetting with netplay_spike before they can be enabled:
	"snes9x": {
		"verified": false,
		"systems": ["super_nes"],
		"options": {},
		"notes": "SNES. Not yet spike-verified.",
	},
	"genesis_plus_gx": {
		"verified": false,
		"systems": ["megadrive", "genesis", "master_system", "game_gear"],
		"options": {},
		"notes": "Sega. Not yet spike-verified.",
	},
}


## True if the core is on the allowlist AND has passed determinism vetting.
static func is_capable(core_name: String) -> bool:
	var e: Dictionary = CORES.get(core_name, {})
	return bool(e.get("verified", false))


## Deterministic core options to force on every peer for this core (may be empty).
static func forced_options(core_name: String) -> Dictionary:
	var e: Dictionary = CORES.get(core_name, {})
	return (e.get("options", {}) as Dictionary).duplicate()


## True when the core supports rollback netplay: verified deterministic AND
## cheap enough to savestate every frame (rollback rewinds via a state ring).
static func rollback_capable(core_name: String) -> bool:
	var e: Dictionary = CORES.get(core_name, {})
	return bool(e.get("verified", false)) and bool(e.get("rollback", false))


static func notes(core_name: String) -> String:
	var e: Dictionary = CORES.get(core_name, {})
	return str(e.get("notes", ""))
