# RomM Integration Plan

**Status:** planned, not started · **Date:** 2026-07-25
**Target server:** `http://192.168.0.106:8080` (`raspberrypi4.local:8080`) — RomM **5.0.0**

---

## Context

Today RetroXR only sees ROMs that were physically copied into
`<roms_root>/<systemid>/` (`RomLibrary.scan_roms`, `Scripts/Data/library/rom_library.gd:54`), and
metadata/art comes exclusively from ScreenScraper into a per-system `gamelist.json` +
`media/{wheel,box,label,manual}/` (`Scripts/Data/library/screenscraper_client.gd`,
`gamelist_manager.gd`). That means: manual file shuffling onto the Quest, per-ROM scraping,
and no shared library between devices.

The user runs a RomM server that already holds the library **and** its metadata and cover art.
Wiring RetroXR to it removes the file-shuffling and the scraping step in one move: browse the
whole server library in VR, tap a game, it downloads and spawns as a cartridge/disc with its
cover art on the label.

The hard constraint is scale. The current UI materialises **one `HBoxContainer` per ROM** with
a **synchronous `Image.load_from_file` per row** (`spawn_menu.gd:947` `_populate_cartridges_detail`,
`:983` `_build_rom_row`, `:3086` `_load_wheel_texture`) and joins metadata with an O(n) linear
scan per row (`gamelist_manager.gd:117` `get_game_for_rom`). That is fine for 30 NES ROMs and
falls over at 10k, let alone 100k. Everything below is designed so the cost of browsing is
**O(visible rows)**, not O(library).

Second constraint, discovered while planning: the server library averages **~272 MB/ROM**
(1328 ROMs / 361 GiB today), i.e. it is disc-heavy — and `Wrapper.cpp:1523` reads the **entire
ROM into RAM** before `retro_load_game`, even for `need_fullpath` disc cores. A 4 GB PS2 ISO
would try to allocate 4 GB on a Quest. That gets fixed here (Phase 0).

---

## Verified server facts (probed live, not assumed)

| Fact | Value |
|---|---|
| Version | `GET /api/heartbeat` → `SYSTEM.VERSION = "5.0.0"` — **public, no auth** |
| Library today | `GET /api/stats` → 1328 ROMs, 2 platforms, 387,791,570,277 bytes — **public, no auth** |
| API auth | `/api/**` returns **403** unauthenticated, with **no `WWW-Authenticate`** → must send credentials proactively |
| **Cover art auth** | **None.** nginx serves `location /assets { try_files ... }` with no auth gate (404, not 403, on a missing file). Art needs no `Authorization` header. |
| Art caching | `ETag` + `Last-Modified` + `Accept-Ranges` present; **no `Cache-Control`**. Covers already carry `?ts=<updated_at>` → treat cover URLs as immutable. |
| `/api/roms` shape | Envelope `{items, total, limit, offset, char_index, rom_id_index, filter_values}` — **not** a bare array |
| Pagination | limit/offset only, `limit` **min 1 / max 10000** (`limit=0` → 422). No cursor. |
| Param name | **`platform_ids`** (plural, repeatable) — *not* `platform_id` |
| Detail endpoint | `DetailedRomSchema` = `SimpleRomSchema` + 8 user arrays only → **all metadata and art paths are already in the list response; no N+1** |
| Downloads | `GET /api/roms/{id}/content/{name}`, scope `roms.read`, served via nginx `X-Accel-Redirect` → **Range works, resumable** |
| Incremental sync | `?updated_after=<ISO8601>` on `/api/roms`, `/api/platforms`, `/api/collections` |
| Deletion detection | `GET /api/roms/identifiers` → bare array of all visible ids |

### The one thing that dictates the whole design

In 5.0.0, **every `/api/roms` response includes `rom_id_index` — the complete ordered id list
for the entire filtered result set** (`backend/handler/database/roms_handler.py`). There is no
`with_rom_id_index` opt-out in this version (master added one later; this server does not have it).

At 100k ROMs that is a ~700 KB int array **attached to every page request**. Paging at
`limit=50` would ship ~1.4 GB of pure index overhead. Consequences, all of which the plan
follows:

1. **Minimise the number of `/api/roms` calls** → sync in large pages (`limit=1000`), not per scroll.
2. **Always** pass `with_char_index=false&with_filter_values=false&with_files=false` after the first call.
3. **Turn it into an asset**: that index *is* the ordered spine a virtual scroller wants. One
   cheap call (`limit=1`) yields `total` + `char_index` + the full ordered id list.
4. Server-side `search_term` is a **full library scan** whenever any filter is set (the memoised
   cache only covers the unscoped query) → debounce hard, prefer local search over the synced index.

`limit=1000` is the sweet spot: per-item JSON (~2.5 KB) dominates index overhead (~0.7 KB/item
at that size), and a 1000-item page is a ~3 MB body — parseable off-thread without a hitch.

---

## Architecture

```
                 ┌──────────────────────────────────────────────┐
  OPTIONS UI ──▶ │ RommConfig      roms/romm_config.json        │
                 │  base_url, auth_mode, token | user/pass,     │
                 │  budget, group_by_meta_id, platform_overrides│
                 └──────────────────┬───────────────────────────┘
                                    │
   ┌────────────────────────────────▼────────────────────────────────┐
   │ RommClient  (Node)  — auth, heartbeat, small one-shot calls      │
   │   HTTPRequest for /heartbeat /token /platforms /roms/{id}        │
   └───────────┬─────────────────────────────────┬───────────────────┘
               │                                 │
   ┌───────────▼──────────────┐      ┌───────────▼────────────────────┐
   │ RommCatalog (RefCounted) │      │ RommDownloader (Node)          │
   │  per-platform .jsonl +   │      │  Thread + HTTPClient,          │
   │  offset/id/name arrays   │      │  Range resume, .part+rename,   │
   │  sync on Thread          │      │  zip extract, art sidecars     │
   └───────────┬──────────────┘      └───────────┬────────────────────┘
               │                                 │
   ┌───────────▼─────────────────────────────────▼───────────────────┐
   │ Cartridges tab (merged local + server)                          │
   │   VirtualRowList  → O(visible) rows, recycled                   │
   │   RommArtCache    → LRU ImageTexture + on-disk cover cache      │
   └─────────────────────────────────────────────────────────────────┘
                               │ downloads land in roms/<systemid>/
                               ▼
        existing pipeline untouched: scan_roms · gamelist.json ·
        media/label → MediaDimensions.load_label_texture · SramPaths ·
        ScenePersistence · netplay MD5 resolve · StartContent
```

