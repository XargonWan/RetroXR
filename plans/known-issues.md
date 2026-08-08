# GBA

* the power light doesn't come on when it is turned on
* the power switch doesn't slide to on when it is slide
* the buttons don't seem to animate

# Core-Info Known Issues

`RetroXR/libretro-core-info/` is no longer the `libretro/libretro-core-info`
submodule. It is a vendored copy of `dist/info/` from our own libretro-super
fork, which carries the fixes below; see that directory's README for how to
resync. 314 files, 155 distinct systemids.

## Fixed by the fork (2026-08-07)

* **C64** — `frodo` and `x64sdl` said `commodore_64` where the four VICE cores said
  `commodore_c64`. All four now agree on `commodore_c64`.
* **Amiga** — `fsuae` said `amiga` where the other four said `commodore_amiga`. All
  five now agree on `commodore_amiga`.
* Cost of those two, now paid off: `SystemInfo.for_system()` resolves
  `res://SystemInfo/<systemid>.tres`, so each machine needed TWO identical `.tres`
  files or half its cores took the fallback descriptor (2 ports, cartridge).
  `RetroXR/SystemInfo/` is 1:1 with the corpus again, and nothing counting systems
  out of that directory double-counts.
* **CD-i** — `cdi2015` took its own systemid; it now reports `cdi`.
* **Intellivision** — `FreeIntvTSOverlay` took `intv`; it now reports `intellivision`.
* **J2ME** — `squirreljme` said `J2ME` and `freej2me` said nothing; both now say
  `j2me`.
* **ScummVM** — systemname was the bare category "Game engine"; now
  "ScummVM Game Engine".
* **PSP** — `remotejoy` had an empty systemname, so whichever entry
  `get_systemname_for_id("playstation_portable")` reached first decided whether the
  label was "PSP" or blank. Both PSP cores now say "PSP".
* **`FreeIntvTSOverlay_libretro.info` firmware numbering** — it declared
  `firmware_count = 2` then wrote `firmware1_desc`, `firmware0_path`, `firmware0_opt`,
  so `grom.bin` overwrote `exec.bin`'s path and entry 1 had a description but no path.
  Both are required Intellivision BIOSes, so the core was unlaunchable on its own
  declared metadata. Now correctly numbered `firmware0_*` / `firmware1_*`.
* Nine cores gained a systemid: `emuscv` → `super_cassette_vision`, `freechaf` →
  `channel_f`, `freej2me` → `j2me`, `galaksija`, `gw` → `handheld_electronic`, `mu` →
  `palm_os`, `neocd` → `neo_geo_cd`, `simcp` → `sam_coupe`, `theodore` →
  `thomson_moto`.

Two files the old submodule had are not in libretro-super and were dropped with the
switch: `boom3_xp` (deleted upstream) and `radio` (`internet_radio`, which
`SystemFilter` hides — its entry there is now dead).

## Cores with no systemid at all

`CoreInfoDatabase._rebuild_indices()` only indexes entries with a non-empty
`systemid`, so these cores are absent from `_by_systemid` entirely — not hidden by
`SystemFilter`, just never there. No tile, no `get_unique_systemids()` entry, no way
to reach them from any system-browsing UI. The core still downloads and runs; only
the discovery path is missing.

36 of the 314 files still carry no `systemid`. Most are test harnesses, players and
single-game cores where it matters less. The real machines among them:

* `bk` — BK-0010/BK-0011(M)
* `oberon` — Ceres/Oberon workstation
* `pcem`, `qemu` — PC
* `vemulator` — Dreamcast VMU

Anything given an id also needs a `res://SystemInfo/<systemid>.tres` or it takes the
fallback descriptor, and a `res://Textures/SystemIcons/<systemid>.svg` or it draws
`_default.svg`. 38 of the 155 systemids still have no console icon: the players and
test cores, plus the ids the fork added that no core here reaches usefully yet —
`bbk`, `dingoo-a320`, `galaksija`, `neo_geo_cd`, `palm_os`, `sam_coupe`, `spmp8000`,
`super_cassette_vision`, `thomson_moto`, `wiiu`.

## Sub-platforms — the `secondary_systemids` key

A core declares ONE `systemid`, the parent machine. Every other platform it emulates
appears only in the `|`-separated `database` field, which nothing indexes.

`genesis_plus_gx` is `systemid = "mega_drive"` and
`database = "Sega - Game Gear|Sega - Master System - Mark III|Sega - Mega-CD - Sega
CD|Sega - Mega Drive - Genesis|Sega - PICO|Sega - SG-1000"`. Six machines, one id.
`picodrive` adds "Sega - 32X" on the same id.

Across the corpus: **162 distinct `database` names against 155 distinct systemids**.

Not a data bug — the stock format has no way to express "this core covers N
platforms". Our fork adds one (2026-08-07), documented in
`00_example_libretro.info`:

    secondary_systemids = "game_gear:gg|sega_cd:cue,iso,chd,m3u"

Pipe-delimited `<systemid>:<ext>,<ext>`. `CoreInfoDatabase._rebuild_indices()` files
the core under each id listed, so a sub-platform resolves to real cores instead of
zero — which is what made a new id unusable before. The extension subset matters:
`extensions_for_systemid()` unions the whole of `supported_extensions` for a primary
id, and Genesis Plus GX reads fifteen of them, so without it every `.md` would land
in the Game Gear library.

Two deliberate omissions:

