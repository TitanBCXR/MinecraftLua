#!/usr/bin/env python3
"""
Generate an original CC0 / public-domain style lofi loop as DFPWM1a for CC:Tweaked.

No copyrighted Tetris theme — chill pads + soft melody we wrote for this repo.
Output: media/tetris_lofi.dfpwm
"""
from __future__ import annotations

import math
import struct
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48000
DURATION_SEC = 48.0  # loop length
OUT = Path(__file__).resolve().parents[1] / "media" / "tetris_lofi.dfpwm"
WAV_PREVIEW = Path(__file__).resolve().parents[1] / "media" / "tetris_lofi_preview.wav"


def encode_dfpwm1a(samples: np.ndarray) -> bytes:
    """DFPWM1a encoder (same family as CC:Tweaked / Computronics)."""
    # Clamp to int8 range as float -1..1 first
    x = np.clip(samples.astype(np.float64), -1.0, 1.0)
    # Convert to -128..127 style amplitude used by classic encoders
    pcm = (x * 127.0).astype(np.int16)

    charge = 0
    strength = 0
    previous_bit = False
    out = bytearray()
    bit_pos = 0
    cur = 0

    for sample in pcm:
        # Predicted bit
        target = 127 if previous_bit else -128
        next_bit = sample > charge or (sample == charge and charge == 127)
        # Write bit
        if next_bit:
            cur |= 1 << bit_pos
        bit_pos += 1
        if bit_pos >= 8:
            out.append(cur)
            cur = 0
            bit_pos = 0

        # Update charge / strength (DFPWM1a)
        target = 127 if next_bit else -128
        next_charge = charge + ((strength * (target - charge) + 0x80) >> 8)
        if next_charge == charge and next_bit != (charge >= 0):
            next_charge += 1 if next_bit else -1
        charge = max(-128, min(127, next_charge))

        z = 0xFF if next_bit == previous_bit else 0x00
        next_strength = strength
        if z != strength:
            next_strength = strength + ((z - strength + 0x80) >> 8)
            # Some encoders force a floor of 2^strength_bits style; keep simple.
            if next_strength == strength:
                next_strength += 1 if z > strength else -1
        strength = max(0, min(255, next_strength if "next_strength" in dir() else strength))
        # Fix: use next_strength always
        strength = max(0, min(255, next_strength))
        previous_bit = next_bit

    if bit_pos:
        out.append(cur)
    return bytes(out)


def soft_sine(t, freq, amp=0.2):
    return amp * np.sin(2 * math.pi * freq * t)


def adsr(n, sr, a=0.05, d=0.15, s=0.55, r=0.35):
    env = np.zeros(n, dtype=np.float64)
    na, nd, nr = int(a * sr), int(d * sr), int(r * sr)
    ns = max(0, n - na - nd - nr)
    i = 0
    if na:
        env[i : i + na] = np.linspace(0, 1, na, endpoint=False)
        i += na
    if nd:
        env[i : i + nd] = np.linspace(1, s, nd, endpoint=False)
        i += nd
    if ns:
        env[i : i + ns] = s
        i += ns
    if nr and i < n:
        env[i:] = np.linspace(env[i - 1] if i else s, 0, n - i)
    return env


