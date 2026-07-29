# Meta XR Audio SDK v85 — findings from a native (non-Unity/Unreal) integration

Compiled 2026-07-29 while binding the SDK's native C API into a Godot 4.7 GDExtension
for a Quest 3 title. Reported in case any of it is useful; several items cost real
debugging time and at least one looks like a genuine arm64 defect.

Each item is tagged with how confident I am, because I got three intermediate
conclusions wrong during this investigation before isolating the real causes. Anything
not marked **Confirmed** should be treated as a lead, not a bug report.

---

## Environment

| | |
|---|---|
| SDK | Meta XR Audio SDK **v85.0.0** (`com.meta.xr.sdk.audio`, npm.developer.oculus.com) |
| `mxra_get_version` reports | `1.117.0` |
| Windows binary | `Runtime/Plugins/x86_64/MetaXRAudioUnity.dll` — 2,671,104 bytes, md5 `7569f2b2e04944966adccdcdc9e5155c` |
| Android binary | `Runtime/Plugins/Android/libs/arm64-v8a/libMetaXRAudioUnity.so` — 2,705,728 bytes, md5 `2ca91e8632d0239d7e34ce55d67a8a50` |
| Device | Quest 3, Horizon OS / Android 14, build `52433670016300520`, arm64-v8a |
| Host toolchain | MSVC 14.51.36231 (x64); NDK r27d clang, `aarch64-linux-android29` |
| API used | the undecorated `mxra_*` C entry points (103 symbols, identical set on both binaries) |

All measurements below come from rendering to WAV and analysing **both platforms with the
same numpy script** — never from measuring inside the code under test.

---

## 1. Redundant `mxra_source_set_position` calls degrade audio on arm64 — **Confirmed**

**Severity: high for any engine integration.** Most engines push transforms every frame
regardless of whether they changed; that is the failing pattern.

Calling `mxra_source_set_position` repeatedly injects sidebands on arm64 **even when the
position passed is bit-identical every time**. The source never moves. Windows x64 is
unaffected.

Method: one context, one source, static listener, a pure 440 Hz sine in. Position is the
same `const float[3]` in every case; only the *call frequency* varies. Measured as the
fraction of output energy remaining within 430–450 Hz.

| `mxra_source_set_position` called… | Windows x64 | Quest arm64 |
|---|---|---|
| once, before the render loop | 100.000 % | **100.000 %** |
| every block (256 frames) | 100.000 % | **80.769 %** |
| every 4th block | 100.000 % | **73.365 %** |
| every 16th block | 100.000 % | **95.976 %** |

The displaced energy lands in sidebands within roughly ±40 Hz of the carrier. There is no
harmonic distortion (all harmonics ≤ −86 dB, same as Windows) and no broadband noise
(2–20 kHz sits at −117 dB vs −122 dB on Windows). Perceptually it is a roughness or warble
on sustained tones.

Note the non-monotonicity — every 4th block is worse than every block — which suggests an
interpolation or crossfade being retriggered rather than a simple accumulation.

**Reproducer: `tools/repro_redundant_setposition.cpp`** — self-contained, depends only on
`external/metaxraudio/MetaXRAudioABI.hpp`, build and run instructions in its header comment.
Verified 2026-07-29 from a clean build on both platforms; it reproduces the four percentages
above exactly.

**Workaround for integrators:** cache the last position per source and skip the call when
unchanged (exact float compare is sufficient — the failing case is a bit-identical repeat).

**Not yet characterised:** whether the effect scales with active source count, and whether
`mxra_source_set_pose` (the transform variant) behaves the same. Both worth checking.

---

## 2. `mxra_context_create` writes a context pointer even when it fails — **Confirmed**

`mxra_context_create(&ctx, &params)` with an invalid `params` returns `2001`
(invalid-parameter) **but still writes a non-null value to `*out_ctx`**.

```
create(&c, nullptr)                    -> 0,    c = valid
create(&c, &params_with_wrong_size)    -> 2001, c = NON-NULL but not initialised
```

A caller that checks the out-pointer rather than the return code proceeds with an
uninitialised context. Subsequent calls then either return `2005` or fault. Suggest either
leaving `*out_ctx` untouched on failure or nulling it.

---

## 3. `mxra_context_params` layout is undocumented and differs from the v47 config — **Documentation**

Recovered from the validation chain in `mxra_context_init`:

```c
struct mxra_context_params {
    uint32_t size;             // [0x00] must be EXACTLY 28 (0x1c)
    uint32_t max_num_sources;  // [0x04] >= 1
    uint32_t sample_rate;      // [0x08] 16000 .. 48000 inclusive
    uint32_t buffer_length;    // [0x0c] 128 .. 65536, and must be <= sample_rate
    uint32_t flags;            // [0x10] read as a byte; bit 4 forces a mutex re-create
    uint32_t mode;             // [0x14] must be <= 8
    uint32_t reserved;         // [0x18]
};
```

The trap: this is **not** the legacy `ovrAudioContextConfiguration`. `size` is 32-bit here,
not 64-bit, and there is no `provider` field. Anyone porting from the documented v47 native
API will pass a 24-byte struct with a 64-bit size, get `2001`, and — per issue 2 — receive a
context pointer anyway.

