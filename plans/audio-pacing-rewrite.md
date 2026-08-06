# Pacing rewrite: brake on the sink, not on the core's claims

Scoped 2026-08-06, after ScummVM/Monkey Island froze on Quest while running fine on desktop.

## Why

The emulation loop has now been paced by two different references, and a real core has
falsified each:

| Reference | Nature | Falsified by |
|---|---|---|
| `av_info.timing.fps` | a claim by the core | **azahar** — `retro_run` returns on game-present, so a call is not a refresh |
| audio frames produced | a claim by the core | **ScummVM** — billed 2,524,000 ms of audio for one `retro_run` |
| audio frames *consumed* | physical: the mixer really does eat `mix_rate` frames/s | nothing — hardware drives it |

`5803962` → `3c0c15d` swapped one core-supplied claim for another. That is why fixing azahar
broke ScummVM. Only the third reference cannot lie.

## What RetroArch does (reference implementation, `~/RetroArch`)

1. **One canonical av_info, read live.** `runloop.c:4958` passes `&video_st->av_info` — a
   long-lived global — to `retro_get_system_av_info`, and every use site reads that struct
   live. `SET_SYSTEM_AV_INFO` `memcpy`s into the same struct (`runloop.c:2772`). A core that
   retains the pointer and writes through it is therefore indistinguishable from a legal
   update. The aliasing failure below cannot occur there.

2. **fps is a ceiling, never a target.** `runloop_set_frame_limit` (`runloop.c:4747`) turns
   fps into `frame_limit_minimum_time`, a *minimum time per frame*: if the frame finished
   early, sleep the remainder. Nothing tries to reach a call rate.

3. **With `audio_sync` on, the fps limiter is switched off entirely** (`runloop.c:7940`),
   in as many words: *"redundant double-pacing … Defer pacing to the audio backpressure
   path."*

4. **The brake is the blocking audio write.** `set_nonblock_state(true)` is called *only*
   when `audio_sync` is off (`audio/audio_driver.c:1699`), so normally the write blocks
   until the sink drains.

5. **Dynamic rate control is the fine trim** (`audio/audio_driver.c:578`):
   ```c
   delta_mid   = avail - half_size;
   direction   = (double)delta_mid / half_size;
   rate_adjust = 1.0 + effective_delta * direction;
   ```
   The resampler ratio is nudged ~±0.5% to hold the buffer near half full — absorbing drift
   without underrunning or letting latency grow. This is the piece `5803962` lacked, and it
   is what separates speed control from latency control.

ScummVM works under RetroArch *because* its 500 fps claim is only a ceiling and audio is the
brake. Declaring a high fps is the core asking "call me as often as you can, throttle me on
audio" — a reasonable request our loop read as an instruction.

## Bugs found while diagnosing — land these first, independently

These are correctness fixes, not part of the redesign. Each is small and independently
verifiable.

- **B1 — av_info aliasing.** `Wrapper.cpp:1538` fills a **stack local**
  `retro_system_av_info`, then computes `frame_duration_ms` (`:1569`) and `sample_rate_hz`
  (`:1590`) from it. ScummVM retains the pointer and writes through it during
  `context_reset` (called from `InitHwRenderContext`, `:1549`) — between the read and the
  use. Observed: same session logs `FPS: 60.000000` at `:1541` and yields
  `frame_duration_ms == 2.0` (500 fps) at `:1569`.
  *Fix:* one canonical `retro_system_av_info` member on `Wrapper`, filled once, read live —
  RetroArch's shape. Do **not** snapshot into scalars: that freezes 60 and works by
  accident, breaking cores that legitimately retime. Do **not** re-call
  `retro_get_system_av_info` — it hands back the same aliasing pointer.

- **B2 — WITHDRAWN, not a bug.** Scoping claimed `QueuedFrames()` was inverted on the Quest
  path. It is not. `MetaXRAudioServer::VoiceFramesAvailable` returns `Available()` — "frames
  waiting to be mixed", i.e. queued — and `AudioHandler::QueuedFrames()` uses it correctly.
  `Space()` is exposed separately as `voice_space`. Recorded here so the claim is not
  rediscovered as fact.

  The server also already exposes **`voice_frames_wanted`** (`MetaXRAudioServer.cpp:417`),
  which returns `min(target_fill - queued, space)` — precisely the "how much does the sink
  want right now" primitive Phase 2 needs. Build the brake on it rather than reimplementing
  target-fill arithmetic in `AudioHandler`.

