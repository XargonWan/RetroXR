# Plan: Libretro Core Downloader, Manager & Dynamic Spawning

**TL;DR:** Add a Core Downloader (HTTP fetch from buildbot, zip extraction, persistence), Core Manager (default core selection per system), and dynamic system spawning to the RetroXR spawn menu. The existing `SpawnMenu2D` gets a top-level navigation bar with "Spawn" (existing content) and "Cores" (new Download/Manager sub-tabs). Persistence uses two separate JSON files. Existing `system_*.tscn` files get their `core_directory` updated to the new default path. The plan is split into 5 phases.

---

## Phase 1: Core Info Data Layer

Parse all `.info` files from the `libretro-core-info/` submodule into a queryable in-memory structure.

### Steps

1. Create `RetroXR/Scripts/Data/cores/core_info_parser.gd` — `class_name CoreInfoParser` (static utility)
   - `static func parse_info_file(path: String) -> Dictionary` — reads a single `.info` file line-by-line, splits on ` = `, strips quotes, returns a dict with keys: `display_name`, `corename`, `systemname`, `systemid`, `license`, `description`, `supported_extensions`, `manufacturer`, etc.
   - `static func parse_all(directory: String) -> Array[Dictionary]` — iterates all `*.info` files in `libretro-core-info/` using `DirAccess`, calls `parse_info_file` on each, returns array of dicts.

2. Create `RetroXR/Scripts/Data/cores/core_info_database.gd` — `class_name CoreInfoDatabase` (runtime singleton-like object, owned by spawn menu)
   - Holds `var cores: Array[Dictionary]` — all parsed core info entries
   - `func get_by_core_name(name: String) -> Dictionary` — lookup by filename stem (e.g. `"fceumm"`)
   - `func get_by_systemid(id: String) -> Array[Dictionary]` — all cores for a given system
   - `func get_unique_systemids() -> Array[String]` — distinct system IDs across all parsed cores
   - `func get_systemname_for_id(id: String) -> String` — human-readable system name for a systemid
   - Filename convention: `{core_name}_libretro.info` maps to core_name by stripping `_libretro.info`

3. The `.info` files path should be resolved relative to the project: `res://libretro-core-info/` won't work if it's outside the Godot project root. Since `libretro-core-info/` is at the workspace root (sibling to `RetroXR/`), the parser needs an absolute path. Store this as a constant or make it configurable. The resource path is likely `res://../../libretro-core-info/` or pass via an export — confirm at implementation time.

### Verification

Print `CoreInfoDatabase.cores.size()` and spot-check `get_by_core_name("fceumm")` returns correct `display_name`.

---

## Phase 2: Download Infrastructure & Persistence

HTTP fetching, zip extraction, and download state tracking.

### Steps

1. Create `RetroXR/Scripts/Data/cores/core_download_manager.gd` — `class_name CoreDownloadManager extends Node` (needs to be in the tree for `HTTPRequest` children)
   - **Constants:** `DEFAULT_CORE_DIR` = `OS.get_environment("USERPROFILE") + "/retroxr/libretro"`, `CORES_SUBDIR` = `"cores"`, `BUILDBOT_URL` = `"https://buildbot.libretro.com/nightly/windows/x86_64/latest/"`
   - `func ensure_directories()` — creates `DEFAULT_CORE_DIR/cores/` via `DirAccess.make_dir_recursive_absolute()` if not present
   - `func fetch_available_cores(callback: Callable)` — adds an `HTTPRequest` child, fetches the buildbot HTML page, parses the directory listing to extract `.dll.zip` filenames and last-modified dates. The buildbot page is an Apache autoindex — parse `<a href="...">` tags with regex, extract the date from the adjacent `<td>` text. Returns an `Array[Dictionary]` with keys `filename`, `core_name` (stem without `_libretro.dll.zip`), `remote_date`.
   - `func download_core(core_name: String, progress_callback: Callable, done_callback: Callable)` — downloads `{BUILDBOT_URL}/{core_name}_libretro.dll.zip` via `HTTPRequest`, reports progress via callback, on completion extracts with `ZIPReader` to `{CORE_DIR}/cores/`, deletes the zip, updates the manifest
   - `func get_core_state(core_name: String, remote_date: String) -> String` — returns `"Download"`, `"Re-Download"`, or `"UPDATE"` by comparing manifest entry vs remote date

2. Create `RetroXR/Scripts/Data/cores/download_manifest.gd` — `class_name DownloadManifest`
   - Reads/writes `{CORE_DIR}/cores_manifest.json`
   - Schema: `{ "cores": { "fceumm": { "downloaded_at": "2026-03-05T...", "remote_date": "...", "filename": "fceumm_libretro.dll" }, ... } }`
   - `func is_downloaded(core_name: String) -> bool`
   - `func get_download_date(core_name: String) -> String`
   - `func set_downloaded(core_name: String, remote_date: String)`
   - `func save()` / `func load_manifest()`

