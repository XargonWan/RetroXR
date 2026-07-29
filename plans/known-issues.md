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
