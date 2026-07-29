#!/usr/bin/env python3
"""Generate CRT television idle hum and power-on/off transients.

Synthesised from the actual physics of a CRT set rather than sampled, for two
reasons. Every "CRT hum" recording that turns up in a search is either
unbundled, licensed for personal use only (the BBC RemArc library), or behind a
login with per-file terms that vary — and this app ships. Second, the components
are individually meaningful, so a note like "more hiss, less whine" is a number
change here rather than another hunt.

What a CRT actually emits:

  * FLYBACK WHINE at the horizontal line rate. 15734.264 Hz on NTSC, 15625 Hz on
    PAL. This is the iconic CRT sound, radiated mechanically by the flyback
    transformer's windings and core. It is right at the edge of adult hearing;
    plenty of people over about 25 cannot hear it at all, which is exactly why it
    is offered at several levels below.
  * MAINS BUZZ from the power transformer, at twice the line frequency (120 Hz in
    North America) with odd harmonics above it, because core magnetostriction
    tracks the absolute value of the current.
  * HISS, broadband, which is the audible half of a no-signal screen — the same
    thermal noise that draws the snow.
  * A DEGAUSS THUNK at switch-on as the degaussing coil fires: a low thump plus
    the mechanical clack of the coil against the funnel.

    python3 Tools/gen_crt_hum.py

Writes 48 kHz mono WAVs. Idle loops are exactly periodic — every component
completes a whole number of cycles in the loop, and the noise is built in the
frequency domain from random phases, so an inverse FFT is inherently seamless.
No click at the loop point, no crossfade needed.
"""

import os
import struct
import wave

import numpy as np

SR = 48000
LOOP = 4.0                      # seconds; 240 whole cycles of 60 Hz
NTSC_LINE = 15734.264

OUT = os.path.join(os.path.dirname(__file__), "..", "RetroVR", "Audio", "crt")
if len(__import__("sys").argv) > 1:
    OUT = __import__("sys").argv[1]


def _n(seconds):
    return int(round(seconds * SR))


def _fit(freq, seconds):
    """Nearest frequency completing a whole number of cycles in `seconds`."""
    return max(1, round(freq * seconds)) / seconds


def tone(freq, seconds, amp, wobble_hz=0.0, wobble_cents=0.0):
    """Sine at a loop-safe frequency, optionally with slow pitch drift."""
    n = _n(seconds)
    t = np.arange(n) / SR
    f = _fit(freq, seconds)
    if wobble_cents > 0.0:
        # Drift also has to close the loop, so its rate is fitted too.
        wf = _fit(wobble_hz, seconds)
        cents = wobble_cents * np.sin(2 * np.pi * wf * t)
        phase = 2 * np.pi * np.cumsum(f * (2.0 ** (cents / 1200.0))) / SR
    else:
        phase = 2 * np.pi * f * t
    return amp * np.sin(phase)


def noise(seconds, amp, lo=120.0, hi=13000.0, tilt=0.0, seed=0):
    """Band-limited noise, exactly periodic over `seconds`.

    Built as a spectrum with random phase and inverse-transformed, so the result
    wraps with no discontinuity. `tilt` in dB/octave shades it: negative is
    darker, 0 is flat (white).
    """
    n = _n(seconds)
    rng = np.random.default_rng(seed)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    mag = np.zeros_like(freqs)
    band = (freqs >= lo) & (freqs <= hi)
    mag[band] = 1.0
    # Soft shoulders, or the band edges ring.
    lo_edge = (freqs > lo * 0.4) & (freqs < lo)
    mag[lo_edge] = (freqs[lo_edge] / lo) ** 2
    hi_edge = (freqs > hi) & (freqs < hi * 2.2)
    mag[hi_edge] = (hi / freqs[hi_edge]) ** 2
    if tilt != 0.0:
        ref = 1000.0
        with np.errstate(divide="ignore", invalid="ignore"):
            octaves = np.log2(np.maximum(freqs, 1e-9) / ref)
        mag = mag * (10.0 ** (tilt * octaves / 20.0))
    mag[0] = 0.0
    spec = mag * np.exp(2j * np.pi * rng.random(len(freqs)))
    x = np.fft.irfft(spec, n)
    peak = np.max(np.abs(x))
    return (amp * x / peak) if peak > 0 else x


def transformer_buzz(seconds, amp, mains=60.0):
    """Core magnetostriction: strongest at 2x mains, with decaying harmonics."""
    out = np.zeros(_n(seconds))
    for mult, rel in ((1, 0.25), (2, 1.0), (3, 0.45), (4, 0.30), (5, 0.16), (6, 0.10)):
        out += tone(mains * mult, seconds, rel)
    return amp * out / np.max(np.abs(out))


def ticks(seconds, amp, count=6, seed=1):
    """Sparse thermal ticks from the case and chassis expanding.

    Kept clear of both ends of the loop so nothing is clipped at the seam.
    """
    n = _n(seconds)
    out = np.zeros(n)
    rng = np.random.default_rng(seed)
    guard = _n(0.08)
    for _ in range(count):
        at = rng.integers(guard, n - guard)
        dur = _n(rng.uniform(0.004, 0.012))
        env = np.exp(-np.linspace(0, 9, dur))
        click = rng.standard_normal(dur) * env
        out[at:at + dur] += click * rng.uniform(0.4, 1.0)
    peak = np.max(np.abs(out))
    return (amp * out / peak) if peak > 0 else out


