# GBA

* the power light doesn't come on when it is turned on
* the power switch doesn't slide to on when it is slide
* the buttons don't seem to animate

# Core-Info Known Issues

As this is a submodule, we need to somehow upstream the issues we found

* There is an insconsistency with the `systemname` "C64" where the corrisponding `systemid` is called either "commodore_c64" or "commodore_64"
* Same inconsistency for the Amiga — `systemid` is either "commodore_amiga" or "amiga" depending on the core
* Cost of both: `SystemInfo.for_system()` resolves `res://SystemInfo/<systemid>.tres`, so each of these machines needs TWO identical `.tres` files or half the cores get the fallback descriptor (2 ports, cartridge) instead of the authored one. `RetroVR/SystemInfo/` is 60 files for 58 real systems because of it. Anything that counts or lists systems from that directory double-counts the C64 and the Amiga.
* Some systemids carry no usable `systemname` at all ("playstation_portable" comes back as the raw id). `CoreInfoDatabase._NAME_OVERRIDES` patches that one locally rather than editing the submodule

## Cores with no systemid at all

Found while looking for a Fairchild Channel F system (2026-08-01). 46 of the 306
`.info` files carry no `systemid` line; 13 of those are real emulators, the other 33
are single-game cores and players where it matters less.

`CoreInfoDatabase._rebuild_indices()` only indexes entries with a non-empty
`systemid`, so these cores are absent from `_by_systemid` entirely — not hidden by
`SystemFilter`, just never there. No tile, no `get_unique_systemids()` entry, no way
to reach them from any system-browsing UI. The core still downloads and runs; only
the discovery path is missing.

The 13, with the `database` name that should have become the systemid:

* `freechaf` — "Fairchild - Channel F"
* `gw` — "Handheld Electronic Game"
* `neocd` — "SNK - Neo Geo CD"
* `emuscv` — "Epoch - Super Cassette Vision"
* `freej2me` — "Mobile - J2ME"
* `simcp` — "SAM coupe"
* `theodore` — "Thomson - MOTO"
* `skyemu` — three databases (DS / Game Boy / GBA), so no single id fits
* `galaksija`, `mu`, `oberon`, `pcem`, `qemu` — no `database` either

Fixable locally the same way `_NAME_OVERRIDES` handles the missing systemnames: a
systemid override table keyed on `core_name`. Anything given an id also needs a
`res://SystemInfo/<systemid>.tres` or it takes the fallback descriptor.

## Sub-platforms are invisible — they exist only in `database`

A core declares ONE `systemid`, which is the parent machine. Every other platform it
emulates appears only in the `|`-separated `database` field, which nothing indexes.

`genesis_plus_gx` is `systemid = "mega_drive"` and
`database = "Sega - Game Gear|Sega - Master System - Mark III|Sega - Mega-CD - Sega
CD|Sega - Mega Drive - Genesis|Sega - PICO|Sega - SG-1000"`. Six machines, one id.
`picodrive` adds "Sega - 32X" on the same id.

Game Gear is the clearest casualty: five cores emulate it (`genesis_plus_gx`,
`genesis_plus_gx_wide`, `gearsystem`, `smsplus`, `picodrive`) and not one reports a
`game_gear` systemid — they say `mega_drive` or `master_system`. So there is no Game
Gear tile, no `SystemInfo/game_gear.tres`, and a GG cart can only be spawned wearing
a Master System or Mega Drive shell.

Across the corpus: **158 distinct `database` names against 132 distinct systemids**.

Not a data bug — the format has no way to express "this core covers N platforms" —
but it means `systemid` cannot be the whole story for what RetroVR can run. Giving a
sub-platform its own systemid is not free: core lookup keys off systemid, so a new
`game_gear` id would resolve to zero cores unless the lookup also learns that the
GG-capable cores serve it.

## Duplicate systemids for one machine

Found by grouping all 132 systemids by normalised `systemname` (2026-07-28). Same
failure mode as the C64/Amiga pair above — each one needs a duplicate `.tres`, and
each one shows up as two tiles in the Cores browser.

* **Philips CD-i** — `cdi` ("CD-i") and `cdi2015` ("CDi"). The names differ only in
  punctuation, so they don't even sort together
* **Intellivision** — `intellivision` and `intv`, both with the systemname
  "Intellivision". Two tiles with byte-identical labels
* **Cave Story** — `doukutsu-rs` and `nxengine`, both "Cave Story Game Engine".
  Defensible (two independent reimplementations) but indistinguishable in a list
* **ColecoVision** — `colecovision` vs `jollycv`
  ("ColecoVision/CreatiVision/My Vision"). jollycv is a multi-system core that took
  its own systemid instead of reusing `colecovision`

## Non-unique systemnames

Distinct machines are fine; these are cases where the `systemname` is not usable as
a label because several systemids share it verbatim.

* **"Arcade (various)"** is the systemname for FIVE systemids — `daphne`, `dice`,
  `fb_alpha`, `hbmame`, `mame`. The Cores browser renders five tiles reading
  "Arcade (various)" with nothing to tell them apart but the core count
* **"Music"** is shared by `game_music` (gme, chiptune/VGM) and `music` (pocketcdg,
  CD+G karaoke) — two unrelated players
* **"Game engine"** is `scummvm`'s systemname — generic where every other engine
  core names itself ("DOOM Game Engine", "Quake II Game Engine"). It reads as a
  category, not a system

Worth fixing locally in `CoreInfoDatabase._NAME_OVERRIDES` before upstreaming, since
the display name is what the browser tiles key off.

## Malformed firmware blocks

Found while building the BIOS / Extras tab (2026-07-30). Both are upstream data bugs,
not parser bugs.

* **`bk_libretro.info` has TWO `notes` lines** (61 and 62). A last-wins key/value
  parser — which is the obvious way to read this format, and what `CoreInfoParser`
  did — silently keeps only the second (`"(!) Homepage: …"`) and discards the first,
  which is the entire md5 checksum table for all 8 firmware files. Worked around in
  `CoreInfoParser.parse_info_file()` by joining duplicate `notes` on `"|"`, which is
  the format's own line separator. It is the only file in the 306 that does this;
  every other duplicated key (`supports_no_game`, `categories`, `display_version`)
  is genuinely single-valued and last-wins is correct for those.

* **`FreeIntvTSOverlay_libretro.info` misnumbers its second firmware entry.** It
  declares `firmware_count = 2`, then writes `firmware1_desc` followed by
  `firmware0_path` and `firmware0_opt` — so `grom.bin` overwrites `exec.bin`'s path
  and entry 1 has a description but no path at all. Both files are required
  Intellivision BIOSes, so the core is unlaunchable on the declared metadata.
  We skip pathless entries rather than guess, which costs this core one row.

* **`notes` checksum keys are not consistently the firmware path.** 182 entries key
  on the full `firmware*_path` (`bk/B11M_BOS.ROM`), but 53 key on the basename alone
  — `ppsspp` publishes `ppge_atlas.zim` for the path `PPSSPP/ppge_atlas.zim`. Any
  consumer has to try the path, then its basename. Not malformed exactly, but
  undocumented and easy to get wrong: keying on the path alone silently finds zero
  hashes for a third of the corpus, and the failure looks like "no checksums
  published" rather than a bug.