**Core principle: a downloaded RomM ROM is indistinguishable from a hand-copied one.**
It lands at `roms/<systemid>/<fs_name>` under its real filename, its cover is written to
`media/label/<basename>.<ext>`, its metadata is merged into `gamelist.json`. Every downstream
consumer — `SramPaths.game_stem`, `MediaDimensions.load_label_texture` (`media_dimensions.gd:96`),
`ScenePersistence` (`scene_persistence.gd:443`), `system.gd:1141 net_rom_md5()`,
`ReplaceDiskImage` — keeps working with **zero changes**. The only extra state is a sidecar
manifest recording *which* files came from the server, so eviction knows what it may delete.

### Threading contract

**No RomM work of any size runs on the main thread.** The frame budget at 90 Hz is 11 ms; a
3 MB `JSON.parse`, a cover decode, an MD5 pass or a 4 GB read will all blow it. Authoritative
split:

| Work | Runs on | Why |
|---|---|---|
| Catalog sync — HTTP + `JSON.parse` + `.jsonl` write | dedicated `Thread` + blocking `HTTPClient` | 3 MB bodies; `HTTPRequest` hands the body back on the main thread |
| ROM download — HTTP + chunked disk write + hash verify + zip extract | dedicated `Thread` + blocking `HTTPClient` | multi-GB, minutes long |
| Cover fetch (bytes → disk) and `Image.load_from_file` decode | `WorkerThreadPool` tasks | PNG/JPEG decode is 1–3 ms each and arrives in bursts while scrolling |
| `ImageTexture.create_from_image` + assignment to a row | main thread, **budgeted ≤ 4 per frame** | cheap `RenderingServer` call, but must touch the tree |
| Small one-shots — `/heartbeat`, `/token`, `/platforms`, `/roms/{id}` | `HTTPRequest`, `use_threads = true` | bodies < 100 KB; parse cost is negligible |
| Index random access — seek + `get_line` + parse of **one** row | main thread | microseconds, and only for currently-visible rows |
| Config / manifest JSON writes | main thread | a few KB |

Rules that make this safe:

- **Worker threads never touch the scene tree.** Results come back via `call_deferred`; the UI
  is only ever mutated on the main thread.
- **Stream to disk, never to RAM.** `HTTPClient.read_response_body_chunk()` returns chunks —
  `FileAccess.store_buffer` each one straight out. A 4 GB ROM must never be assembled in memory
  (that is the same mistake Phase 0 fixes on the C++ side).
- **One `Mutex` guards** the catalog's `_offsets` / `_ids` / `_names` arrays. A sync thread
  rebuilding them swaps in a new set under the lock; the UI reads whichever set is current.
- **Every thread loop checks an `_abort` flag** and is joined with `wait_to_finish()` from
  `_exit_tree()` / `NOTIFICATION_WM_CLOSE_REQUEST`. Without this, quitting mid-download hangs the
  app on exit — easy to get wrong, and miserable on the Quest.
- The `HTTPClient` poll loop sleeps (`OS.delay_msec(1)`) so it doesn't spin a core — this matters
  on the Quest, which is already CPU-bound.

### New files

| File | Class | Role |
|---|---|---|
| `Scripts/Data/romm/romm_config.gd` | `RommConfig` | `roms/romm_config.json`; mirrors `scraper_config.gd` load/save shape exactly |
| `Scripts/Data/romm/romm_platforms.gd` | `RommPlatforms` | RomM slug/fs_slug ↔ project systemid map; mirrors `screenscraper_systems.gd:8` |
| `Scripts/Net/romm/romm_client.gd` | `RommClient` (Node) | auth headers, `/heartbeat`, `/token`, device pairing, `/platforms`, `/roms/{id}`, `/roms/by-hash` |
| `Scripts/Data/romm/romm_catalog.gd` | `RommCatalog` | per-platform on-disk index, threaded sync, windowed random access, local search |
| `Scripts/Data/romm/romm_downloader.gd` | `RommDownloader` (Node) | resumable ROM download, multi-file zip, art + manual sidecars, cache manifest, LRU eviction |
| `Scripts/Data/romm/romm_cache_manifest.gd` | `RommCacheManifest` | `roms/romm_cache.json`; mirrors `download_manifest.gd` |
| `Scripts/UI/spawn_menu/virtual_row_list.gd` | `VirtualRowList` (Control) | reusable recycling virtual list |
| `Scripts/UI/spawn_menu/romm_art_cache.gd` | `RommArtCache` | async cover fetch + on-disk cache + LRU `ImageTexture` map |

### Modified files

| File | Change |
|---|---|
| `libretro-godot/src/Core.{hpp,cpp}` | cache `retro_get_system_info().need_fullpath`, expose `GetNeedFullpath()` |
| `libretro-godot/src/Wrapper.cpp:1505-1541` | skip the whole-file RAM read when `need_fullpath` |
| `Scripts/UI/spawn_menu/spawn_menu.gd` | Cartridges tab → merged model + `VirtualRowList`; OPTIONS → "ROMM SERVER" section; toast stack gains dwell/progress/cap + a public `notify()` (Phase 6) |
| `Scripts/UI/spawn_menu/spawn_menu_controller.gd:895` | `_on_spawn_cartridge_requested` gains a "not downloaded yet" path |
| `Scripts/Data/library/rom_library.gd` | add `scan_roms_map(systemid, exts) -> Dictionary` (lowercase filename → entry) for O(1) local/server dedupe |

---

## Phase 0 — C++: stop loading whole discs into RAM

### Why

`retro_get_system_info().need_fullpath` splits cores into two groups that want opposite things:

- **`need_fullpath = false`** — most cartridge cores (NES, SNES, Genesis, GB/GBA…). The core does
  *not* open the file itself; the frontend **must** read the bytes and supply `game_info.data`.
  Loading into RAM is mandatory here, and cheap — 128 KB to ~64 MB.
- **`need_fullpath = true`** — every disc core (PS1, PS2, Saturn, Dreamcast, GC, PSP), plus MAME
  and friends. The core opens `game_info.path` itself, normally through the VFS, because it needs
  to seek around the image, read tracks lazily and hot-swap discs. It **ignores `game_info.data`
  entirely**.

`Wrapper.cpp:1513-1534` never checks the flag: it unconditionally does
`m_game_buffer.resize(game_size)` + a full read, then sets **both** `path` and `data`. So a 4 GB
PS2 ISO is read off storage into a `std::vector` that nothing ever reads, after which the core
opens the same file and streams it off disk anyway. Three costs:

1. **On Quest this is fatal.** The per-app RAM budget is a fraction of the 8 GB device total; a
   4 GB allocation gets the process killed before the game boots.
2. Where it does fit (desktop), it's a multi-second pre-boot stall and doubled storage→RAM traffic.
3. `m_game_buffer` is a `Wrapper` member, so the buffer stays resident for the whole session —
   not just across `retro_load_game`.

The fix is **not** "use less RAM in general" — cartridge cores keep byte-for-byte their current
behaviour. It is "skip the copy for the cores that explicitly told us they don't want it." This
isn't RomM-specific either; RomM only makes it unavoidable, because that library averages
272 MB/ROM.

