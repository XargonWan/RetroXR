# Core Known Issues

Behaviour that belongs to a libretro core rather than to RetroXR, found the hard
way. Each entry says what was measured, not what the documentation claims.

# Memory cards

## pcsx_rearmed — the four slot modes

`pcsx_rearmed_memcard1` (values `libretro` / `serial` / `shared` / `none`,
default `libretro`) and `pcsx_rearmed_memcard2` (`serial` / `shared` / `none`,
default `shared`). Measured by booting FF7 against the core and looking at what
appeared in the save directory:

| Mode | File | Who can see it |
|---|---|---|
| `libretro` (slot 1 only) | none — the card IS `RETRO_MEMORY_SAVE_RAM` | whatever the frontend mounts |
| `serial` | `<SERIAL>_<slot>.mcd`, e.g. `SCUS-94163_2.mcd` | that one game only |
| `shared` | `pcsx-card2.mcd` | every PS1 game |
| `none` | — | slot empty at the SIO level |

`serial` is worth recognising: it is a private card per game, which is exactly
the behaviour RetroXR had before real cards landed, and exactly why nothing
could read anything another game wrote.

RetroXR forces `memcard1` from card presence and pins `memcard2 = "none"`
(`RetroSystem._removable_media_options`). The cabinet has one card slot, so slot
2 is said to be empty rather than left on the core's `shared` default, which is
an invisible permanent card no object in the room accounts for.

## "No card" cannot be expressed through SAVE_RAM

`retro_get_memory_data(RETRO_MEMORY_SAVE_RAM)` always returns a 128 KB buffer,
so an unbacked run is indistinguishable from a blank card. Worse, pcsx_rearmed
fills that buffer with a **fully formatted** card — measured md5
`d8f29ffd55cb1e4f77987a1e07472d66`, byte-identical to the blank it writes for
`memcard2=shared`. A PSX with no card seated would therefore accept a save,
report success, and lose it at power-off.

Two mitigations, both in place:

* `Wrapper::SetRemovableStorage(true)` blanks SAVE_RAM when nothing is seated, so
  the game reports unformatted media instead of silently eating the save. Opt-in
  because a fixed-storage core may initialise SAVE_RAM to `0xFF` (flash/EEPROM)
  and zeroing that would fake corrupt data, and a netplay client legitimately
  runs with an empty path and empty bytes.
* `pcsx_rearmed_memcard1 = "none"` is the real fix: it sets `McdDisable[0]`, and
  `sioWrite8`'s `0x81` handler then jumps to `no_device`, which is what the
  hardware does. Confirmed: `none` makes `retro_get_memory_size(SAVE_RAM)` return
  **0**, where `libretro` returns 131072.

**The option is read at content load, not per frame** (labelled "(Restart)").
So a card *pulled mid-game* still reports unformatted rather than absent until
the next power cycle. Inserting mid-game does work, because SAVE_RAM stays live.
Making removal authentic needs a core patch: flip `McdDisable[0]` from
`update_variables()` instead of only from `load_memcards()`.

Slot 2 can never be a physical card object under `libretro` mode — SAVE_RAM is a
single buffer. A second real slot would need the core to accept a path per slot.

## pcsx_rearmed builds before ~2026-03 have no `memcard1` option

The build shipped 2026-03-06 declared 60 options and only `pcsx_rearmed_memcard2`;
the current nightly declares 64 and includes `pcsx_rearmed_memcard1`. On the older
core there is no way to reach `McdDisable`, so "no memory card" is unreachable and
the option never appears in the OPTIONS menu — the menu lists what the core
declares. Setting the key anyway is harmless on the old build, which is why
`_removable_media_options` writes it unconditionally.

The old option used `enabled` / `disabled`; the new one uses `serial` / `shared` /
`none`. A stale `pcsx_rearmed_memcard2 = "disabled"` is **not** silently promoted
to the new `shared` default — measured, it reads as off, same as `none`. Harmless,
but the value is meaningless to the new core and is now overwritten.

## Dolphin — no SAVE_RAM at all, and hot-swap is there but unreachable

`dolphin_libretro` returns 0 from `retro_get_memory_size(RETRO_MEMORY_SAVE_RAM)`.
It manages `save/dolphin/User/GC/<region>/Card A/` itself, shared by every game,
so the frontend's SRAM path is a no-op for GameCube and no save ever reaches
`SaveSync`.

Dolphin itself has a proper card-swap primitive —
`ExpansionInterfaceManager::ChangeDevice()` (`Source/Core/Core/HW/EXI/EXI.cpp`)
schedules `EXIDeviceType::None` immediately and the real device one full emulated
second later ("Let the hardware see no device for 1 second"), and
`CEXIChannel::AddDevice(…, notify_presence_changed = true)` raises `EXTINT`. That
is a genuine eject/insert, and it is what the GUI does mid-game.

**The blocker is `DolphinLibretro`, which contains no memory-card code at all.**
Its entire involvement with saves is three lines in `Boot.cpp` pointing Dolphin's
`User` dir at `<save_dir>/User`. No memcard option exists, so nothing ever calls
`ChangeDevice`.

Writing `Dolphin.ini` mid-run cannot work alone: the path is read once in the
device constructor (`SetupGciFolder` / `SetupRawMemcard` in
`EXI_DeviceMemoryCard.cpp`). But `ChangeDevice` *reconstructs* the device, so it
would pick up a changed path. Override key is `GCIFolderAPath`; the default with
an empty config is `{D_GCUSER_IDX}{region}/Card A`, which is what is on disk.