def note_freq(midi):
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def main():
    n = int(SAMPLE_RATE * DURATION_SEC)
    t = np.arange(n) / SAMPLE_RATE
    audio = np.zeros(n, dtype=np.float64)

    # Slow lofi: ~72 BPM, Am7 - Fmaj7 - Cmaj7 - G6 loop
    bpm = 72.0
    beat = 60.0 / bpm
    bar = beat * 4
    chords = [
        [57, 60, 64, 67],  # Am7
        [53, 57, 60, 64],  # Fmaj7
        [48, 52, 55, 59],  # Cmaj7
        [55, 59, 62, 66],  # G6
    ]

    # Soft pad (detuned sines)
    for bar_i in range(int(DURATION_SEC / bar) + 1):
        start = int(bar_i * bar * SAMPLE_RATE)
        if start >= n:
            break
        length = min(int(bar * SAMPLE_RATE), n - start)
        tt = np.arange(length) / SAMPLE_RATE
        env = adsr(length, SAMPLE_RATE, 0.2, 0.3, 0.7, 0.4)
        chord = chords[bar_i % len(chords)]
        pad = np.zeros(length)
        for midi in chord:
            f = note_freq(midi)
            pad += soft_sine(tt, f, 0.07)
            pad += soft_sine(tt, f * 1.003, 0.04)
            pad += soft_sine(tt, f * 0.5, 0.03)
        audio[start : start + length] += pad * env

    # Gentle melody (original, not Korobeiniki) — sparse & slow
    melody = [
        (0.0, 72, 1.5),
        (2.0, 74, 1.0),
        (3.5, 76, 2.0),
        (6.0, 74, 1.5),
        (8.0, 72, 2.0),
        (11.0, 69, 2.0),
        (14.0, 67, 2.5),
        (17.0, 69, 1.5),
        (19.0, 72, 2.0),
        (22.0, 71, 2.0),
        (25.0, 69, 3.0),
        (29.0, 67, 2.0),
        (32.0, 65, 2.0),
        (35.0, 67, 2.0),
        (38.0, 69, 3.0),
        (42.0, 72, 3.0),
    ]
    for start_b, midi, dur_b in melody:
        start = int(start_b * beat * SAMPLE_RATE)
        length = int(dur_b * beat * SAMPLE_RATE)
        if start >= n:
            continue
        length = min(length, n - start)
        tt = np.arange(length) / SAMPLE_RATE
        env = adsr(length, SAMPLE_RATE, 0.08, 0.2, 0.45, 0.5)
        f = note_freq(midi)
        # soft triangle-ish
        wave_ = 0.12 * (2 / math.pi) * np.arcsin(np.sin(2 * math.pi * f * tt))
        wave_ += 0.04 * np.sin(2 * math.pi * f * 2 * tt)
        audio[start : start + length] += wave_ * env

    # Soft kick / brush every other beat
    for i in range(int(DURATION_SEC / beat)):
        if i % 2 != 0:
            continue
        start = int(i * beat * SAMPLE_RATE)
        length = min(int(0.12 * SAMPLE_RATE), n - start)
        if length <= 0:
            break
        tt = np.arange(length) / SAMPLE_RATE
        kick = np.sin(2 * math.pi * (80 * np.exp(-18 * tt)) * tt) * np.exp(-14 * tt) * 0.18
        audio[start : start + length] += kick

    # Vinyl-ish hiss (very quiet)
    rng = np.random.default_rng(7)
    hiss = rng.normal(0, 0.008, n)
    # occasional soft crackle
    cracks = rng.random(n) < 0.00015
    hiss[cracks] += rng.uniform(-0.04, 0.04, cracks.sum())
    audio += hiss

    # Gentle lowpass-ish: moving average
    k = 12
    kernel = np.ones(k) / k
    audio = np.convolve(audio, kernel, mode="same")

    # Normalize
    peak = np.max(np.abs(audio)) or 1.0
    audio = audio / peak * 0.85

    # Fade edges for seamless-ish loop
    fade = int(0.25 * SAMPLE_RATE)
    audio[:fade] *= np.linspace(0, 1, fade)
    audio[-fade:] *= np.linspace(1, 0, fade)

    OUT.parent.mkdir(parents=True, exist_ok=True)

    # Prefer pip dfpwm if available
    raw = None
    try:
        import dfpwm  # type: ignore

        if hasattr(dfpwm, "compressor"):
            raw = bytes(dfpwm.compressor(audio))
        elif hasattr(dfpwm, "encode"):
            raw = bytes(dfpwm.encode(audio))
    except Exception as e:
        print("dfpwm package unused:", e)

    if raw is None:
        # Fallback: hand encoder on int PCM
        raw = encode_dfpwm1a(audio)

    OUT.write_bytes(raw)
    print(f"Wrote {OUT} ({len(raw)} bytes, {DURATION_SEC:.0f}s @ {SAMPLE_RATE}Hz)")

    # Optional WAV preview for listening outside MC
    pcm16 = (np.clip(audio, -1, 1) * 32767).astype(np.int16)
    with wave.open(str(WAV_PREVIEW), "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm16.tobytes())
    print(f"Preview WAV: {WAV_PREVIEW}")


if __name__ == "__main__":
    main()