### What

1. `Core.cpp`: in `Load()`, after `LoadFunction(retro_get_system_info)`, call it once and cache
   `m_need_fullpath = info.need_fullpath` alongside the existing `m_supports_no_game`
   (`Core.cpp:147` `GetSupportsNoGame` is the pattern to copy). Expose `bool GetNeedFullpath() const`.
2. `Wrapper.cpp`: in the `else` branch at `:1505`, when `m_core->GetNeedFullpath()` is true, keep
   the `is_regular_file` guard, then build `game_info` with `path` only (`data = nullptr, size = 0`)
   and skip the `ifstream` entirely.
3. Sanity guard on the non-`need_fullpath` path: if `game_size` exceeds a threshold
   (suggest 512 MB), `LogError` and bail rather than attempting the allocation.
4. **Rebuild every target** — Windows `template_debug dev_build=yes` + `template_release`, and
   Android arm64 `template_debug`. A stale Android `.so` makes on-device testing silently
   exercise the old code path.

---

## Phase 1 — Config, auth, connectivity

`Scripts/Data/romm/romm_config.gd`, file `roms/romm_config.json` (sibling of `scraper_config.json`;
same hand-rolled JSON load/save as `scraper_config.gd:38-95` — the repo uses no `ConfigFile`):

```gdscript
var enabled: bool = false
var base_url: String = ""              # "http://192.168.0.106:8080", trailing slash stripped
var auth_mode: String = "token"        # "token" | "basic"
var token: String = ""                 # rmm_<64 hex>
var username: String = ""
var password: String = ""
var cache_budget_gb: float = 20.0
var group_by_meta_id: bool = true      # collapse multi-region dupes
var platform_overrides: Dictionary = {}   # romm_slug -> systemid
var sync_state: Dictionary = {}        # systemid -> {updated_after, total, synced_at}
var last_stats: Dictionary = {}        # {ROMS, TOTAL_FILESIZE_BYTES} for cheap change detection
```

`RommClient` (`Scripts/Net/romm/romm_client.gd`, `extends Node` so it can own `HTTPRequest` children —
same shape as `CoreDownloadManager`):

- `auth_headers() -> PackedStringArray` — `["Authorization: Bearer rmm_…"]` or
  `["Authorization: Basic " + Marshalls.utf8_to_base64("user:pass")]` depending on `auth_mode`.
  **Both modes are supported** (user decision). Every `/api/**` call sends them; cover-art
  fetches deliberately do not.
- `heartbeat(cb)` → public, no auth. Parse `SYSTEM.VERSION`, gate on major ≥ 5, and read
  `FRONTEND.DISABLE_USERPASS_LOGIN` / `OIDC.ENABLED` to decide whether to offer the password form.
- `pair_with_code(code, cb)` → `POST /api/client-tokens/exchange {"code": "12345678"}` —
  **unauthenticated**, the 8-digit code is the credential. This is the good path in VR: generate
  the code on the desktop UI, type 8 digits on the headset instead of a 68-char token.
- `login_basic_and_mint_token(user, pass, cb)` (optional convenience) → Basic-auth
  `POST /api/client-tokens` with scopes `roms.read platforms.read collections.read`, store
  `raw_token`, drop the password. Offered as a "convert to token" button.
- `test_connection(cb)` → heartbeat + authed `GET /api/roms?limit=1&with_char_index=false&with_filter_values=false`;
  reports version, total ROM count, and which auth mode succeeded.

**OPTIONS UI** — new "ROMM SERVER" section in `spawn_menu.gd` immediately before the existing
"SCRAPER" header (`spawn_menu.gd:1854`), built with the existing
`_add_options_text_field(parent, label, value, on_changed, secret)` (`:1900`) which already
carries the Meta overlay-keyboard bounce workaround:

- Server URL (text) · Auth mode (`VRDropdown` — **never `OptionButton`**, see the double-click
  gotcha) · API token (secret) · Username · Password (secret) · Cache budget GB (text) ·
  Group multi-region duplicates (CheckButton).
- Buttons: **Pair with code** (8-digit `LineEdit` → `pair_with_code`), **Test connection**,
  **Sync library now**, **Clear downloaded ROMs** (evicts *only* manifest-tracked files).
- Status line: `RomM 5.0.0 · 1328 ROMs · 361 GiB · 12.4 GB cached / 20 GB budget`.

---

## Phase 2 — Platform mapping

`Scripts/Data/romm/romm_platforms.gd`, a literal mirror of `screenscraper_systems.gd:8`'s `SYSTEM_MAP`
shape. RomM platform slugs are IGDB-style (`nes`, `snes`, `n64`, `gb`, `gba`, `gbc`, `nds`,
`ps`, `ps2`, `psp`, `dc`, `saturn`, `genesis-slash-megadrive`, `atari2600`, `virtualboy`, …);
project systemids come from libretro core-info (`nes`, `super_nes`, `nintendo_64`, `game_boy`,
`mega_drive`, `playstation`, `playstation2`, `playstation_portable`, `virtual_boy`, …).

```gdscript
const SLUG_MAP := { "nes": "nes", "snes": "super_nes", "n64": "nintendo_64", ... }

## fs_slug wins over slug (the user's own folder naming may already be our systemid),
## then RommConfig.platform_overrides, then SLUG_MAP.
static func systemid_for(platform: Dictionary, overrides: Dictionary) -> String
```

Resolution order: `overrides[slug]` → `overrides[fs_slug]` → `SLUG_MAP[fs_slug]` →
`SLUG_MAP[slug]` → `""`. Unmapped platforms are **not silently dropped** — they are listed in
the OPTIONS status panel as "unmapped: <name> (<slug>)" so the user can add an override, because
a systemid is required to pick cart-vs-disc, physical dimensions and the 3D model
(`media_dimensions.gd:71 is_disc_system`, `cartridge.gd:38 _CART_MODELS`).

---

## Phase 3 — Catalog: the scalable index

`RommCatalog` keeps **no ROM dictionaries in RAM**. Per mapped systemid it maintains:

```
roms/<systemid>/.romm/index.jsonl     one slim JSON object per line, server order (order_by=name)
roms/<systemid>/.romm/index.meta.json {total, updated_after, synced_at, group_by_meta_id, platform_id}
```

In memory per **currently open** system only:

```gdscript
var _offsets: PackedInt64Array   # byte offset of row N in index.jsonl
var _ids:     PackedInt32Array   # RomM rom id of row N          (spine)
var _names:   PackedStringArray  # lowercased name for instant local search
```

100k rows ≈ 800 KB + 400 KB + ~2 MB of strings — trivial, and `FileAccess.seek(_offsets[n])` +
`get_line()` + `JSON.parse_string` gives O(1) random access to row N without holding the library.