- **B3 — `EffectiveTotalFrames()` still pretends 0.1 s.** `AudioHandler.cpp:142` returns
  `m_audio_buffer_capacity_sec * m_mix_rate` (0.1 s) while the real voice ring is
  `kRingFrames = 1 << 15` (32768 frames, ~0.68 s at 48 kHz). This is the same mismatch
  `3c0c15d` blamed for the original occupancy-pacing failure; it was worked around, not
  removed. Any consumption-based brake must use real numbers.

- **B4 — unbounded overdraft sleep.** Already patched (debt clamp at 250 ms + a ceiling on
  per-call billing). **Keep both as backstops** regardless of the redesign — "core billed 45
  minutes" must never be trusted — but they are a tourniquet, not the fix.

## Design

**Roles.**
- `timing.fps` → speed **ceiling** only. Never a billing floor, never a target call rate.
- Sink consumption → the **brake**.
- Resampler ratio → the **trim** that holds latency steady.
- Declared fps → the **fallback** brake for cores that emit no audio at all (the one case a
  sink clock genuinely cannot handle).

**The brake.** We have no blocking write to lean on: `PushStereoFrames` clamps to `Space()`
and returns (`MetaXRAudioServer.cpp:466`), which is the source of the popping noted in
`3c0c15d`. So we synthesise one in the pacing loop: before running a frame, if queued frames
exceed the target depth, wait for the shortfall to drain; otherwise run. Two rules learned
the hard way:
- The test reads the **actual** queue depth every pass (B2/B3), never a pretend total.
- The valve is **stateless** — no `audio_stall_ms`-style accumulator that can latch open.
  Every wait is bounded and recomputed from current state.

**Target depth.** Not the ring's 0.68 s — that is latency a player feels. Target ~60–80 ms.
`MetaXRAudioServer` already carries `m_target_fill` with `SetTargetLatencyMs` /
`GetTargetLatencyMs` and clamps to `[2 blocks, kRingFrames/2]` (`:499`), so the concept
exists and should be reused rather than duplicated.

**The trim.** Port RetroArch's DRC: adjust `m_resample_ratio` by ~±0.5% proportional to
`(queued - target) / target`.
*Blocker:* the resampler is only allocated when the core rate differs from the mix rate
(`AudioHandler.cpp:202`). ScummVM at 44100 into a 44100 mixer gets **no resampler**, so
there is no ratio to trim. Phase 3 must allocate it unconditionally at ratio 1.0.

## Phases

- **Phase 0 — correctness. B1 only.** No behaviour redesign. Ship and confirm ScummVM still
  runs and azahar/Majora's Mask is unchanged. *Independent of everything below.*

  **B3 was moved out of Phase 0 (2026-08-06).** Its denominator feeds
  `m_audio_buffer_occupancy` → `CallAudioBufferStatusCallback` → frameskip decisions in
  *every* core, so correcting it is a behaviour change with the same blast radius as the
  redesign and needs the same per-core validation sweep. Phase 0 is meant to be safe and
  independently shippable; B1 is a pure memory-safety fix with no observable change. Fold B3
  into Phase 2, where the sink numbers are reworked wholesale and can be validated together.
- **Phase 1 — fps becomes a ceiling. DONE 2026-08-06.** The declared rate no longer bills or
  targets anything; it only caps how fast the loop may call, and is the sole brake for a core
  that emits no audio at all.
- **Phase 2 — sink brake. DONE 2026-08-06.** `AudioHandler::MsUntilSinkWantsFrames()` on top
  of the server's existing `voice_frames_wanted`. Returns 0 when there is no sink (a missing
  sink must never halt emulation), bounded at 250 ms (a stopped sink must never freeze the
  game), and recomputed from current depth every pass so it cannot latch. `credit_ms` and
  B4's clamps are gone with the arithmetic they guarded; the 250 ms bound is their successor.

  Verified on Quest across three cores with three different rates — azahar (32728 Hz,
  2 refreshes per call) at 1x, ScummVM (44100 Hz, claims 500 fps) correct, fceumm
  (48000 Hz, 60.099827 fps) unchanged. None of them needed the frontend to know anything
  true about them, which is the point.