def write(path, x, peak=0.5):
    """Normalise to `peak` and write 16-bit mono."""
    m = np.max(np.abs(x))
    if m > 0:
        x = x / m * peak
    pcm = np.clip(x * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return len(pcm) / SR


# --------------------------------------------------------------------------
# Idle loops. Levels are relative within each mix; the file is normalised, so
# what differs between variants is the BALANCE, not the loudness.
# --------------------------------------------------------------------------
def idle(whine, buzz, hiss, tick=0.0, wobble=False, pal=False, seed=0):
    line = 15625.0 if pal else NTSC_LINE
    x = np.zeros(_n(LOOP))
    if whine > 0.0:
        x += tone(line, LOOP, whine,
                  wobble_hz=0.7 if wobble else 0.0,
                  wobble_cents=6.0 if wobble else 0.0)
        # NO second harmonic. 15734 x 2 = 31469 Hz is above the 24 kHz Nyquist
        # limit at 48 kHz, so it does not reproduce — it ALIASES back to
        # 48000 - 31469 = 16531 Hz, an inharmonic whistle a fifth above the
        # whine. A spectrum check caught it sitting only 15 dB down.
    if buzz > 0.0:
        x += transformer_buzz(LOOP, buzz)
    if hiss > 0.0:
        x += noise(LOOP, hiss, lo=140.0, hi=12500.0, tilt=-1.5, seed=seed)
    if tick > 0.0:
        x += ticks(LOOP, tick, seed=seed + 5)
    return x


def power_on():
    """Degauss thunk, then the whine and hiss coming up as the set warms."""
    dur = 1.8
    n = _n(dur)
    t = np.arange(n) / SR

    # Degauss: a low thump plus the coil's mechanical clack.
    thump_env = np.exp(-t * 14.0)
    thump = (np.sin(2 * np.pi * 46.0 * t) * 0.9 + np.sin(2 * np.pi * 92.0 * t) * 0.3) * thump_env
    rng = np.random.default_rng(11)
    clack_n = _n(0.05)
    clack = np.zeros(n)
    clack[:clack_n] = rng.standard_normal(clack_n) * np.exp(-np.linspace(0, 7, clack_n)) * 0.5

    # Whine slides up to pitch over ~0.35 s and holds.
    ramp = np.clip(t / 0.35, 0.0, 1.0)
    f = NTSC_LINE * (0.55 + 0.45 * ramp)
    whine = 0.16 * np.sin(2 * np.pi * np.cumsum(f) / SR) * ramp

    hiss = noise(dur, 0.30, lo=140.0, hi=12500.0, tilt=-1.5, seed=3)
    hiss *= np.clip((t - 0.05) / 0.5, 0.0, 1.0)
    buzz = transformer_buzz(dur, 0.22) * np.clip(t / 0.2, 0.0, 1.0)
    return thump + clack + whine + hiss + buzz


def power_off():
    """Whine falls away and the hiss collapses; a soft relay clunk."""
    dur = 1.0
    n = _n(dur)
    t = np.arange(n) / SR
    fall = np.clip(1.0 - t / 0.45, 0.0, 1.0)
    f = NTSC_LINE * (0.35 + 0.65 * fall)
    whine = 0.16 * np.sin(2 * np.pi * np.cumsum(f) / SR) * fall
    hiss = noise(dur, 0.30, lo=140.0, hi=12500.0, tilt=-1.5, seed=4) * np.clip(1.0 - t / 0.25, 0.0, 1.0)
    buzz = transformer_buzz(dur, 0.22) * np.clip(1.0 - t / 0.3, 0.0, 1.0)
    rng = np.random.default_rng(12)
    cl = _n(0.04)
    clunk = np.zeros(n)
    clunk[:cl] = rng.standard_normal(cl) * np.exp(-np.linspace(0, 8, cl)) * 0.35
    thump = np.sin(2 * np.pi * 55.0 * t) * np.exp(-t * 20.0) * 0.5
    return whine + hiss + buzz + clunk + thump


VARIANTS = {
    # name:                        whine buzz  hiss  tick  wobble
    "idle_a_whine_only":     dict(whine=0.22, buzz=0.05, hiss=0.00),
    "idle_b_transformer":    dict(whine=0.04, buzz=0.30, hiss=0.00),
    "idle_c_static_heavy":   dict(whine=0.08, buzz=0.14, hiss=0.34),
    "idle_d_balanced":       dict(whine=0.14, buzz=0.16, hiss=0.18),
    "idle_e_aged_set":       dict(whine=0.16, buzz=0.20, hiss=0.20, tick=0.22, wobble=True),
    "idle_f_pal_balanced":   dict(whine=0.14, buzz=0.16, hiss=0.18, pal=True),
}


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, kw in VARIANTS.items():
        secs = write(os.path.join(OUT, name + ".wav"), idle(seed=7, **kw))
        print("wrote %-22s %.2f s  %s" % (name + ".wav", secs, kw))
    for name, fn in (("power_on", power_on), ("power_off", power_off)):
        secs = write(os.path.join(OUT, name + ".wav"), fn(), peak=0.7)
        print("wrote %-22s %.2f s" % (name + ".wav", secs))