**Slim row schema** written to `index.jsonl` (drop `summary` and every raw provider blob —
`igdb_metadata` et al. are large and unused; fetch them on demand from `/api/roms/{id}`):

```
id, name, fs_name, fs_name_no_tags, fs_extension, fs_size_bytes,
md5_hash, sha1_hash, crc_hash, regions, languages, tags, revision,
path_cover_small, path_cover_large, has_manual, has_multiple_files,
is_identified, updated_at, first_release_date, genres, companies
```

### When sync runs — lazily, per platform, never at launch

| Trigger | What happens | Cost |
|---|---|---|
| **App launch** | Nothing. At most one fire-and-forget `/api/stats` ping, and only if a server is configured *and* enabled. | ~100 bytes, or zero |
| **Cartridges tab opened** | `GET /api/platforms` (cached) to build the system grid with `"12 local · 843 server"` badges. Local systems render **immediately**; server platforms merge in when it returns. | one small request |
| **System page opened, first time** | That **one** platform syncs, with in-page progress. Local ROMs for that system render instantly meanwhile — the page is never blank and never blocked. | 2 requests (1.3k ROMs) … 100 (100k) |
| **System page opened, already synced** | Instant, from the local index. A background delta check runs **only** if the `/api/stats` fingerprint moved since last time. | 0–2 requests |
| **OPTIONS → "Sync all now"** | Every mapped platform, sequentially, for deliberate offline browsing. | explicit opt-in |

A full-library sync at launch is the obvious-looking design and it's the wrong one: on a 100k
library it is minutes of transfer before the user can do anything, it re-runs on every cold start,
and it syncs platforms they will never open. Per-platform-on-open spreads the same work across
the natural browse flow, and in practice most sessions touch two or three systems.

The `/api/stats` fingerprint (`ROMS` + `TOTAL_FILESIZE_BYTES`, public, no auth) is what makes
repeat opens free — if it matches `RommConfig.last_stats`, the library provably hasn't changed
and no `/api/roms` call is made at all.

### Sync (on a `Thread`, `HTTPClient` — not `HTTPRequest`)

`HTTPRequest` hands the body back on the main thread; a 3 MB `JSON.parse` there is a visible
hitch at 90 Hz. Sync therefore runs on a dedicated `Thread` using the blocking `HTTPClient` API,
parsing and appending to `index.jsonl` page by page, reporting progress via `call_deferred`.
`Scripts/Net/web_file_server.gd:53` (raw `TCPServer` + `Thread`) is the in-repo precedent that
this pattern is welcome here.

```
GET /api/roms?platform_ids=<pid>&limit=1000&offset=<n>
    &order_by=name&order_dir=asc
    &group_by_meta_id=<cfg>
    &with_char_index=false&with_filter_values=false&with_files=false
```

- First page only: `with_char_index=true` → keep `char_index` for the A–Z jump strip.
- `total` and the spine come free from page 1; the progress toast is exact from the first response.
- Write each page straight to disk; never accumulate pages in RAM.
- **Resumable**: `index.meta.json` records the last completed offset, so an interrupted sync
  (headset sleep, WiFi drop) resumes rather than restarting.
- 1328 ROMs → 2 requests, ~4 MB, a couple of seconds. 100k in one platform → 100 requests,
  ~320 MB, minutes — a background job with progress, done once, delta-updated thereafter.

### Delta sync

1. `GET /api/stats` (public, ~100 bytes) — if `ROMS` and `TOTAL_FILESIZE_BYTES` match
   `RommConfig.last_stats`, **nothing changed, stop.** This is the cheap poll on menu open.
2. Otherwise `GET /api/roms?...&updated_after=<sync_state[systemid].updated_after>` → apply
   adds/edits by id into `index.jsonl` (rewrite-on-compact; a dirty-row count over ~20 % triggers
   a full re-sync, which is simpler and rare).
3. `GET /api/roms/identifiers` → set-diff against `_ids` to detect **deletions** (`updated_after`
   cannot express them). Bare int array, cheap even at 100k.

Explicitly **not** doing socket.io live updates: Godot has no socket.io client (it is a
protocol layered on WebSocket with its own handshake/framing), and 5.0.0 emits no per-ROM
mutation events anyway — only `scan:*`. Polling `/api/stats` is strictly better value here.

### Search

- Synced platform → local filter over `_names` (instant, works offline, no server load).
- Not-yet-synced → server `search_term`, **debounced 400 ms**, because every scoped query is a
  full-library scan server-side. `search_term` is case-insensitive, matches both `name` and
  `fs_name`, whitespace = AND, `|` = OR.

---

## Phase 4 — Merged Cartridges tab + virtualization

`_populate_cartridges_tab` (`spawn_menu.gd:935`) currently lists systems from
`core_defaults.all_defaults()`. It becomes the **union** of that set with mapped RomM platforms,
badged `"12 local · 843 server"`.

`_populate_cartridges_detail` (`spawn_menu.gd:947`) is rewritten around a merged row model and a
virtual list. Merge rule (cheap first, hashes only opportunistically):

1. `RomLibrary.scan_roms_map(systemid, exts)` → `{lowercase fs_name: {path, label}}` (new helper;
   the existing `scan_roms` already builds this dictionary internally at `rom_library.gd:67`, so
   it is a small refactor, not new logic).
2. Walk the catalog spine; a server row whose `fs_name.to_lower()` hits the local map is `BOTH`
   (already downloaded). Leftover local-only files append at the end as `LOCAL`.
3. Opportunistic hash match only when a local MD5 is already cached
   (`NetFileTransfer.cached_hash_of`, `file_transfer.gd:80`) — never hash 361 GiB to build a list.
   `GET /api/roms/by-hash?md5_hash=…` stays available for one-off "what is this local file?" lookups.

**`VirtualRowList`** (`Scripts/UI/spawn_menu/virtual_row_list.gd`, `extends Control`) — the reusable piece:

```gdscript
func set_row_count(n: int) -> void
func set_row_height(h: int) -> void
func set_row_builder(cb: Callable) -> void   # func() -> Control        (pool allocation)
func set_row_binder(cb: Callable) -> void    # func(row: Control, i: int) -> void
func scroll_to_index(i: int) -> void         # for the A–Z char_index strip
```

Sits inside the existing detail `ScrollContainer` of `SystemGridBrowser`
(`system_grid_browser.gd:202`, already wired to VR trigger-scroll via `active_scroll_changed`).
`custom_minimum_size.y = count * row_h`; a pool of `visible + 4` recycled rows is repositioned
and re-bound on `scroll_vertical` change. Cost is O(visible), independent of library size.

Rows reuse the existing `_build_rom_row` layout (`spawn_menu.gd:983`) — `MarqueeButton` for long
titles, 🎮 detail, 📖 manual, ✂️ scrape — plus:

