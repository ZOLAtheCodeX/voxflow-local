#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import struct
import wave
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
FIXTURE_DIR = ROOT_DIR / "backend/tests/fixtures/golden_clips"

SAMPLE_RATE = 16_000
AMPLITUDE = 11_000

# Deterministic synthetic clips avoid platform TTS quirks that can produce empty files.
# Duration/frequency combinations are tuned to remain short while still producing
# consistent model outputs for regression checks.
CLIPS: list[tuple[str, float, float]] = [
    ("calibration_phrase.wav", 0.08, 440.0),
    ("schedule_phrase.wav", 0.12, 660.0),
    ("dashboard_phrase.wav", 0.20, 880.0),
]


def _valid_wav(path: Path) -> bool:
    if not path.exists():
        return False

    try:
        with wave.open(str(path), "rb") as handle:
            return handle.getnchannels() == 1 and handle.getframerate() == SAMPLE_RATE and handle.getnframes() > 0
    except Exception:
        return False


def _write_sine_wav(path: Path, duration_s: float, frequency_hz: float) -> None:
    frame_count = max(1, int(SAMPLE_RATE * duration_s))
    attack_frames = max(1, int(frame_count * 0.10))
    release_frames = max(1, int(frame_count * 0.10))

    pcm = bytearray()
    for index in range(frame_count):
        # Short fade-in/fade-out to avoid hard-edge clicks.
        if index < attack_frames:
            envelope = index / attack_frames
        elif index > frame_count - release_frames:
            envelope = max(0.0, (frame_count - index) / release_frames)
        else:
            envelope = 1.0

        sample = int(AMPLITUDE * envelope * math.sin(2.0 * math.pi * frequency_hz * (index / SAMPLE_RATE)))
        pcm.extend(struct.pack("<h", sample))

    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(pcm))


def generate(force: bool) -> None:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    print("Generating deterministic synthetic regression clips")

    for filename, duration_s, frequency_hz in CLIPS:
        destination = FIXTURE_DIR / filename
        if not force and _valid_wav(destination):
            print(f"skip {destination.name} (exists)")
            continue

        print(f"generate {destination.name}")
        _write_sine_wav(destination, duration_s=duration_s, frequency_hz=frequency_hz)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate deterministic golden regression clips.")
    parser.add_argument("--force", action="store_true", help="Regenerate clips even if they exist.")
    args = parser.parse_args()

    generate(force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
