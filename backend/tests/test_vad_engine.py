"""SileroVAD engine (R6): speech-presence classification for the whisper-path
gate and the /v1/audio/diagnose endpoint.

The silero-vad package bundles its ~2 MB model in the wheel (verified: loads
with HF_HUB_OFFLINE=1), so these tests run the REAL model — deterministic,
CPU-only, ~2 s load once per session. Fail-open behavior is tested via a
broken loader injection: VAD unavailability must never block transcription.
"""

from __future__ import annotations

import sys
import wave
from pathlib import Path
from unittest.mock import MagicMock

import pytest

# Import the REAL ML deps at collection time: test_whisper_engine.py stubs
# numpy/torch into sys.modules with a "keep them if already imported" guard,
# and this module collects first alphabetically — importing the real ones
# here keeps the whole process on real tensors. (The real-model tests below
# also skip explicitly if some other ordering still poisoned the modules.)
import numpy  # noqa: F401
import torch  # noqa: F401

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from engines.vad import SileroVAD  # noqa: E402


@pytest.fixture()
def real_ml_modules():
    if isinstance(sys.modules.get("torch"), MagicMock) or isinstance(sys.modules.get("numpy"), MagicMock):
        pytest.skip("numpy/torch are mocked by another test module in this process")

FIXTURES = Path(__file__).parent / "fixtures" / "golden_clips"


def _wav_pcm(name: str) -> tuple[bytes, int]:
    with wave.open(str(FIXTURES / name)) as w:
        return w.readframes(w.getnframes()), w.getframerate()


class TestSileroVADReal:
    def test_silence_is_not_speech(self, real_ml_modules):
        vad = SileroVAD()
        pcm = b"\x00\x00" * 16000  # 1 s of digital silence @16k
        result = vad.analyze(pcm, 16000)
        assert result.available is True
        assert result.speech_detected is False
        assert result.speech_ms == 0

    def test_ambient_noise_is_not_speech(self, real_ml_modules):
        # The RMS energy gate cannot make this distinction — noise has
        # energy. This is the whole point of the VAD gate.
        pcm, rate = _wav_pcm("ambient_noise_4s.wav")
        result = SileroVAD().analyze(pcm, rate)
        assert result.available is True
        assert result.speech_detected is False

    def test_real_speech_is_detected(self, real_ml_modules):
        pcm, rate = _wav_pcm("calibration_phrase.wav")
        result = SileroVAD().analyze(pcm, rate)
        assert result.available is True
        assert result.speech_detected is True
        assert result.speech_ms > 500
        assert 0.0 < result.speech_ratio <= 1.0


class TestSileroVADFailOpen:
    def test_broken_loader_fails_open(self):
        def _boom():
            raise RuntimeError("model load failed")

        vad = SileroVAD(loader=_boom)
        result = vad.analyze(b"\x00\x00" * 16000, 16000)
        # Fail OPEN: unavailability must read as "assume speech" so the
        # whisper gate never blocks transcription on a VAD problem.
        assert result.available is False
        assert result.speech_detected is True

    def test_unsupported_sample_rate_fails_open(self):
        vad = SileroVAD()
        result = vad.analyze(b"\x00\x00" * 44100, 44100)
        assert result.available is False
        assert result.speech_detected is True

    def test_load_failure_is_sticky_not_retried_per_call(self):
        calls = []

        def _boom():
            calls.append(1)
            raise RuntimeError("nope")

        vad = SileroVAD(loader=_boom)
        vad.analyze(b"\x00\x00" * 16000, 16000)
        vad.analyze(b"\x00\x00" * 16000, 16000)
        assert len(calls) == 1, "a failed load must not be retried on every call"