- a **leading state icon** (see below) as the row's first child, separated from the trailing
  🎮 📖 ✂️ cluster,
- cover thumbnail (from `RommArtCache`, async; placeholder until decoded),
- ✂️ scrape hidden for server rows (RomM already supplies the metadata).

### Leading state icon (Nerd Font)

`RetroXR/fonts/SymbolsNerdFont-Regular.ttf` is already a bundled project resource — so it works
on Quest with no system-font dependency — and the recipe is established at `vr_hinge.gd:214-219`
and `tv_remote.gd:124-128`:

```gdscript
var fv := FontVariation.new()
fv.base_font = ThemeDB.fallback_font
fv.fallbacks = [load("res://fonts/SymbolsNerdFont-Regular.ttf")]
```

Codepoints verified present in that TTF's cmap, names read from its `post` table:

| Row state | Codepoint | Glyph name | Tint | Action |
|---|---|---|---|---|
| `SERVER` — not downloaded | `U+F0ED` | `fa-cloud_download` | muted blue | start download |
| downloading | `U+F019` | `fa-download` + `38%` + thin bar | amber | tap to cancel + drop `.part` |
| `BOTH` — downloaded, on server | `U+F01B4` | `md-delete` | red | delete local copy → back to cloud |
| `LOCAL` only — not on server | `U+F05E8` | `md-delete_forever` | red | delete — **irreversible** |
| retrying after a transient failure | `U+F021` | `fa-refresh` | amber | (auto) countdown in subtitle |
| terminal failure | `U+F071` | `fa-warning` | red | tap to retry; reason in subtitle |

The downloading state is the glyph with the **percentage underneath it and a 5 px progress bar
below that**, all inside the same 76×100 button — a bare ✕ read as an error, not as activity.
Build it as a `Button` (the single tap target) with a `Label` and a `ProgressBar` as children,
both `mouse_filter = MOUSE_FILTER_IGNORE`, anchored `PRESET_BOTTOM_WIDE`. Tapping the button
cancels (two-stage confirm, same as delete); the row subtitle carries the byte counter
(`1.6 / 4.3 GB`).

Two different delete glyphs is deliberate: the pictogram encodes whether the file is
re-downloadable. `md-delete_forever` on a server-backed ROM over-warns (it's one tap to get it
back); `md-delete` on a local-only ROM under-warns (that file is gone for good).

**Rendered and checked 2026-07-25** (throwaway probe, since deleted). `fa-cloud_download` and
`fa-download` read instantly, and the percent + bar under the download arrow reads clearly as
"in flight" at row size. Both trash cans read correctly at 96 px, **but at the 40 px row size
`md-delete` and `md-delete_forever` are nearly indistinguishable** — the ✕ on the can body is
only visible if you're looking for it. So the glyph pair is a *supporting* signal, not the
primary one: the reversible/permanent distinction must be carried by the confirm text
("Delete local copy" vs "Delete permanently — not on server") and by the confirm styling. Also
noted from the render: the cloud glyph is visually lighter than the trash glyphs at the same
`font_size`, so it wants ~+4 px for even weight (verified — with the bump the four states sit
at matching visual weight).

**Caveats:**

1. **Destructive action in VR.** Every `Viewport2Din3D` click fires twice and pointer aim at
   distance is imprecise. Left placement separates it from the frequent-tap cluster, but it still
   needs a **two-stage tap** — first press turns the icon red with a confirm label for ~3 s,
   second press within that window commits. Hard-block deletion while the ROM is inserted in a
   powered-on system, or while a download targeting it is active.
2. **Share one `FontVariation`.** The virtual list recycles rows — build it once for the menu and
   reuse the resource; never per row or per bind.
3. **Glyph/emoji visual clash — confirmed in the render, worse than expected.** The existing
   🎮 📖 ✂️ are full-colour system emoji and sit next to flat monochrome PUA glyphs in the same
   row; the mismatch in weight and colour is obvious at a glance. Converting the trailing cluster
   to Nerd Font was rendered alongside and looks markedly more coherent — do it as part of
   Phase 4, not deferred. `fa-gamepad` (`U+F11B`) reads well; `U+F02D` reads more like a document
   than a manual — use `md-book_open_page_variant` (`U+F05DA`, verified present) instead.
4. **Colour carries further than shape** at VR viewing distance: blue = fetch, amber = in
   progress, red = destructive. Don't rely on silhouette alone.
5. **LRU eviction races the UI** — auto-eviction can remove a file behind a visible row, leaving
   a stale icon. `RommCacheManifest` gains a `changed` signal; the detail page re-binds visible
   rows on it (cheap, the list is virtualized).
6. `U+F05E8` is above `0xFFFF`. Fine in GDScript (Godot Strings are UTF-32); construct with
   `String.chr()`, matching `vr_hinge.gd:238`.

Detail page header gains a debounced search `LineEdit` and the A–Z jump strip driven by
`char_index`. Note `SystemGridBrowser._on_filter_changed` (`:259`) only filters *system tiles* —
ROM-level search is new.

**`RommArtCache`** (`Scripts/UI/spawn_menu/romm_art_cache.gd`):

- URL = `base_url + rom.path_cover_small` — **verbatim**, never reconstructed. The path already
  contains `/assets/romm/resources` and a `?ts=<updated_at>` buster; prepending the prefix
  yourself double-prefixes it. Percent-encode the query (the `ts` value is a raw datetime with
  spaces and colons). Absent art is `""`, not `null` — test `!= ""`.
- **No `Authorization` header** (nginx serves `/assets` unauthenticated — verified).
- On-disk cache `roms/<systemid>/media/romm/<rom_id>_s.<ext>`; because `?ts=` changes whenever the
  ROM does, cached files are treated as immutable — no revalidation round-trip.
- ≤ 4 concurrent `HTTPRequest` nodes with `download_file` set (same streaming-to-disk trick as
  `core_download_manager.gd:218`), a fetch queue driven by what is currently visible, and
  **cancellation on scroll-away**. `download_file` matters here: the bytes go to disk instead of
  being handed back as a `PackedByteArray` on the main thread.
- **Decode off the main thread.** `Image.load_from_file` runs as a `WorkerThreadPool` task; only
  `ImageTexture.create_from_image` and the assignment to the row happen on the main thread,
  budgeted at ≤ 4 per frame. Decoding covers inline while scrolling is the classic way this kind
  of grid stutters, and a burst of 20 rows scrolling into view would cost ~40 ms on the main
  thread — four dropped frames.
- LRU `ImageTexture` map capped at ~200 entries, modelled on `pdf_book.gd:467 _trim_texture_cache`.
- A missing or failed cover is **not** an error state — the row falls back to the title text
  (exactly what `_build_rom_row` already does when no wheel art exists) and simply doesn't retry.

---

## Phase 5 — Download → spawn