3. Handle edge case: buildbot may list cores not in `libretro-core-info/`. These should still appear in the download list with "CORE UNKNOWN" as description.

### Verification

Manually call `fetch_available_cores`, verify it returns a populated list. Download one core, verify the DLL appears in the cores directory and the manifest is updated.

---

## Phase 3: Download UI

The "Cores > Download" tab in the spawn menu.

### Steps

1. Refactor `RetroXR/Scripts/UI/spawn_menu/spawn_menu.gd` — restructure `_build_ui()`:
   - After the title bar/separator, add an `HBoxContainer` as a **top navigation bar** with two toggle `Button` nodes: **"Spawn"** and **"Cores"**
   - Below the nav bar, add a content area (a `Control` or `VBoxContainer`) that swaps its children based on which nav button is active
   - **"Spawn" view:** contains the existing `TabContainer` (Systems/TVs/Cartridges) — extract current tab logic into `_build_spawn_view() -> Control`
   - **"Cores" view:** contains its own `TabContainer` with two tabs: **"Download"** and **"Manager"** — build via `_build_cores_view() -> Control`
   - Nav button styling: active button gets a brighter/highlighted `StyleBoxFlat`, inactive gets dim. Toggle logic swaps visibility of the two views.

2. Implement `_build_download_tab() -> Control` in spawn_menu.gd (or a new file `RetroXR/Scripts/UI/core_download_tab.gd`):
   - **Top field**: `Label` showing the current core directory path (read from `CoreDownloadManager.DEFAULT_CORE_DIR + "/cores"`)
   - **Scrollable list**: `ScrollContainer` → `VBoxContainer`, populated after `fetch_available_cores` completes
   - Each core entry is an `HBoxContainer`:
     - Left side (`VBoxContainer`):
       - `display_name` — `Label`, font size ~22, bold
       - `license` — `Label`, font size ~16
       - `description` — `Label`, font size ~14, word-wrapped, max 2-3 lines (use `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART`, clip with `custom_minimum_size` or `max_lines`)
     - Right side: `VBoxContainer` containing:
       - Action `Button` — text is "Download" / "Re-Download" / "UPDATE" / "BUSY" based on state
       - `ProgressBar` — visible only during download, updated via progress callback
   - For unknown cores (no `.info` match): display filename as title, "CORE UNKNOWN" as subtitle
   - On button click: call `CoreDownloadManager.download_core()`, swap button text to "BUSY", show progress bar, on completion update button text

3. Add a **loading spinner/label** shown while the buildbot page is being fetched.

4. The `CoreDownloadManager` node needs to be in the scene tree. Add it as a child of `SpawnMenu2D` or `SpawnMenuController`. Since `SpawnMenu2D` lives in a SubViewport, the `HTTPRequest` should work fine there.

### Verification

Open spawn menu in VR, click "Cores" → "Download", verify the list populates. Download a core, verify progress bar works and button transitions to "Re-Download". Close and reopen menu, verify persisted state shows correctly.

---

## Phase 4: Manager UI & Core Defaults Persistence

The "Cores > Manager" tab for selecting default cores per system.

### Steps

1. Create `RetroXR/Scripts/Data/cores/core_defaults.gd` — `class_name CoreDefaults`
   - Reads/writes `{CORE_DIR}/core_defaults.json`
   - Schema: `{ "defaults": { "nes": "fceumm", "super_nes": "snes9x", ... } }`
   - `func get_default_core(systemid: String) -> String` — returns core_name or empty
   - `func set_default_core(systemid: String, core_name: String)`
   - `func save()` / `func load_defaults()`

2. Implement `_build_manager_tab() -> Control` in spawn_menu.gd (or `RetroXR/Scripts/UI/core_manager_tab.gd`):
   - Scan the cores directory for downloaded `*_libretro.dll` files
   - For each DLL, look up its `.info` to get `systemid` and `systemname`
   - Group by `systemid` — only show systems that have at least one downloaded core
   - Each row: `HBoxContainer` with:
     - `Label` showing `systemname` (e.g. "Nintendo Entertainment System")
     - `OptionButton` dropdown listing all downloaded cores for that system (display `corename` or `display_name`), pre-selected to the current default from `CoreDefaults`
   - On `OptionButton.item_selected`: update `CoreDefaults`, save to JSON
   - If a systemid has only one core downloaded, still show the dropdown (single option, auto-selected as default)

3. Emit a signal `default_core_changed(systemid: String, core_name: String)` from the manager so other systems can react.

### Verification

Download 2+ cores for the same system (e.g. `fceumm` and `nestopia` for NES). Open Manager tab, verify both appear in the dropdown. Select one, close menu, reopen — verify selection persisted.

---

## Phase 5: Dynamic System Spawning

Wire the Manager's defaults into the Spawn tab and existing system scenes.

### Steps

