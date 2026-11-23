#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
# AAC at a different sample rate and channel count, plus ALAC. afconvert ships with macOS.
python3 - "$work_dir" <<'PY'
import math, struct, sys, wave
dest = sys.argv[1]
def write(name, rate, channels, freq):
    frames = int(rate)
    with wave.open(f"{dest}/{name}.wav", "w") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(rate)
        pcm = bytearray()
        for i in range(frames):
            sample = int(0.4 * 32767 * math.sin(2 * math.pi * freq * i / rate))
            pcm.extend(struct.pack("<" + "h" * channels, *([sample] * channels)))
        output.writeframes(pcm)
write("mono", 44100, 1, 440)
write("stereo", 48000, 2, 660)
write("alac", 44100, 2, 440)
PY
afconvert -f m4af -d aac "$work_dir/mono.wav" "$work_dir/mono.m4a"
afconvert -f m4af -d aac "$work_dir/stereo.wav" "$work_dir/stereo.m4a"
afconvert -f m4af -d alac "$work_dir/alac.wav" "$work_dir/alac.m4a"
rm -f "$work_dir/mono.wav" "$work_dir/stereo.wav" "$work_dir/alac.wav"
xcrun clang++ -std=c++17 -fobjc-arc -fsanitize=address,undefined -framework Foundation -framework AudioToolbox PCMMixerTests.mm -o "$work_dir/tests"
"$work_dir/tests" "$work_dir/mono.m4a" "$work_dir/stereo.m4a" "$work_dir/alac.m4a"