Tapping a server row runs `RommDownloader` (Thread + `HTTPClient`, so a 4 GB pull never touches
the main thread):

```
GET /api/roms/{id}/content/{fs_name}
Authorization: <auth_headers()>
Range: bytes=0-                       # always — resumable in BOTH single- and multi-file cases
```

1. Destination `roms/<systemid>/<fs_name>` — **the real filename**, so SRAM stems
   (`sram_paths.gd:13`), label-art lookup (`media_dimensions.gd:96`), scene restore
   (`scene_persistence.gd:443`) and netplay MD5 resolve (`system.gd:1141`) all keep working.
2. Write to `<fs_name>.part`, then atomic rename — the exact pattern at `file_transfer.gd:303
   _finish_recv`. A `.part` present on start means resume: send `Range: bytes=<size>-`.
3. `has_multiple_files` → the response is a zip (RomM injects a generated `.m3u`). Extract
   preserving subpaths (`core_download_manager.gd:289 _extract_zip` is the model, but **do not
   flatten** — it flattens deliberately for DLLs), then launch the `.m3u`/`.cue`.
   `?file_ids=<one>` fetches a single member raw when only one file is needed.
4. Verify `fs_size_bytes`; verify `md5_hash` when present (`RomHasher.compute_checksums`,
   `rom_hasher.gd:16` — chunked, already used by the scraper).
5. Sidecars, so the rest of the app lights up for free:
   - `path_cover_large` → `media/label/<basename>.<ext>` → `MediaDimensions.load_label_texture`
     paints it on the cart/disc **with no code change**. (RomM has no separate cart/disc "support"
     art and no wheel/logo — SGDB is disabled on this server — so the cover is the best source;
     ScreenScraper stays the wheel provider.)
   - `has_manual` → fetch `path_manual` to `media/manual/<basename>.pdf` on demand; the existing
     📖 button (`spawn_menu.gd:1025`) then just works.
   - Merge name/genre/companies/release date into `gamelist.json` via
     `GamelistManager.add_or_merge_rom` (`gamelist_manager.gd:65`), using `"romm:<id>"` as
     `game_id` so RomM and ScreenScraper entries never collide.
6. Record in `roms/romm_cache.json` (`RommCacheManifest`, shaped after `download_manifest.gd`):
   `{"<systemid>/<fs_name>": {rom_id, size, md5, downloaded_at, last_used_at}}`.
7. Emit the existing `spawn_cartridge_requested(rom_path, game_label, systemid)` — from here the
   flow is completely unchanged (`spawn_menu_controller.gd:895` → cart/disc instantiate → insert →
   `power_on()` → `StartContent`).

Progress is reported per-row and via the existing toast stack (`_make_media_toast`,
`spawn_menu.gd:2742`), with cancel. One download at a time by default (these are big files);
queue the rest.

### Error handling

Every failure is classified before anything is retried — blind retry loops on a 403 or a 404
just hammer the server and confuse the user. Retry policy reuses the shape already in
`screenscraper_client.gd:113-121` (`MAX_RETRIES := 3`, delay `pow(2, retry + 1)` seconds).

| Failure | Class | Retry? | `.part` | UI |
|---|---|---|---|---|
| Connection dropped / timeout / DNS | transient | yes, ×3 backoff — **resumes** from `.part`, doesn't restart | keep | amber, auto-retrying, countdown in subtitle |
| HTTP 5xx | transient | yes, ×3 backoff | keep | as above |
| HTTP 401 / 403 | **auth** | **no** | keep | red, "Sign in to RomM again" → deep-link to the OPTIONS section |
| HTTP 404 | **stale catalog** | **no** | delete | red, "No longer on server" → triggers a delta sync, row disappears |
| HTTP 416 Range Not Satisfiable | **stale `.part`** | yes, once, from byte 0 | delete first | brief amber flicker; usually invisible |
| Size ≠ `fs_size_bytes` | **corrupt** | yes, once, from byte 0 | delete first | amber then red on second failure |
| MD5 ≠ `md5_hash` | **corrupt** | yes, once, from byte 0 | delete first | as above |
| Zip extract failed (multi-file) | **corrupt** | yes, once | delete | as above |
| Disk write failed (`ERR_FILE_CANT_WRITE`, no space) | **local** | **no** | keep | red, "Not enough space" + offer "Free up cache" |
| User cancelled | not an error | — | keep (resumable later) | back to the cloud icon |
| App quit / crash mid-download | not an error | — | keep | resumes on next tap |

Principles behind that table:

- **Resume, don't restart.** Because every request already carries `Range: bytes=0-`, a transient
  retry continues from the `.part` instead of re-pulling 4 GB. This is the single biggest
  robustness win on flaky Quest WiFi.
- **`.part` is deleted only when the bytes are known-bad** (corrupt, 416, gone from server). A
  network failure leaves it alone so the next attempt is cheap.
- **A partial file must never be visible as a ROM.** `.part` + atomic rename
  (`file_transfer.gd:303 _finish_recv`) is not just tidiness — a half-written `.iso` sitting in
  `roms/<systemid>/` would be picked up by `RomLibrary.scan_roms`, spawn as a real cartridge, and
  fail deep inside `StartContent` with an error the user cannot interpret.
- **Auth failures are terminal and get their own message.** A revoked or expired token looks
  identical to a network error at the transport layer and completely different to the user.
- **Terminal failures are sticky, not silent.** The row parks in an error state
  (`fa-warning`, `U+F071`, red) with the reason in the subtitle; tapping it retries
  (`fa-refresh`, `U+F021`). A toast fires once via the existing stack
  (`_make_media_toast`, `spawn_menu.gd:2742`) — never one toast per retry.
- Log with a `[RommDownloader]` prefix via `push_warning` / `push_error`, matching repo style, so
  on-device `adb logcat -s godot:*` triage works.

### Eviction

Budget from `RommConfig.cache_budget_gb` (default 20 GB). Eviction runs **before** a download
starts, sized for the incoming file (`fs_size_bytes` is known from the catalog), and again after
it completes. Before matters more than after: Godot exposes no free-space API, so the budget is
the only guard against a 4 GB pull filling the device — evicting only afterwards means the
overflow has already happened. If even a full eviction can't make room, the download is refused
up front with "Not enough space" rather than failing 90 % of the way in.

Eviction deletes least-recently-used **manifest-tracked files only** — hand-copied ROMs are never
touched — skipping anything currently inserted in a powered-on system or referenced by a saved
scene. `last_used_at` is stamped when a cart spawns. Their
`media/`, `gamelist.json` and `.srm` sidecars are **kept** (kilobytes, and it makes re-download
instant and preserves saves).

---

## Phase 6 — Notifications (reuse the existing status bar / toast stack)

Everything RomM does in the background must surface in the same bottom-of-menu slot the scraper
already uses for "Hashing ROM…". Two widgets exist there and they are not interchangeable:

