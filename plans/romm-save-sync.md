# RomM save sync

## Context

Battery saves are local-only. A cartridge owns a `save_id`, its `.srm` lives at
`save/<core>/<game_stem>/<save_id>.srm`, and that is the end of it — play the same game on
the Quest and on desktop and you get two unrelated saves with no way to move between them.
RomM already stores per-ROM saves for exactly this, and RetroVR already talks to RomM for
ROMs, art and firmware.

This adds: server saves listed and selectable in the cartridge menu, and an opt-in per save
to keep it synced.

### What already exists

| Piece | Where | Note |
|---|---|---|
| Per-cart save identity | `cartridge.gd:26` `save_id`, `"%08x%08x" % [randi(), randi()]` | persisted through `scene_persistence.gd` |
| Path layout | `sram_paths.gd` | `save/<core>/<game_stem>/<save_id>.srm`; files are **never deleted** |
| The cart menu | `cartridge_options_2d.gd` / `cartridge_options_panel.gd` | already lists every local `.srm` + "New blank save", and selecting one rebinds `save_id` |
| SRAM injection | `system.gd:2142` `net_set_sram()` → `Libretro.SetSramData()` | netplay already boots peers from supplied bytes |
| ROM → RomM id | `gamelist.json` `game_id = "romm:<id>"`, written by `romm_downloader.gd:423` | plus `RommClient.rom_by_hash()` for ROMs that did not come from RomM |
| Blocking HTTP on a worker | `romm_http.gd`, `firmware_installer.gd` | download side only — no multipart upload yet |

### The flush question, answered

Uploading "whenever the SRAM is saved" is the right trigger, and that event already exists —
in C++, where GDScript cannot see it. `Wrapper::FlushSramIfDirty()` (`Wrapper.cpp:843`):

- runs **every ~600 frames (~10 s)** from the emu loop (`Wrapper.cpp:1606`),
- runs once more at **core shutdown** (`Wrapper.cpp:1710`), so power-off is covered,
- runs on **memory-card hot-swap** via `ApplySramSwap` (`Wrapper.cpp:871`), so eject is covered,
- and is a real dirty check — `memcmp` against `m_sram_shadow`, early-returns when unchanged,
  so it only writes when the game actually wrote.

So the trigger is a **new signal on that function**, not a set of UI moments. No polling, no
timer over a running core, and nothing to keep in sync with power/eject handling.

### Decisions taken

- **Conflicts keep both, never overwrite.** The losing side forks into a new local `save_id`
  and shows up as its own row. Consistent with the existing rule that `.srm` files are never
  deleted.
- **Sync is per-save, off by default.** A cart can hold both synced and local-only saves;
  nothing touches the network unless asked.
- **Cartridge saves only.** Memory cards (`SramPaths.card_save_path`) are keyed by `card_id`
  and shared across games — RomM's model is per-`rom_id`, so a card does not map onto it.
- **Saves, not save states.** `/api/states` exists and so does `RequestSaveState` in C++, but
  it is wired only to netplay; there is no user-facing save-state feature to sync yet.

---

## Identity

| RetroVR | RomM | How |
|---|---|---|
| cartridge `save_id` | `slot` | used verbatim, so a round trip is stable and idempotent |
| core name | `emulator` | e.g. `mgba` |
| ROM | `rom_id` | `gamelist.json` `game_id` `"romm:<id>"`; falls back to `RommClient.rom_by_hash(md5)` and caches the result |

A cart whose ROM resolves to no `rom_id` cannot sync; its rows show the toggle disabled with
"Not on RomM".

## Sync state

New `<core_root>/save/romm_sync.json`, keyed by the local save's relative path:

```json
{ "mgba/Pokemon Emerald/a3f9c210": {
    "enabled": true, "rom_id": 1289, "server_save_id": 42,
    "last_hash": "8dd7…", "last_sync_at": 1785432100.0, "label": "" } }
```

`last_hash` is what makes the three-way call possible. RomM returns `content_hash` on
`SaveSchema`, so comparing local md5, `last_hash` and server hash distinguishes:

| local vs last | server vs last | Action |
|---|---|---|
| same | same | nothing |
| same | changed | **pull** — server moved on, adopt it |
| changed | same | **push** |
| changed | changed | **conflict** — push ours, fork theirs to a new `save_id`, notify |

Timestamps are deliberately not the discriminator: device clocks disagree and RomM's
`updated_at` is server-side, so "newest" is not reliable across devices.

## New and changed files

**C++ — `libretro-godot/src/`**
- `Wrapper.cpp` `FlushSramIfDirty()` — on a write that actually happened, notify the node.
  A `final` flag distinguishes the shutdown flush (`:1710`) from a periodic one, so GDScript
  can upload immediately at power-off and debounce otherwise. Runs on the emu thread, so it
  goes through the existing `call_deferred("emit_signal", …)` pattern (`Libretro.cpp:219`).
- `Libretro.cpp` — `ADD_SIGNAL(MethodInfo("sram_flushed", path, size, final))`, alongside the
  existing `savestate_ready` / `options_ready` declarations (`:307-321`).
- **Rebuild all targets** — Windows x86_64 *and* Android arm64. A stale `.so` makes the Quest
  silently exercise the old code.

