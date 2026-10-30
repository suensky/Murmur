#!/bin/sh
# Speaks the live-test fixtures with `say` into 16 kHz mono PCM16 WAV files.
set -eu
out="$(cd "$(dirname "$0")/.." && pwd)/MurmurKit/Tests/Fixtures/live"
mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

speak() {
  say -o "$tmp/$1.aiff" "$2"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/$1.aiff" "$out/$1.wav"
}

speak review "Can we move the design review to Thursday at three? I would like the billing team there."
speak fillers "Um, so, I think we should, uh, ship the the build on Friday."
speak correction "Let's meet on Tuesday, no wait, Wednesday at noon."
speak email "Write an email to Bob saying the launch slipped to Monday."
echo "fixtures in $out"