| Widget | `spawn_menu.gd` | Behaviour | Right for |
|---|---|---|---|
| Status bar | `_show_scrape_status` `:2643`, `_update_scrape_status` `:2689`, `_hide_scrape_status` `:2712`, public `show_notice(msg, seconds)` `:2700` | **Exactly one** bar, hardcoded ⏳, persists until hidden | one-at-a-time modal-ish progress |
| Toast stack | `_make_media_toast(key, icon, msg)` `:2742`, `_finish_media_toast` `:2791`, `_remove_media_toast` `:2810` | **Many** bars keyed by an arbitrary string, stacked above the status bar, auto-dismiss 2.5 s | concurrent, independent operations |

**Use the toast stack, not the status bar.** RomM routinely has a sync and one or more downloads
in flight at once; the single status bar would let them clobber each other's text. The stack's
`media_type` argument is just a dictionary key, so RomM claims a `"romm:"` namespace —
`"romm:sync:<systemid>"`, `"romm:dl:<rom_id>"`, `"romm:cache"` — which cannot collide with the
scraper's existing `box` / `wheel` / `label` / `manual` keys.

### Small extensions needed to the stack

The existing helpers are close but not sufficient. Four minimal, backwards-compatible changes —
the scraper's current call sites keep working untouched:

1. **`_finish_media_toast` gains a `seconds := 2.5` param.** Errors need to dwell longer (~6 s);
   a 2.5 s flash is not enough to read a failure reason in VR.
2. **Optional progress on a toast** — `_make_media_toast(..., progress := -1.0)` adds a thin
   `ProgressBar` under the label when ≥ 0. Same treatment as the row icon: `MOUSE_FILTER_IGNORE`.
3. **Cap the visible stack.** `_media_toast_stack` is anchored with `offset_top = -300.0`
   (`:2735`), so it holds ~5 bars before overflowing off the panel. Show at most 4 and collapse
   the rest into a single "+3 more" bar.
4. **A public `notify(key, icon, msg, opts)` wrapper** so `RommCatalog` / `RommDownloader` have
   one entry point instead of reaching into private `_`-prefixed methods.

Toasts are `MOUSE_FILTER_IGNORE` (`:2752`) and stay that way — they are not tappable. Retry lives
on the row icon, which is the thing that knows how to retry.

### The notification set

Progress lines **update the existing toast in place**; they never stack per update, and a retry
never mints a second toast.

| Event | Key | Icon | Text | Dwell |
|---|---|---|---|---|
| Sync started | `romm:sync:<sid>` | `⏳` | `Syncing PlayStation 2 from RomM…` | persists |
| Sync progress | ↑ same | `⏳` | `Syncing PlayStation 2 · 4,200 / 12,800` | in place |
| **Sync found content** | ↑ same | `✅` | **`PlayStation 2 · 242 new games`** | 3 s |
| Sync, nothing new | ↑ same | `✅` | `PlayStation 2 · up to date` | 1.5 s |
| Sync found removals | ↑ same | `✅` | `PlayStation 2 · 18 games removed` | 3 s |
| Sync failed | ↑ same | `❌` | `RomM sync failed — <reason>` | 6 s |
| Connected | `romm:conn` | `✅` | `RomM 5.0.0 · 1,328 games` | 2.5 s |
| Auth expired | `romm:conn` | `❌` | `RomM sign-in expired — check OPTIONS` | 6 s |
| Server unreachable | `romm:conn` | `❌` | `RomM unreachable` | 6 s, **once per state change** |
| Download started | `romm:dl:<id>` | `⬇` | `Gran Turismo 3 · 4.1 GB` | persists |
| Download progress | ↑ same | `⬇` | `Gran Turismo 3 · 38% · 1.6 / 4.3 GB` | in place |
| Download retrying | ↑ same | `⏳` | `Gran Turismo 3 — network error, retry 2/3` | in place |
| Download done | ↑ same | `✅` | `Gran Turismo 3 ready` | 2.5 s |
| Download failed | ↑ same | `❌` | `Gran Turismo 3 — <reason>` | 6 s |
| **Cache evicted** | `romm:cache` | `🗑` | `Freed 8.2 GB — removed 3 games` | 4 s |
| Out of space | `romm:cache` | `❌` | `Not enough space for Gran Turismo 3 (4.1 GB)` | 6 s |
| Unmapped platforms | `romm:map` | `⚠` | `3 RomM platforms unmapped — see OPTIONS` | 4 s, once per sync |

Two of these are less obvious than the rest and both matter:

- **Cache eviction must be announced.** Files silently vanishing from a library is alarming and
  looks like data loss. One toast naming the reclaimed space turns it into an obviously-deliberate
  housekeeping action.
- **"Server unreachable" fires on state *change*, not per failed request.** A dead server with a
  background poll would otherwise produce an endless toast stream.

### Two things that fall out of where this UI lives

1. **Toasts must be raised via `call_deferred`.** Sync and downloads run on worker threads
   (see the threading contract); they never touch these nodes directly.
2. **The stack lives inside the menu's `SubViewport`** (`add_child` on the `SpawnMenu2D`, `:2686`
   / `:2739`), so it is only visible while the menu panel is open. A 4 GB download continues while
   the user is playing and its completion toast would go unseen. So `RommDownloader` and
   `RommCatalog` **queue terminal outcomes that occurred while the menu was closed** and flush
   them on next open — capped and coalesced (`✅ 2 downloads finished · 1 failed`) rather than
   replaying every toast. Anything more visible than that (a world-space notification) is
   deliberately out of scope.

---

## Efficiency summary

| Operation | Cost |
|---|---|
| Menu open, nothing changed | 1 request, ~100 bytes (`/api/stats`) |
| Open a synced platform | 0 requests; `PackedInt64Array` seek per visible row |
| Scroll | O(visible rows); ≤ 4 concurrent art fetches, cancelled on scroll-away |
| Search a synced platform | 0 requests, in-RAM `PackedStringArray` scan |
| Full sync, 1328 ROMs | 2 requests, ~4 MB |
| Full sync, 100k ROMs | 100 requests, ~320 MB, threaded + resumable + one-time |
| Delta sync | 1–2 requests unless the library actually changed |
| RAM per open platform | ~3 MB at 100k rows (offsets + ids + lowercased names) |
| Node count | ~visible + 4, regardless of library size |

---

## Verification

**Headless (Godot 4.7, `_console.exe`)** — after any `class_name` addition the global cache must
be regenerated or probes fail to resolve the new types:

```
"$godot" --headless --path "$proj" --editor --quit     # filter: SCRIPT ERROR|Parse Error|Failed to
```

**Probes** (throwaway `probe.gd` + `probe.tscn` in `RetroXR/`, deleted afterwards, each with a
`create_timer(...)` quit safety net), printing `[probe] …`:

