# Libretro Rumble → VR/Desktop Haptic Feedback

## Context

Libretro cores can request controller rumble via `RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE` (e.g. N64 rumble pak, PlayStation dual-shock rumble). The C++ bridge already accepts this interface — `InputHandler::RumbleInterfaceSetRumbleState` is wired up in `EnvironmentHandler.cpp:240` — but the implementation at `InputHandler.cpp:45-50` is a stub that only logs. Rumble requests never reach the player.

We want cores that trigger rumble to vibrate the physical controller holding the in-VR `RetroController` plugged into the libretro port issuing the rumble. In desktop mode (non-XR), the same path should vibrate connected physical gamepad(s) via `Input.start_joy_vibration`.

## Vocabulary

Three distinct things get called "port" in this codebase — pinning them here to keep the routing unambiguous:

- **Libretro port**: the emulated in-game controller slot (0..N-1) the running core thinks about. The core's `retro_set_rumble_state(port, effect, strength)` uses this. The core has no idea physical hardware exists.
- **Cabinet port**: the physical in-VR snap zone on the `RetroSystem` cabinet (`_port_zones[0..3]` in `system.gd:70`). When a `RetroController` snaps into `_port_zones[i]`, it is plugged into **libretro port `i`** — the two indices are identical by construction.
- **Joy device index**: Godot's `Input.get_connected_joypads()` index for a physical gamepad attached to the PC. Used by `Input.start_joy_vibration(device_idx, …)`.

Routing chain: core (libretro port) → `RetroSystem._port_controllers[port]` (the `RetroController` snapped into the matching cabinet port) → that `RetroController`'s physical holder (XR hand tracker *or* `_desktop_held`) → haptics API.

## Approach

Pipe the rumble callback across the emulation → main thread boundary using the same `call_deferred`-from-Wrapper pattern already used by `NotifyOptionsReady` (`Libretro.cpp:98-103`), emit a `rumble_state_changed(port, weak, strong)` signal from the `Libretro` node, and let `RetroSystem` route it to whichever `RetroController` is plugged into that port. The `RetroController` (which already tracks the holding/secondary `XRController3D`) converts the signal into an `XRToolsRumbleManager` indefinite event (VR) or `Input.start_joy_vibration` call (desktop).

Key design points:

- **Dedup at source**: cores call `set_rumble_state` every frame even when values haven't changed. Track last `(weak, strong)` per port in `InputHandler` and only `call_deferred` when a value actually changes. This keeps the main thread quiet.
- **No new ThreadCommand needed**: `call_deferred("emit_signal", …)` on the `Libretro* m_libretro_node` back-pointer is the same shortcut `NotifyOptionsReady` already uses — it's safe from the emulation thread.
- **Use `XRToolsRumbleManager` (autoload) rather than raw `XRServer.primary_interface.trigger_haptic_pulse`**. It's already registered in `project.godot:25`, supports indefinite events via `XRToolsRumbleEvent.indefinite = true`, combines weak/strong into a single magnitude via `combine_magnitudes()` at `rumble_manager.gd:46`, respects the user's haptics scale, and per-tick retriggers the pulse internally. Add with a stable event key (e.g. `self` — the `RetroController` instance) and `clear()` with the same key when rumble stops.
- **Per-system port→controller map**: `RetroSystem` already receives plug/unplug via `_on_port_snapped` / `_on_port_released` (`system.gd:358-373`) but doesn't cache the Node. Add a `_port_controllers: Array[Node]` sized to `_port_zones.size()`.
- **Strength normalization**: libretro `uint16_t` 0-65535 → float 0.0-1.0 at the C++ boundary before emitting the signal (cheaper than round-tripping a uint16). Division `strength / 65535.0f`.

## Files to modify

### C++ (libretro-godot/src/)

**`InputHandler.hpp`**
- Add private members to dedup:
  ```cpp
  std::unordered_map<uint32_t, uint16_t> m_rumble_weak;
  std::unordered_map<uint32_t, uint16_t> m_rumble_strong;
  ```