* **No name in the key.** Five cores cover Game Gear; each repeating its name is how
  they come to disagree about it — which is exactly what `gearsystem` ("Sega 8-bit
  (MS/GG/SG-1000)") and `smsplus` ("Sega 8-bit") did. A secondary-only id is named by
  `SystemInfo/<id>.tres` instead, via `get_systemname_for_id()`. That function also
  ignores secondaries when naming a PRIMARY id: mesen2 declared `super_nes` and, being
  indexed first, relabelled it with its own twelve-platform display name.
* **A primary id keeps its full extension union.** Narrowing `mega_drive` to drop
  `gg`/`cue` would be correct and would also orphan whatever users already keep in
  `roms/mega_drive/`. Sega CD images still list under Mega Drive as they always did;
  they now also have a home of their own.

A core reached only as a secondary contributes its declared subset and nothing else,
which is what keeps this safe in the other direction too: the Mega Drive cores name
`master_system`, and `master_system` is a primary id, so an unfiltered union would
have pulled `md`/`cue`/`chd`/`32x` into a Master System library. `extensions_for_systemid()`
unions the cores whose OWN systemid it is, then adds only the declared subsets.

Sixteen platforms are wired this way, each with its own tile, icons and descriptor:
`game_gear`, `sega_cd`, `sega_32x`, `sg1000`, `sega_pico`, `fds`, `wii`,
`nintendo_64dd`, `supergrafx`, `pc_engine_cd`, `atari_8bit`, `svi`, `satellaview`,
`sufami_turbo`, `amiga_cd32`, `amiga_cdtv`.

Five ids that already had a tile simply gained cores: `master_system` (the three Mega
Drive cores), `colecovision` (bluemsx), `game_boy` (mgba, vbam, the two higan builds,
mesen-s, mesen2, skyemu), `game_boy_advance` (vbam, mesen2, skyemu) and `pc_engine`,
`super_nes` and `wonderswan` (mesen2). `skyemu` had no systemid at all and is now
`nds` plus Game Boy and GBA.

Claims follow each core's own `database` field, never its extension list — picodrive
reads `.sg` but does not declare SG-1000, so it is not claimed.

CD32 and CDTV are the one pair no extension can tell apart — both are Amiga CD
images. The per-system rom FOLDER separates them, which is all the scan needs; a
`.cue` in either is that platform's.

Still only in `database`: Naomi, Naomi 2, Atomiswave and ST-V, which the RomM map
already folds into `mame`; Enterprise 128 and Videoton TV-Computer (ep128emu_core);
Interton VC 4000 and Elektor TVGC (amiarcadia); GX4000; Videopac+; ZX Spectrum +3;
GBA e-Cards. Colour and revision variants — Game Boy Color, WonderSwan Color, Neo
Geo Pocket Color, MSX2, DSi — are left merged on purpose, matching the existing
`gbc` → `game_boy` decision.

Six cores name Sufami Turbo in `database` but read none of its extensions
(`bsnes`, `bsnes_hd_beta`, the four snes9x200x builds), so they do not claim it —
the same rule that kept SuperGrafx off mesen2. Fix those `supported_extensions`
lines upstream and they can.

## Duplicate systemids for one machine

Found by grouping every systemid by normalised `systemname` (2026-07-28). Same
failure mode as the C64/Amiga pair above — each one needs a duplicate `.tres`, and
each one shows up as two tiles in the Cores browser. CD-i and Intellivision are
fixed; these two remain.

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
* **"Multi (various)"** is shared by `mame` and `mess`
* **"Neo Geo"** is shared by `fb_alpha` and `neogeo`
* **A multi-system core naming the whole set.** Splitting a platform out into its
  own systemid does not rename the parent, so the parent kept advertising it —
  `gamecube` read "GameCube / Wii" beside a Nintendo Wii tile, and `nes` took
  mesen2's twelve-platform name. Fixed for every id the split touched: the Dolphin
  trio, the four PC Engine cores, `bluemsx`, `atari800` (which said "Atari 8-bit
  Family" under `atari_5200`), `mgba`, `vbam`, both Genesis Plus GX builds,
  `picodrive`, `mesen2` and `mesen-s`. Three disagreements remain and predate all
  of it: `cpc` ("CPC" vs "CPC/GX4000"), and the `fb_alpha` and `mame` arcade
  families below.
* **The empty string** is the systemname of `jumpnbump` and `superbroswar`.
  `get_systemname_for_id()` falls back to the systemid only when the key is absent,
  not when it is present and empty, so these render as a blank label

`scummvm`'s "Game engine" is fixed. There is no local override table to patch these
in — `CoreInfoDatabase.get_systemname_for_id()` returns the first indexed entry's
`systemname` verbatim, so the fix has to be in the data.

## Malformed firmware blocks

Found while building the BIOS / Extras tab (2026-07-30). Upstream data bugs, not
parser bugs. The `FreeIntvTSOverlay` misnumbering is fixed; the `bk` one is not.

* **`bk_libretro.info` has TWO `notes` lines** (61 and 62). A last-wins key/value
  parser — which is the obvious way to read this format, and what `CoreInfoParser`
  did — silently keeps only the second (`"(!) Homepage: …"`) and discards the first,
  which is the entire md5 checksum table for all 8 firmware files. Worked around in
  `CoreInfoParser.parse_info_file()` by joining duplicate `notes` on `"|"`, which is
  the format's own line separator;
  every other duplicated key (`supports_no_game`, `categories`, `display_version`)
  is genuinely single-valued and last-wins is correct for those. Still the only file
  in the corpus that does this.

* **`notes` checksum keys are not consistently the firmware path.** 182 entries key
  on the full `firmware*_path` (`bk/B11M_BOS.ROM`), but 53 key on the basename alone
  — `ppsspp` publishes `ppge_atlas.zim` for the path `PPSSPP/ppge_atlas.zim`. Any
  consumer has to try the path, then its basename. Not malformed exactly, but
  undocumented and easy to get wrong: keying on the path alone silently finds zero
  hashes for a third of the corpus, and the failure looks like "no checksums
  published" rather than a bug.