1. Update the **"Spawn > Systems" tab** in `_build_spawn_view()`:
   - Instead of the hardcoded `[["NES System", "nes"]]` array, dynamically build the list from `CoreDefaults` — for each systemid that has a default core set, add a spawn button labeled with the `systemname`
   - Pass the `systemid` as the spawn type string

2. Update `RetroXR/Scripts/UI/spawn_menu/spawn_menu_controller.gd`:
   - Remove hardcoded `NES_SCENE` constant (keep `TV_SCENE` and `CART_SCENE`)
   - Load the base `system.tscn` for system spawns: `const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")`
   - In `_on_spawn_requested(type)`: if type matches a known systemid, instantiate `SYSTEM_SCENE`, set `core_name` from `CoreDefaults.get_default_core(systemid)`, set `core_directory` to the configured core path, set `system_label` from `CoreInfoDatabase`

3. Update existing `system_*.tscn` files:
   - Change `core_directory` exports from `"C:/Users/user/libretro"` to the new default path (`OS.get_environment("USERPROFILE") + "/retroxr/libretro"`)
   - Keep these scenes for backward compatibility / pre-configured setups

4. Handle **live default changes**: already-spawned `RetroSystem` nodes should reference the live default rather than a snapshot. In `RetroXR/Scripts/Objects/systems/system.gd`, in `power_on()`, if `core_name` is empty, look up the default from `CoreDefaults` for the system's `systemid`. This means adding a `systemid` export to `RetroSystem` (or deriving it from the spawn type).

5. Add a `systemid` export to `RetroSystem` alongside the existing `core_name`. When `power_on()` is called:
   - If `core_name` is set, use it directly (backward compat with existing .tscn files)
   - If `core_name` is empty but `systemid` is set, look up the current default core from `CoreDefaults`

### Verification

Download NES and SNES cores. Set defaults in Manager. Open Spawn tab — verify NES and SNES systems appear. Spawn one, connect to TV, insert cartridge, power on — verify it loads the default core. Change default in Manager, spawn another — verify it uses the new default.

---

## Decisions

- **UI structure:** Top bar with "Spawn" / "Cores" toggle buttons, content area swaps below. "Cores" contains its own TabContainer with "Download" / "Manager" tabs.
- **Persistence:** Two separate JSON files — `cores_manifest.json` (download state) and `core_defaults.json` (default core per system) — both in the core directory.
- **Existing .tscn files:** Kept but updated with new default `core_directory` path. Dynamic spawning uses the base `system.tscn`.
- **Core info path:** The `libretro-core-info/` submodule is at the workspace root, outside the Godot project. The parser will need an absolute path or a project-relative workaround (e.g., symlink into `RetroXR/`, or pass the path at runtime).
- **Buildbot HTML parsing:** Apache autoindex format — extract `<a href="*.dll.zip">` entries with regex. File dates for UPDATE detection come from the HTML listing or HTTP `Last-Modified` headers.
- **Phase order:** Data layer → Download infra → Download UI → Manager UI → Dynamic spawning. Each phase is independently testable.

---

## New Files Summary

| File | Class | Purpose |
|---|---|---|
| `RetroXR/Scripts/Data/cores/core_info_parser.gd` | `CoreInfoParser` | Parse `.info` files |
| `RetroXR/Scripts/Data/cores/core_info_database.gd` | `CoreInfoDatabase` | Query parsed core info |
| `RetroXR/Scripts/Data/cores/core_download_manager.gd` | `CoreDownloadManager` | HTTP fetch, zip extract, download orchestration |
| `RetroXR/Scripts/Data/cores/download_manifest.gd` | `DownloadManifest` | Track downloaded cores (JSON persistence) |
| `RetroXR/Scripts/Data/cores/core_defaults.gd` | `CoreDefaults` | Track default core per systemid (JSON persistence) |
| `RetroXR/Scripts/UI/core_download_tab.gd` | (optional) | Download tab UI builder |
| `RetroXR/Scripts/UI/core_manager_tab.gd` | (optional) | Manager tab UI builder |

## Modified Files Summary

| File | Changes |
|---|---|
| `RetroXR/Scripts/UI/spawn_menu/spawn_menu.gd` | Add top nav bar, restructure into Spawn/Cores views |
| `RetroXR/Scripts/UI/spawn_menu/spawn_menu_controller.gd` | Dynamic system spawning, remove hardcoded NES_SCENE |
| `RetroXR/Scripts/Objects/systems/system.gd` | Add `systemid` export, look up default core in `power_on()` |
| `RetroXR/Scenes/Objects/system_nes.tscn` | Update `core_directory` to new default path |
| `RetroXR/Scenes/Objects/system_snes.tscn` | Update `core_directory` to new default path |
| `RetroXR/Scenes/Objects/system_n64.tscn` | Update `core_directory` to new default path |
| `RetroXR/Scenes/Objects/system_ps1.tscn` | Update `core_directory` to new default path |