- `RumbleInterfaceSetRumbleState` stays `static`, same signature.

**`InputHandler.cpp`** (replace the stub at lines 45-50)
- Resolve the current wrapper via `Wrapper::GetCurrentThreadWrapper()` (same pattern as `StateCallback` at line 14).
- Update the appropriate per-port map entry for the effect.
- If the value actually changed, compute normalized floats from *both* weak and strong for that port, then:
  ```cpp
  instance->m_libretro_node->call_deferred(
      "emit_signal", "rumble_state_changed",
      (int)port,
      weak  / 65535.0f,
      strong / 65535.0f);
  ```
- Return `true`.
- Also clear both maps on content stop. Easiest: in `Wrapper::StopContent` (or equivalent shutdown path), emit one final `rumble_state_changed(port, 0, 0)` for any non-zero port before deletion so stale vibration cannot leak past core unload. (Safety — matches "core must explicitly zero" convention, but guards against crashy cores.)

**`Libretro.hpp`** — no API changes needed, only the signal registration in `_bind_methods` (declaration already exists).

**`Libretro.cpp`** (alongside the `options_ready` signal at line 170)
- Add in `_bind_methods`:
  ```cpp
  ADD_SIGNAL(MethodInfo("rumble_state_changed",
      PropertyInfo(Variant::INT,   "port"),
      PropertyInfo(Variant::FLOAT, "weak"),
      PropertyInfo(Variant::FLOAT, "strong")));
  ```
- No GDScript-callable method is needed — the signal is the API.

### GDScript (RetroVR/Scripts/Objects/)

**`system.gd`**
- Add `var _port_controllers: Array = [null, null, null, null]` alongside `_port_zones` (line 70).
- In `_ready` after the existing port-zone loop (line 87-90), connect:
  ```gdscript
  _libretro.rumble_state_changed.connect(_on_rumble_state_changed)
  ```
- In `_on_port_snapped` (line 358), cache: `_port_controllers[port_index] = controller`.
- In `_on_port_released` (line 367), clear the cached entry AND explicitly stop rumble on the *released* controller (call `set_rumble(0.0, 0.0)` on it) so a controller that unplugs mid-rumble goes silent.
- Add handler:
  ```gdscript
  func _on_rumble_state_changed(port: int, weak: float, strong: float) -> void:
      if port < 0 or port >= _port_controllers.size(): return
      var ctrl = _port_controllers[port]
      if ctrl and ctrl.has_method("set_rumble"):
          ctrl.set_rumble(weak, strong)
  ```
- In `power_off()` (line 265), zero any active rumble on all ports so switching off the cabinet mid-rumble stops the vibration. (Core should do this itself via final `retro_deinit`, but belt-and-suspenders — cores misbehave.)

**`retro_controller.gd`**
- Add state:
  ```gdscript
  var _rumble_weak:   float = 0.0
  var _rumble_strong: float = 0.0
  var _rumble_event:  XRToolsRumbleEvent = null
  ```
- Add method (called by `RetroSystem`):
  ```gdscript
  func set_rumble(weak: float, strong: float) -> void:
      _rumble_weak   = weak
      _rumble_strong = strong
      _apply_rumble()
  ```
