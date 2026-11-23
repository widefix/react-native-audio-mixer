#!/bin/bash
# Generates test stems and serves them on http://localhost:8089 for the example app.
# macOS only: uses afconvert to encode AAC (.m4a), the format the mixer downloads.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p stems
if [ ! -f stems/click.m4a ]; then
  python3 -I scripts/make-stems.py stems
  for wav in stems/*.wav; do
    afconvert -f m4af -d aac "$wav" "${wav%.wav}.m4a"
    rm "$wav"
  done
fi
echo "Serving stems on http://localhost:8089"
exec python3 -m http.server 8089 --bind 0.0.0.0 --directory stems