1. `RommClient.heartbeat` against `192.168.0.106:8080` → assert version `5.0.0`; assert an
   unauthenticated `/api/roms` gives 403 and an authenticated one gives 200.
2. `RommCatalog` sync of one platform → assert `total` matches `/api/stats`, `index.jsonl` line
   count == total, and random-access row N round-trips (`_offsets` seek → same id as `_ids[N]`).
3. Cover fetch **without** an auth header → 200 + a decodable `Image`.
4. `RommDownloader` on a small ROM: kill it mid-transfer, restart, assert `.part` resume produces
   a byte-identical file (MD5 vs `md5_hash`).
5. End-to-end: download → `media/label/` written → `gamelist.json` merged →
   `RomLibrary.scan_roms` now returns it → `MediaDimensions.load_label_texture` returns non-null.
6. Eviction: set budget to 1 MB, download two files, assert the LRU one is gone, the manifest is
   consistent, and a hand-copied ROM in the same folder is untouched. Then assert a download
   larger than the whole budget is **refused up front**, not started and abandoned.
7. **Error matrix** — drive each row of the table with a stub server (or by pointing `base_url` at
   a throwaway local responder): 403 → exactly **zero** retries and an auth-specific message;
   404 → `.part` deleted and a delta sync queued; 5xx → exactly 3 attempts with 2/4/8 s spacing;
   truncated body → size mismatch caught, one restart, then terminal. Assert **one** toast per
   failure, not one per attempt.
8. **No partial file is ever visible as a ROM**: start a large download, kill it mid-flight, then
   run `RomLibrary.scan_roms` — assert the `.part` does not appear.
9. **Clean shutdown mid-download**: start a download, quit the app, assert the process exits
   within ~1 s (the `_abort` flag + `wait_to_finish()` path) rather than hanging on the socket.
10. **Notifications**: run a sync and two downloads concurrently and assert the toast stack shows
    three independent bars that update in place (never one bar per progress tick, never one per
    retry), that a failure dwells ~6 s while a success dwells ~2.5 s, that >4 concurrent
    operations collapse to "+N more", and that outcomes occurring while the menu is closed are
    coalesced into a single summary toast on next open.
11. **Main-thread stall check**: while a sync and a download are both running, sample
    `Performance.get_monitor(Performance.TIME_PROCESS)` over 300 frames and assert no frame
    exceeds ~11 ms attributable to RomM work. This is the objective test for "doesn't freeze the
    game" — everything else in the threading contract is a means to this end.

**Glyph sheet — done 2026-07-25.** All four state icons rendered at real row size in a mock row
layout; findings folded into Phase 4 above (row-size trash-can ambiguity, emoji clash, cloud
glyph weight). Still outstanding: confirm the 40 px icons are hittable and legible **through the
headset lens**, which a desktop PNG cannot answer — check it in the on-device pass below.

**Visual proof (required — headless cannot confirm how it looks).** Render the merged Cartridges
tab into a `SubViewport` on the real display (`DISPLAY=:0`, `own_world_3d`, `cam.current = true`,
8 `process_frame`s then `RenderingServer.frame_post_draw`) and surface the PNG inline. Cover
grid, download badges and marquee titles all need eyeballing. For the download progress + spawn
animation, capture an **mp4** (`imageio` + `imageio-ffmpeg`, 15 fps, libx264/yuv420p), not a GIF.

**On-device (Quest, unattended over adb).** Export, `adb install -r`, then all three of:
`am broadcast -a com.oculus.vrpowermanager.prox_close`, `setprop debug.oculus.guardian_pause 1`,
`monkey -p com.xenu.retroxr 1`. Stream `adb logcat -s godot:*` from *before* launch (the ring
buffer rotates in under a minute). Specifically measure: scroll frame time over a 1000+ row list,
RAM after opening the largest platform, and a large-ISO launch to confirm the Phase 0 fix.
Watch for the stale-`.gdc` export trap — `rm -rf RetroXR/android/build/src/main/assets` if an
on-device change doesn't take.

---

## Known gotchas (collected during research)

- **`platform_ids`**, plural and repeatable. `platform_id` silently does nothing.
- **`limit=0` → 422.** Minimum is 1; use `limit=1` and read `total`.
- **`rom_id_index` ships on every `/api/roms` response** in 5.0.0 and cannot be turned off here.
- **`path_cover_*` is `""` when absent**, not `null`, despite the OpenAPI type.
- **`?ts=` contains spaces and colons** (a raw Python datetime) — percent-encode the query.
- **Never construct art paths.** If `ENABLE_SCHEDULED_CONVERT_IMAGES_TO_WEBP` is ever enabled the
  extension changes to `.webp`; always use the returned path verbatim (Godot decodes WebP fine).
- **`rom_user` has no `is_favorite` and no `note`.** Favorites are a *collection*
  (`/api/roms?favorite=true`); notes are `has_notes` + `GET /api/roms/{id}/notes`.
- **403 carries no `WWW-Authenticate`** — no challenge-response; send credentials proactively.
- **Never use `OptionButton` or `ACTION_MODE_BUTTON_PRESS` in the VR panel** — every
  `Viewport2Din3D` click fires twice. Use `VRDropdown`.
- **Don't `grab_focus()` a `LineEdit` programmatically** (Android EditText desync, Godot #72969);
  reuse `_add_options_text_field`'s keyboard-bounce cooldown.
- **`FileAccess.file_exists("res://…")` is false in exported builds** — use `ResourceLoader.exists()`.
- **Warnings are errors** for `:=` inference from a `Variant` — annotate explicitly
  (`var x: Dictionary = json.data`).
- **A `SubViewport` with `UPDATE_ALWAYS` hangs a headless run** — test logic headless, eyeball visuals on the display.
- RomM moves fast (5.0.0 shipped 2026-07-15, ten days before this plan). Gate on
  `heartbeat.SYSTEM.VERSION` and degrade with a clear message rather than assuming params exist.

---

## Out of scope (noted, not planned)

- **Streaming a disc over HTTP Range through a libretro VFS shim** instead of downloading it.
  `EnvironmentHandler` already implements the VFS interface, so a network-backed file handle is
  technically reachable — but latency-sensitive disc seeks over WiFi are a research project, not a
  feature. Phase 0 + a resumable download is the pragmatic answer.
- Save/state sync via `/api/saves`, `/api/states`, `/api/sync/negotiate` — a natural follow-up
  (that protocol covers saves/states *only*, never the library).
- Firmware/BIOS pull from `/api/firmware?platform_id=` — small, useful, and worth doing right
  after Phase 5.
- Collections / smart collections as a browsing axis (`collection_id`, `virtual_collection_id`)
  — the client-side pieces all generalise to it once per-platform browsing works.
- Writing back `last_played` / play state to the server.
