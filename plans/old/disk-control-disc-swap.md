# Plan: Disk control — physical disc eject/swap for multi-disc games (PSX)

## Context

Multi-disc games (FF7: "insert disc 2") are unplayable. The libretro disk-control
interface **is received and stored** — `EnvironmentHandler::SetDiskControlExtInterface`
saves `m_disk_control_ext_callback`, `GetDiskControlInterfaceVersion` returns 1
(`EnvironmentHandler.cpp:557-574`) — but nothing ever *calls* those function pointers, so
there is no eject/swap path to GDScript. When the game asks for the next disc, you're stuck.

**No `.m3u` needed.** The interface's `replace_image_index(index, retro_game_info*)`
(`libretro.h:5342`) lets the frontend hand the core a **brand-new disc file on the fly** —
this is what RetroArch's "Load New Disc" uses. So each disc is just an ordinary, independent
cartridge (its own `.cue`/`.chd`), and a swap, while the system stays **on**, is:

1. pull disc 1 out → `set_eject_state(true)` (tray open, game keeps running)
2. put disc 2 in → `replace_image_index(current_index, disc2)` → `set_eject_state(false)`

Purely physical — no menu, no linked disc set, no playlist. These callbacks must run on the
**emulation thread** between frames (same rule as savestates/SRAM), so the fix threads an
eject/replace path from the emu thread out to GDScript and drives it from the cartridge
insert/remove the system already handles. Swaps are **host-authoritative and frame-scheduled**
so netplay peers swap deterministically on the same frame.

## Layer 1 — C++: expose the disk-control path (libretro-godot/src)

**EnvironmentHandler** (`.hpp`/`.cpp`) — public methods wrapping the stored callbacks,
preferring the ext callback, falling back to v0 `m_disk_control_callback`, all null-guarded:
- `bool HasDiskControl() const` (any callback registered — decides eject-vs-poweroff),
  `unsigned GetDiskImageIndex() const`, `unsigned GetDiskImageCount() const`,
  `bool GetDiskEjected() const`,
- `bool SetDiskEjected(bool)`, `bool SetDiskImageIndex(unsigned)`,
- `bool ReplaceDiskImage(unsigned index, const std::string& path)` — build a
  `retro_game_info{ path, nullptr, 0, nullptr }` (PSX cores are `need_fullpath`, so the path
  suffices; mirror how `Core`/`Wrapper` build game info in `retro_load_game` for the
  non-fullpath case) and call `replace_image_index`.

**EmuThreadCommands** (`.hpp`/`.cpp`) — new emu-thread commands (drained between frames at
`Wrapper.cpp:1349`), mirroring `EmuThreadCommandSaveState`:
- `EmuThreadCommandDiskInfo` → read has-control/count/index/ejected, then
  `EmitSignalOnMainThread("disk_control_ready", …)`.
- `EmuThreadCommandSetDiskEjected(bool)` and
  `EmuThreadCommandReplaceDisk(unsigned index, std::string path)` (replace at index; the file
  is already selected, so the caller closes the tray after). Each re-emits `disk_control_ready`.

**Wrapper** (`.hpp`/`.cpp`) — `RequestDiskInfo()`, `SetDiskEjectState(bool)`,
`ReplaceDiskImage(uint32_t index, String path)` enqueue those commands (guard
`m_core`/`m_running`, mirror `RequestSaveState` at `Wrapper.cpp:554`). Netplay scheduling
(Layer 3): `ScheduleDiscOp(int64_t frame, int op, uint32_t index, String path)` stores into a
new `std::map<int64_t, DiscOp> m_disk_schedule` guarded by `m_np_mutex`; the emu loop applies
any op whose frame == the frame about to run, right where `m_np_inputs` is consumed.

**Libretro node** (`.hpp`/`.cpp`) — forward + `bind_method` each; add
`ADD_SIGNAL("disk_control_ready", has_control: BOOL, count: INT, current_index: INT,
ejected: BOOL)` beside the existing signals (`Libretro.cpp:249-258`). Rebuild all 4 targets.

## Layer 2 — GDScript: physical eject/swap (RetroXR/Scripts/Objects/systems/system.gd)