`buffer_length` is also the fixed block size for the whole context: `mxra_source_process`
takes no frame count and reads it from here.

---

## 4. `mxra_source_process` takes a recursive mutex — **Confirmed behaviour, design concern**

`mxra_source_process` calls `ovrAudioInternal_LockRecursiveMutex` on every invocation
(visible in the arm64 disassembly at `mxra_source_process+0x13c`). For a real-time audio
callback this means:

- a lock is taken per source, per block, on the audio thread;
- any main-thread call into the same context (setting a pose, changing room parameters) can
  contend with the audio thread.

Not a bug, but it is not documented, and it forces integrators to funnel *all* context
mutation through a queue drained on the audio thread. Worth stating explicitly in any
future native documentation.

---

## 5. No distance attenuation by default; only one of four modes attenuates — **Confirmed behaviour**

A newly created context applies **no distance law at all** — a source at 4 m measures the
same level as at 1 m. Of the modes accepted by `mxra_source_set_attenuation` (validated
`<= 2`, and 3 is accepted too), only **mode 2** attenuates:

| mode | 0.5 m | 1 m | 4 m | 10 m |
|---|---|---|---|---|
| (none set) | −26.4 | −24.0 | −24.0 | −24.0 dB |
| 0 | −26.4 | −24.0 | −24.0 | −24.0 dB |
| 1 | −26.4 | −24.0 | −24.0 | −24.0 dB |
| **2** | −26.4 | −42.3 | −59.2 | −67.9 dB |
| 3 | −26.4 | −24.0 | −24.0 | −24.0 dB |

Mode 2's curve is also steeper than inverse-distance (≈ −18 dB per 4× rather than −12 dB),
which put a source 4.8 m away at −44 dB — inaudible in a normal room mix. We ended up
applying the engine's own inverse-distance law through the gain parameter instead.

Modes 0, 1 and 3 returning success while doing nothing is the part worth fixing — silent
no-ops are hard to distinguish from a wiring mistake.

---

## 6. Inconsistent argument validation in `mxra_source_set_position` — **Minor**

`mxra_source_set_position(ctx, index, const float pos[3])` validates the context pointer,
the source index (sign and upper bound) and the finiteness of the position components — but
dereferences the position pointer without a null check, so a bad pointer faults inside the
library rather than returning `2001` like every neighbouring error path.

Given the rest of the function is unusually thorough about validation, the omission reads as
an oversight. Low severity for correct callers.

---

## 7. Cross-platform render divergence for off-axis sources — **UNCONFIRMED, do not action yet**

Flagging as a lead only. I could not root-cause this and it may still be my harness.

- With a **static, on-axis** source, Windows x64 and Quest arm64 produce **MD5-identical**
  output — 576,000 samples, zero difference. So the two builds *can* agree bit-for-bit.
- With sources **off-axis and elevated**, the two platforms diverge, and not just in the low
  bits: in one scenario the interaural level difference was −4.31 dB on Windows and +4.11 dB
  on arm64 — i.e. the opposite ear.

I eliminated the obvious harness causes (identical listener yaw values printed on both
platforms; test-signal generator hashed identical after the fix in the note below), but not
all of them. **Treat this as unverified.** If item 1 is investigated, this is worth a glance
at the same time, since both concern the arm64 rendering path.

---

## Note for anyone reproducing this: FMA contraction

This one was **our bug, not the SDK's**, but it wasted hours and will bite anyone doing
cross-platform bit-exact comparison:

Clang contracts `a*b+c` into a single FMA by default on ARM; MSVC does not. That alone made
our test *signal* differ between platforms and looked exactly like an SDK defect. Building
the NDK side with `-ffp-contract=off` made the generator hash match Windows exactly
(`0x5a14a1bc97ae400f` on both).

It also explains why the static case above was bit-identical while moving cases were not:
the static render had no multiply-add to fuse.

Any cross-platform comparison of this SDK should disable FP contraction first, or it will
generate phantom bugs.

---

## Context: why we were on the native API at all

Not a bug, but it is the reason all of the above had to be reverse-engineered:

- v85 ships only as Unity / Unreal / FMOD / Wwise plugins. There is no native/C++ package.
- The legacy native download (`oculus-spatializer-native`, v47, Dec 2022) is the last one
  with published headers and reference docs, and its API differs from the current one.
- The current `mxra_*` C API has **no published header and no reference documentation**
  anywhere I could find, though it is clearly the intended stable ABI: 103 undecorated
  symbols, byte-identical between the Windows and Android binaries.
- We recovered signatures from the MSVC-mangled C++ exports (which encode full parameter
  types) plus targeted disassembly.

Publishing `MetaXRAudio*.h` and the `mxra_*` reference — even as-is, unsupported, alongside
the feature freeze — would make the SDK usable from engines Meta doesn't ship plugins for,
at essentially zero cost.

## Performance, for reference

Measured on Quest 3, since no per-source figure is published. 256-frame block at 48 kHz
(5.333 ms real-time budget), one `mxra_source_process` per source per block:

| sources | µs/source/block | % of real-time budget |
|---|---|---|
| 8 | 4.7 | 0.70 % |
| 16 | 4.7 | 1.41 % |
| 32 | 5.0 | 2.99 % |

Linear, ~5 µs per source. Cost is not a concern — this was the risk we expected to find and
did not.