**`RetroVR/Scripts/Data/romm_save_sync.gd`** — `RommSaveSync extends Node`. The whole policy
layer: owns `romm_sync.json`, resolves `rom_id`, runs the three-way comparison, and drives
push/pull/fork. One worker thread, mirroring `FirmwareInstaller`'s `_pump` → thread →
`call_deferred` shape. Debounce: coalesce periodic flushes to at most one upload a minute per
save; a `final` flush bypasses the debounce.

**`RetroVR/Scripts/Net/romm_saves.gd`** — `RommSaves extends Node`, thin API wrapper:
- `list(rom_id, cb)` → `GET /api/saves?rom_id=N`
- `download(save_id, dest, cb)` → `GET /api/saves/{id}/content`
- `upload(rom_id, core, slot, path, cb)` → `POST /api/saves?rom_id&emulator&slot&overwrite=true`
- `update(server_id, path, cb)` → `PUT /api/saves/{id}` once the server id is known

**`RetroVR/Scripts/Net/romm_http.gd`** — add `upload_multipart(path, headers, field, filename,
bytes)`. Everything there today is download-shaped; this is the one genuinely new primitive.
Keep it on the same blocking-HTTPClient model so it stays worker-thread-only.

**`RetroVR/Scripts/UI/cartridge_options_2d.gd`** — rows gain a trailing sync control, and a
second section lists server slots with no local copy:

```
Battery Save — Pokemon Emerald

  ●  a3f9c210    30 Jul 21:40    32.0 KB          ☁ synced
     7c2b91f0    28 Jul 09:15    32.0 KB          ☁ off
     a3f9c210    30 Jul 14:12    32.0 KB          ⚠ conflict (from Quest)

  On RomM
     e11d4a02    30 Jul 18:02    32.0 KB          ⬇ get

  ＋  New blank save          ＋  New synced save
```

Glyphs reuse the Nerd Font set already in `spawn_menu.gd` (`_ICON_DOWNLOAD` `U+F0ED`,
`_ICON_BUSY` `U+F019`, `_ICON_ERROR` `U+F071`) — note this panel has its own colour constants
and no `_symbols()` helper yet, so the shared `FontVariation` recipe comes with it.

**`RetroVR/Scripts/UI/cartridge_options_panel.gd`** — feed the server list in, forward the
toggle, and fetch `/api/saves` when the panel opens.

**`RetroVR/Scripts/Objects/system.gd`** — connect `sram_flushed` and hand it to `RommSaveSync`
with the seated cart's identity. Pull-on-power-on happens here too, before
`SetSramPath` (`:1242`), reusing the `net_set_sram` precedent for injecting bytes.

## Sequencing

1. **C++ signal + rebuild.** Nothing observable yet; verify with a probe that the signal fires
   on a real in-game save and carries `final=true` at power-off.
2. **`romm_saves.gd` + multipart upload.** Provable in isolation against the live server.
3. **`romm_save_sync.gd`.** The three-way logic is pure and unit-probeable with synthetic
   hashes — no server needed for the decision table.
4. **Cart menu UI.** Last, once the states it must render actually exist.

---

## Verification

The server currently holds **0 saves and 0 states** (checked), so every test starts by
uploading one — which is also the first thing worth proving.

**Probe 1 — the signal.** Boot a core with a real ROM headless, write to SRAM, assert
`sram_flushed` arrives with a plausible size, and assert the shutdown flush carries
`final=true`. Also assert it does **not** fire when nothing changed, since the whole design
rests on `FlushSramIfDirty` being a true dirty check.

**Probe 2 — round trip.** Upload a known byte pattern as slot `probe0000`, list it back,
download it, and assert byte equality and that `content_hash` matches. Then `PUT` a changed
copy and confirm the server hash moves.

**Probe 3 — the decision table.** Drive all four rows of the three-way matrix with synthetic
hashes and assert the chosen action. Then the real conflict path end to end: two different
local and server copies, assert both survive, that the fork gets a new `save_id`, and that
`list_saves()` returns both.

**Visual.** The cart menu is a `Viewport2Din3D` panel — render it with rows in every state
(off, synced, uploading, conflict, server-only) and deliver the PNG inline. Colour has to
carry the state at headset distance, not the glyph silhouette.

**On device.** The point of the feature is two devices. Sync a save on Windows, pull it on the
Quest, confirm the game continues from it. This is also the only way to test clock skew, which
is why hashes and not timestamps decide.

## Risks

- **Every `Viewport2Din3D` click fires twice** — the cart menu is one, so the sync toggle and
  the "get" button need the `VRDropdown`-style guard, not `ACTION_MODE_BUTTON_PRESS`.
- **A save uploaded mid-write is a torn save.** Uploading only from `sram_flushed` avoids it:
  the file is complete at that moment by construction. Never upload on a timer.
- **Quitting during an upload.** The worker must be joined in `_exit_tree`, and a partial
  upload must not be recorded as `last_hash` — only a 2xx updates sync state.
- **`rom_by_hash` on a big ROM** hashes the whole file. `RomHasher` is already threaded; the
  result must be cached in `romm_sync.json` so it happens once per cart, not once per flush.