- Add `_apply_rumble()` helper:
  - Compute combined magnitude via `XRToolsRumbleManager.combine_magnitudes(_rumble_weak, _rumble_strong)`.
  - **VR (held) path**: if `_holding_ctrl` or `_secondary_ctrl` are valid trackers, build (or reuse) an `XRToolsRumbleEvent` with `magnitude = combined`, `indefinite = true`, and call `XRToolsRumbleManager.add(self, _rumble_event, [trackers…])` with whichever trackers are holding. If combined == 0, `XRToolsRumbleManager.clear(self)`.
  - **Desktop (held) path**: `_desktop_held == true` → iterate `Input.get_connected_joypads()` and call `Input.start_joy_vibration(device, weak, strong, 0.0)` on each (0 duration = continuous). On zero, `Input.stop_joy_vibration(device)` on each. Vibrating all connected pads is the honest mirror of existing desktop input — `_process_desktop_joypad` at `retro_controller.gd:407-424` reads action-based input which already merges every connected pad into the same libretro-port input stream, so whichever physical pad is actually driving the game also gets its rumble. Single-pad (the common case) works perfectly; multi-pad just rumbles all of them uniformly, which is no worse than how input already works.
  - **Not held**: nothing to do. Bail silently (cable is unplugged but the physical hand isn't on it).
- Handle hand changes: when a hand grabs or drops the controller, re-apply so the new hand(s) pick up existing rumble. Call `_apply_rumble()` at the end of `_on_grabbed_signal` and `_on_dropped_signal`. On drop while rumble is still active, the `clear(self)` on the old tracker (done inside `_apply_rumble` when recomputing) drops the old hand; the new hand will pick up next apply. Simpler: always `clear(self)` first, then `add` to current holders.
- Rumble should also be cleared on `on_unplugged` (system releases the port): set `_rumble_weak = _rumble_strong = 0` and call `_apply_rumble()`. This is double-covered by `system.gd` calling `set_rumble(0, 0)` before clearing the cache — fine, idempotent.

## Verification

1. **Build**: from workspace root, `& $scons platform=windows arch=x86_64 target=template_debug dev_build=yes`. Expect no new warnings.
2. **Code path smoke test (log only)**: temporarily add a `print` in `_on_rumble_state_changed` showing `port / weak / strong`, launch `RetroVR`, power on an N64 system with Mario 64 (or any rumble-capable rom), perform an action that rumbles (fall damage, cartridge blow). Confirm prints.
3. **VR haptics**: with an XR controller physically holding the `RetroController` plugged into port 0 of that system, trigger the same rumble event. The holding hand should vibrate; releasing the controller while rumble is active should stop the vibration; re-grabbing mid-rumble should resume it. Test two-handed hold — both hands should vibrate.
4. **Unplug-during-rumble**: trigger rumble, yank the `ControllerPlug` from the port while still held. Vibration should stop immediately (handled by `_on_port_released` → `set_rumble(0,0)`).
5. **Power-off-during-rumble**: trigger rumble, press power button. Vibration should stop (handled by `power_off` clearing all ports).
6. **Dedup sanity**: with the debug print enabled, confirm the signal only fires on value *changes*, not every emulation frame — should see bursts, not a steady stream.
7. **Desktop mode**: run with a keyboard+gamepad (no HMD), pick up the controller in desktop mode, trigger rumble, confirm the physical gamepad vibrates. Disconnect the gamepad mid-rumble → no crashes.
8. **Android/Quest**: same build for `platform=android arch=arm64 target=template_debug`. Test on-device with N64 rumble — Quest controllers should vibrate via the same `XRToolsRumbleManager` path (OpenXR on Android). No Quest-specific code needed; `trigger_haptic_pulse` is platform-abstracted.

## Out of scope (explicit non-goals)

- **Per-core rumble tuning / scaling curves**: honor `XRToolsUserSettings.haptics_scale` (done for free by `XRToolsRumbleManager`), but don't add a libretro-specific scaling knob right now.
- **Per-cabinet-port desktop gamepad routing**: currently impossible — `_process_desktop_joypad` uses Godot's global action system, so there is no existing mapping from cabinet port N to joy device M. All connected pads already drive the single desktop-held `RetroController`. Rumble mirrors that: all connected pads vibrate uniformly. Revisit if/when desktop input grows per-device binding (at which point rumble piggybacks on the same mapping).
- **Rumble when controller is plugged in but not held**: no receiver, so nothing to do. Do not fall back to `Input.start_joy_vibration` in VR mode — that would vibrate a physical gamepad that isn't part of this player's experience.