- **Phase 3 — DRC trim. DONE 2026-08-06, verified on device.** Phase 2 made azahar's crackle
  **much less frequent but did not eliminate it** (an earlier revision of this file, and
  `9abeafd`'s commit message, wrongly said "gone" — that came from a first impression which
  was then refined). The rate trim closed the remainder.

  Landed as: the resampler is now allocated even at 1:1, because a core already running at
  the mixer's rate would otherwise have no ratio to turn — so ScummVM (44100→44100) pays a
  sinc pass it did not before, which is real CPU on a device already flagged CPU-bound.
  A failed allocation no longer tears down the Meta XR path when the rates match; it just
  loses the trim, since matched rates still play correctly straight through. Per batch the
  ratio is trimmed by ±0.5% (`k_drc_max_delta`, RetroArch's default bound) proportional to
  `(target - queued) / target`, reusing the depth read the occupancy figure already made.

  **Caveat on the history:** a concurrent session's commit `5365dbf` ("a channel mode routes
  one source channel to both speakers") swept up this work uncommitted, so the DRC change is
  recorded under a commit message about channel modes. It also carried a temporary sink-depth
  probe into master, removed in `0fb40b2`.

  What that pattern means: the gross fault was a fill level nothing aimed at, and aiming at
  one fixed most of it. What is left is *occasional* starvation, which is the signature DRC
  exists for. The brake is one-sided — it only ever holds the core *back* when the sink is
  above target. Nothing pushes the other way, so when a heavy frame or a main-thread hitch
  outruns the ~46 ms target fill (`kDefaultTargetFill` 2048 frames), the ring drains and the
  mixer gets a gap. DRC handles exactly that by re-rating slightly instead of starving.

  Two things to try before, or instead of, full DRC — both cheap:
  1. **Raise the target fill.** `set_target_latency_ms` is already bound; nothing currently
     calls it. More headroom trades latency for margin and would confirm the underrun
     reading immediately.
  2. **Measure the depth.** Log queued frames over a run. Sawtoothing down to zero is
     underrun (DRC's case); slamming to full is overrun (a different fix).

  The unconditional-resampler blocker (`AudioHandler.cpp:202`) does have to be solved for
  real DRC: ScummVM at 44100→44100 gets no resampler and therefore no ratio to trim.
- **Phase 4 — cleanup.** Drop the `implausible batch` probe in `AudioHandler.cpp` (it has
  answered its question); decide whether the one-shot warnings stay (recommend: yes, they
  are cheap and would have caught this in a day).

## Validation

No formal test suite, so this is per-core on-device measurement. Speed must be *measured*,
not eyeballed — the original azahar bug presented as "speed tracks viewing distance."

- **fceumm** — well-behaved 60 fps, the control. Must not change.
- **azahar / Majora's Mask 3D** — the core the audio clock exists for. Must stay at 1x; the
  original symptom was up to 2x with ~0.6 s audio lag, and speed varying with GPU load.
- **ScummVM / Monkey Island** — the regression. Must run at correct speed with no stall.
- **mupen64plus, PPSSPP** — share azahar's present-driven `retro_run` shape.

**Both platforms run the same sink.** An earlier draft of this plan claimed desktop falls back
to `AudioStreamPlayer3D` while only Quest uses the Meta XR voice ring — that is wrong.
`metaxr-audio.windows.template_debug.x86_64.dll` ships alongside the Android `.so`, and
`AudioHandler::Init` gates `m_use_sdk` on the `MetaXRAudio` singleton being present and
available (`AudioHandler.cpp:168`), not on platform. The `AudioStreamGenerator` path is a
fallback that neither platform normally takes. Desktop/Quest behaviour differences therefore
come from the **core builds** (the Windows ScummVM DLL and the Android `.so` are separately
built), not from the audio path.

Confirmed on-device 2026-08-06: **azahar's audio crackle reproduces on desktop too**, which
is consistent with one shared sink and points at pacing/latency control rather than anything
platform-specific.

**Netplay stays on the plain accumulator** — rate control is not deterministic. `Wrapper.cpp`
already branches on `m_netplay_enabled`; that branch must remain untouched.

## Risks

- Synthesising back-pressure without a blocking write is the crux; a latching valve is the
  documented way this fails.
- Rebuild **all** targets per change — a stale Android `.so` makes on-device tests exercise
  old code silently.
- Phases 1–3 are not independently shippable: fps-as-ceiling without a working sink brake
  leaves cores unthrottled. Land 1–3 together, or behind a flag.
