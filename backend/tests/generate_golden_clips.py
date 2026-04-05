#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
FIXTURE_DIR = ROOT_DIR / "backend/tests/fixtures/golden_clips"

SAMPLE_RATE = 16_000

# Each entry: (filename, tts_phrase).
# These fixtures are intentionally simple because they are generated from the
# local macOS TTS stack and need to remain stable across runs.
CLIPS: list[tuple[str, str]] = [
    ("calibration_phrase.wav", "Thank you for joining us."),
    ("schedule_phrase.wav",    "Thank you for your help."),
    ("dashboard_phrase.wav",   "Thank you very much."),
]

# macOS voice used for generation. Samantha is the default system voice and
# produces clear, natural speech that Whisper transcribes reliably.
TTS_VOICE = "Samantha"


def _valid_wav(path: Path) -> bool:
    if not path.exists():
        return False

    try:
        with wave.open(str(path), "rb") as handle:
            return handle.getnchannels() == 1 and handle.getframerate() == SAMPLE_RATE and handle.getnframes() > 0
    except Exception:
        return False


def _write_tts_wav(path: Path, phrase: str) -> None:
    """Generate a speech WAV clip using macOS `say`.

    `say -o foo.wav --data-format=...` can silently emit a header-only WAV on
    some macOS builds. Write to a temporary file first and only replace the
    destination if the result is a valid PCM clip with non-zero frames.
    """
    with tempfile.TemporaryDirectory(prefix="voxflow-golden-") as temp_dir:
        temp_path = Path(temp_dir) / path.name
        subprocess.run(
            ["say", "-v", TTS_VOICE, "-o", str(temp_path), "--data-format=LEI16@16000", phrase],
            check=True,
        )
        if not _valid_wav(temp_path):
            raise RuntimeError(
                f"macOS say produced an invalid WAV for {path.name}. "
                "Keep the existing fixture and regenerate with a known-good audio source."
            )
        shutil.move(str(temp_path), str(path))


def generate(force: bool) -> None:
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    print("Generating TTS regression clips")

    for filename, phrase in CLIPS:
        destination = FIXTURE_DIR / filename
        if not force and _valid_wav(destination):
            print(f"skip {destination.name} (exists)")
            continue

        print(f"generate {destination.name}: {phrase!r}")
        _write_tts_wav(destination, phrase)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate TTS golden regression clips using macOS say.")
    parser.add_argument("--force", action="store_true", help="Regenerate clips even if they exist.")
    args = parser.parse_args()

    generate(force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