Each PSX disc is an ordinary `RetroCartridge` spawned from the menu — **no cartridge changes,
no `.m3u`, no `disc_index`.** The whole feature is in the system's insert/remove handlers,
replacing "remove ⇒ power off" when the core owns a disk-control interface:
- Cache disk state: connect `_libretro.disk_control_ready` → store `_has_disk_control`,
  `_disc_index`, `_disc_ejected`; call `_libretro.RequestDiskInfo()` after `power_on`'s
  `StartContent` (`system.gd:337`).
- `_on_cartridge_removed` (`:730`): if `is_powered_on and _has_disk_control` → **tray eject**
  (`SetDiskEjectState(true)`, `_disc_ejected = true`); stay powered, keep the running
  `rom_path`. Otherwise the current power-off path (cart consoles / no disk control unchanged).
- `_on_cartridge_inserted` (`:715`): if `is_powered_on and _disc_ejected` and the inserted
  cartridge carries a real disc path → **swap without reload**:
  `ReplaceDiskImage(_disc_index, cartridge.get_rom_path())` then `SetDiskEjectState(false)`;
  update `rom_path` to the new disc. If the system is *off*, today's insert→power-on path is
  unchanged (a fresh boot).
- All of the above is a no-op when `_has_disk_control` is false, so every existing console
  behaves exactly as before.

No new UI — swapping is purely physical (pull the disc, drop in the next).

## Layer 3 — Netplay: host-authoritative, frame-scheduled swap (object_sync + system.gd)

A swap changes deterministic core state, so all peers must apply it on the **same frame**.
Mirror the `EV_VCR_CMD` client-intent→host pattern (`object_sync.gd`), tagged with a frame
and the disc's content id (peers must have the file):
- New `EV_DISK_OP  # {sys, op, md5}` (client → host intent; op = eject | replace) and a
  host→peers broadcast `{sys, op, md5, frame}`.
- While a netplay session is active, `system.gd`'s eject/insert sends **intent** instead of
  applying locally. The host picks `apply_frame = last_confirmed + LEAD`, ensures the disc
  file is available to all peers (reuse `NetFileTransfer` md5 resolution — already used at
  `system.gd:437`), then broadcasts; every peer (incl. host) calls
  `_libretro.ScheduleDiscOp(frame, op, index, resolved_path)`.
- The emu thread applies the scheduled op exactly before running `apply_frame` (Layer 1), so
  all cores stay identical; the existing RAM-CRC (`EmitNetplayCrc`) guards against desync.

## Verification

1. Rebuild C++ (4 targets); headless `--editor --quit` compile check.
2. **Plumbing probe** (throwaway `Tools/disk_probe.gd`, deleted after): with no core loaded,
   assert `RequestDiskInfo` emits `disk_control_ready(has_control=false, …)` and that
   `SetDiskEjectState` / `ReplaceDiskImage` are safe no-ops (mirror the savestate probes).
3. **Real swap** (if a PSX core + two small disc images are installed): load disc 1, assert
   `has_control` true; `SetDiskEjectState(true)` → `ReplaceDiskImage(0, disc2)` →
   `SetDiskEjectState(false)`; assert `GetDiskImageIndex`/no crash and the frame counter keeps
   advancing (game still running).
4. **Physical probe** (`Tools/disc_swap_probe.gd`): power a system on with a disc-control
   stub, simulate `_on_cartridge_removed` then `_on_cartridge_inserted` of a second disc;
   assert the system stayed powered and issued eject→replace→insert (spy on Libretro calls)
   instead of power-cycling; and that a non-disk-control console still powers off on removal.
5. Netplay: extend the `netplay_spike` determinism run — a scripted swap at a fixed frame on
   two peers must keep RAM-CRCs identical afterward.
6. On-device: FF7 to the disc-2 prompt; pull disc 1, insert disc 2, game continues.

## Out of scope / follow-ups
- Auto-detecting *when* the game asks for a disc (cores don't signal it — swap when prompted).
- Persisting the active disc across a scene reload (tied to savestates, not object placement).
- `.m3u` playlists (not needed given `replace_image_index`, but they'd still load fine as a
  single cartridge if a user has one).