A patch would add an enumerated `dolphin_memcard_a_slot` option (libretro options
are fixed value lists, so an index, not a free path) and, on
`Options::IsUpdated(...)`, set `Config::MAIN_GCI_FOLDER_A_PATH` then call
`ChangeDevice`. The plumbing exists: `CheckForUpdatedVariables()` runs every frame
from `retro_run`, and `EFB_SCALE` is the template.

# Dolphin — the Vulkan backend trips the Adreno GPU watchdog on Quest

Booting a Wii/GameCube game with Dolphin's **Vulkan** backend in the arcade room
kills the GPU within seconds: the GMU reports `MISC: GPU hang detected`, the
`VkDevice` is lost permanently, and every later submit returns
`VK_ERROR_DEVICE_LOST`. Audio and input keep running, so it presents as a black
(later white) screen rather than a crash.

**Workaround: run Dolphin on GLES3** — `Libretro.SetPreferredHwRender(5)` before
`StartContent`. Measured working; the OpenGL path has no equivalent contract and
is unaffected.

## It is GPU contention, not a bug in the frontend

Same core, same ROM, same Vulkan path; the only variable is how much GPU work
Godot is doing:

| Condition | Result |
|---|---|
| Arcade room rendering | GPU hang in 2-3 s, every time |
| `Tools/gl_video_probe` as main scene (no room) | 95 s clean; 0 hangs, `reset_count` unchanged |
| Passthrough, room not drawn | ~25 minutes |

Meta documents that the compositor **preempts the application's GPU workload**
every frame to hit its cadence (the `Preempt` render stage in
`documentation/native/android/ts-renderdoc-renderstage`), and kgsl's
`ft_long_ib_detect` is on (`/sys/class/kgsl/kgsl-3d0/`), which times a submission
in wall-clock — preemption gaps included. Godot renders 2064x2163 per eye at
72 Hz on the same GPU.

Ruled out by measurement, so do not re-investigate: the Android surface size, the
`AImageReader` never being drained, the sync-index count, our readback entirely
(built with `ReadbackToPixels` submitting nothing — still hangs), and Vulkan API
misuse (validation is silent until ~10 s after the hang, and what it then reports
is Dolphin's own code on an already-dead device). There are no page-fault lines
anywhere in the logs, so it is a timeout and not a bad memory access.

## What DolphinLibretro's Vulkan glue actually does

Read this before theorising about the surface (`DolphinLibretro/Vulkan.cpp`):

* It **fakes the whole swapchain**. `vkCreateSwapchainKHR` allocates plain
  offscreen images — `popcount(get_sync_index_mask())` of them, so that mask
  decides how many images the CORE allocates — and it never presents to our
  surface. `vkGetPhysicalDeviceSurfaceCapabilitiesKHR` is hooked to override
  `currentExtent` with Dolphin's own size, so the surface's dimensions are never
  read by anything.
* `vkAcquireNextImageKHR` -> `wait_sync_index()` then `get_sync_index()`.
* `vkQueuePresentKHR` -> `set_image(..., 0, nullptr, ...)` — zero semaphores.
* `vkQueueSubmit` **strips every wait and signal semaphore**, then submits under
  `lock_queue`. `set_command_buffers` and `set_signal_semaphore` are both `#if 0`.

So `wait_sync_index()` is the only frontend/core synchronisation in the pipeline.

## The frontend cannot reach Dolphin's device on Android

`create_instance` and `create_device2` are both inside `#ifdef __APPLE__`
(`DolphinLibretro/Video.cpp`), so on Android Dolphin offers **only v1
`create_device`**. v1 passes a flat `VkPhysicalDeviceFeatures` with no `pNext`
chain and the core builds its own `VkDeviceCreateInfo`. Consequences:

* `VulkanContext::s_CreateDeviceWrapper` is dead code on Android (v2 only).
* `VK_EXT_device_fault` can be forced in via `required_device_extensions` (a core
  must honour those, and Dolphin merges them with `AddNameUnique`) but its
  `VkPhysicalDeviceFaultFeaturesEXT` feature bit cannot. Tried: the driver accepts
  `vkGetDeviceFaultInfoEXT` and returns an empty description with zero address and
  zero vendor records.
* `VK_EXT_global_priority` needs `VkDeviceQueueGlobalPriorityCreateInfoEXT`
  chained into queue creation, inside Dolphin's create-info. Unreachable.

Driver crash dumps are closed on retail hardware too: `/sys/class/kgsl/kgsl-3d0/snapshot/`
is permission-denied, `setprop panel.gpuSnapshotPath` is refused, and
`ft_long_ib_detect` is root-only so the watchdog cannot be extended to test the
timeout directly. A real root cause needs a Dolphin patch — we ship our own build.

# Reading a core's options without running RetroXR

Both the option list and these behaviours were measured with a ~60-line ctypes
harness: `CDLL` the core, supply an environment callback answering
`GET_SYSTEM_DIRECTORY` (9), `GET_SAVE_DIRECTORY` (31), `GET_CAN_DUPE` (3),
`SET_PIXEL_FORMAT` (10) and `GET_VARIABLE` (15) with the overrides under test,
stub the five `retro_set_*` callbacks, then `retro_init` + `retro_load_game` and
inspect `retro_get_memory_size` / the save directory. It runs a real core against
a real ROM in about a second and needs no Godot, which makes it the fastest way to
settle "what does this core actually do".

A plain strings sweep of the DLL for `<core>_[a-z0-9_]+` also recovers the full
option key list, which is how the missing `memcard1` was spotted.
