#!/usr/bin/env python3
"""
Generate a retro 8-bit arrangement of Korobeiniki (public-domain Russian folk
song) as DFPWM1a for CC:Tweaked. Original synth arrangement for this repo —
not a rip of any commercial Tetris soundtrack.

Output: media/tetris_lofi.dfpwm  (filename kept so pockets keep caching path)
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48000
OUT = Path(__file__).resolve().parents[1] / "media" / "tetris_lofi.dfpwm"

# Classic chiptune tempo (~150 BPM sixteenth = short step)
BPM = 148.0
BEAT = 60.0 / BPM


def square(t, freq, amp=0.2, duty=0.5):
    phase = (t * freq) % 1.0
    return np.where(phase < duty, amp, -amp)


def triangle(t, freq, amp=0.15):
    phase = (t * freq) % 1.0
    return amp * (2.0 * np.abs(2.0 * phase - 1.0) - 1.0)


def noise(n, amp=0.05, rng=None):
    rng = rng or np.random.default_rng(3)
    return rng.uniform(-amp, amp, n)


def note_freq(midi):
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def env_decay(n, sr, attack=0.01, decay=0.2):
    env = np.zeros(n, dtype=np.float64)
    na = max(1, int(attack * sr))
    nd = max(1, n - na)
    env[:na] = np.linspace(0, 1, na, endpoint=False)
    env[na:] = np.linspace(1, 0.05, nd)
    return env


def place(audio, start, wave, env=None):
    n = len(audio)
    if start >= n:
        return
    length = min(len(wave), n - start)
    chunk = wave[:length]
    if env is not None:
        chunk = chunk * env[:length]
    audio[start : start + length] += chunk


def encode(audio: np.ndarray) -> bytes:
    peak = np.max(np.abs(audio)) or 1.0
    audio = np.clip(audio / peak * 0.9, -1.0, 1.0)
    try:
        import dfpwm  # type: ignore

        return bytes(dfpwm.compressor(audio))
    except Exception:
        # Minimal fallback: write raw-ish via package failure path
        raise SystemExit("Install dfpwm: pip install dfpwm")


def main():
    # Korobeiniki A-section (MIDI), lengths in sixteenth notes.
    # Public-domain folk melody; our square/triangle arrangement.
    melody = [
        (76, 2), (71, 1), (72, 1), (74, 2), (72, 1), (71, 1),
        (69, 2), (69, 1), (72, 1), (76, 2), (74, 1), (72, 1),
        (71, 2), (71, 1), (72, 1), (74, 2), (76, 2),
        (72, 2), (69, 2), (69, 4),
        (0, 2),
        (74, 2), (77, 1), (81, 2), (79, 1), (77, 1),
        (76, 3), (72, 1), (76, 2), (74, 1), (72, 1),
        (71, 2), (71, 1), (72, 1), (74, 2), (76, 2),
        (72, 2), (69, 2), (69, 4),
        (0, 4),
    ]
    # Bass (root tones, half-ish)
    bass_pat = [
        (45, 4), (45, 4), (41, 4), (41, 4),
        (40, 4), (40, 4), (45, 4), (45, 4),
        (50, 4), (50, 4), (45, 4), (45, 4),
        (40, 4), (40, 4), (45, 4), (45, 4),
    ]

    # Two loops of the A section for a ~32s-ish track
    loops = 2
    total_sixteenths = sum(d for _, d in melody) * loops
    duration = total_sixteenths * (BEAT / 4.0) + 0.5
    n = int(SAMPLE_RATE * duration)
    audio = np.zeros(n, dtype=np.float64)
    rng = np.random.default_rng(11)

    # Melody
    cursor = 0.0
    for _ in range(loops):
        for midi, dur in melody:
            length = int((dur * (BEAT / 4.0)) * SAMPLE_RATE)
            start = int(cursor * SAMPLE_RATE)
            cursor += dur * (BEAT / 4.0)
            if midi <= 0 or length <= 0:
                continue
            t = np.arange(length) / SAMPLE_RATE
            # Pulse lead + soft triangle detune (Game Boy-ish)
            wave = square(t, note_freq(midi), 0.22, duty=0.125)
            wave += triangle(t, note_freq(midi) * 1.002, 0.08)
            env = env_decay(length, SAMPLE_RATE, 0.005, max(0.08, length / SAMPLE_RATE * 0.9))
            place(audio, start, wave, env)

    # Bass
    cursor = 0.0
    bass_cycles = int(math.ceil(duration / (sum(d for _, d in bass_pat) * (BEAT / 4.0))))
    for _ in range(bass_cycles):
        for midi, dur in bass_pat:
            length = int((dur * (BEAT / 4.0)) * SAMPLE_RATE)
            start = int(cursor * SAMPLE_RATE)
            cursor += dur * (BEAT / 4.0)
            if start >= n or length <= 0:
                break
            length = min(length, n - start)
            t = np.arange(length) / SAMPLE_RATE
            wave = square(t, note_freq(midi), 0.16, duty=0.5)
            env = env_decay(length, SAMPLE_RATE, 0.002, max(0.1, length / SAMPLE_RATE * 0.85))
            place(audio, start, wave, env)

    # Soft noise hi-hats on off-sixteenths
    step = BEAT / 4.0
    i = 0
    while i * step < duration:
        if i % 2 == 1:
            start = int(i * step * SAMPLE_RATE)
            length = min(int(0.04 * SAMPLE_RATE), n - start)
            if length > 0:
                hat = noise(length, 0.04, rng) * np.linspace(1, 0, length)
                place(audio, start, hat)
        i += 1

    # Tiny bitcrush / sample-hold for more retro grit
    hold = 4
    crushed = audio.copy()
    for i in range(0, n, hold):
        crushed[i : i + hold] = audio[i]
    audio = 0.75 * crushed + 0.25 * audio

    fade = int(0.05 * SAMPLE_RATE)
    audio[:fade] *= np.linspace(0, 1, fade)
    audio[-fade:] *= np.linspace(1, 0, fade)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    raw = encode(audio)
    OUT.write_bytes(raw)
    print(f"Wrote {OUT} ({len(raw)} bytes, {duration:.1f}s @ {SAMPLE_RATE}Hz)")


if __name__ == "__main__":
    main()
