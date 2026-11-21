"""Writes four synthesized stems (bass, chords, melody, click) as WAV files.

They share one tempo and chord progression, so they sound like one song when
mixed. Being generated, they carry no copyright.
"""
import math
import struct
import sys
import wave

RATE = 44100
BPM = 100
BEAT = 60 / BPM
# I - V - vi - IV in C, one bar each, repeated.
PROGRESSION = [
    (48, [60, 64, 67]),
    (43, [59, 62, 67]),
    (45, [60, 64, 69]),
    (41, [60, 65, 69]),
]
BARS = 12
LENGTH = int(BARS * 4 * BEAT * RATE)


def freq(note):
    return 440 * 2 ** ((note - 69) / 12)


def envelope(t, duration, attack=0.01, release=0.08):
    if t < attack:
        return t / attack
    if t > duration - release:
        return max(0.0, (duration - t) / release)
    return 1.0


def render(notes, voice):
    """notes: (start_seconds, duration_seconds, midi_note, gain)."""
    out = [0.0] * LENGTH
    for start, duration, note, gain in notes:
        f = freq(note)
        first = int(start * RATE)
        for i in range(int(duration * RATE)):
            if first + i >= LENGTH:
                break
            t = i / RATE
            out[first + i] += gain * envelope(t, duration) * voice(f, t)
    return out


def sine(f, t):
    return math.sin(2 * math.pi * f * t)


def bass_voice(f, t):
    return 0.8 * sine(f, t) + 0.2 * sine(2 * f, t)


def pad_voice(f, t):
    return sine(f, t) + 0.3 * sine(2 * f, t) + 0.1 * sine(3 * f, t)


def pluck_voice(f, t):
    return math.exp(-4 * t) * (sine(f, t) + 0.5 * sine(2 * f, t))


def song():
    bass, chords, melody, click = [], [], [], []
    for bar in range(BARS):
        root, triad = PROGRESSION[bar % len(PROGRESSION)]
        bar_start = bar * 4 * BEAT
        for beat in range(4):
            start = bar_start + beat * BEAT
            bass.append((start, BEAT * 0.9, root, 0.5))
            click.append((start, 0.03, 96 if beat == 0 else 84, 0.6))
        for note in triad:
            chords.append((bar_start, 4 * BEAT, note, 0.12))
        arpeggio = triad + [triad[0] + 12]
        for step in range(8):
            note = arpeggio[(step + bar) % len(arpeggio)] + 12
            melody.append((bar_start + step * BEAT / 2, BEAT / 2, note, 0.25))
    return {
        "bass": render(bass, bass_voice),
        "chords": render(chords, pad_voice),
        "melody": render(melody, pluck_voice),
        "click": render(click, sine),
    }


def write(path, samples):
    with wave.open(path, "w") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        clipped = (max(-1.0, min(1.0, s)) for s in samples)
        output.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in clipped))


if __name__ == "__main__":
    for name, samples in song().items():
        write(f"{sys.argv[1]}/{name}.wav", samples)
