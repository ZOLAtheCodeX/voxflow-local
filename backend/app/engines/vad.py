"""SileroVAD — speech-presence classification (R6).

Wraps the silero-vad package (model bundled in the wheel, ~2 MB, loads
offline — verified with HF_HUB_OFFLINE=1) behind the same lazy-load /
sticky-failure pattern as WhisperEngine. Two consumers:

- WhisperEngine's decode gate: noise-only audio that passes the RMS energy
  gate (noise has energy) still never reaches the model.
- /v1/audio/diagnose: the app posts an empty capture's PCM here so the
  status line can say "speech detected but too quiet" vs "no speech" —
  sharper than the RMS heuristic alone.

Fail-open is the invariant: any load/run failure or unsupported sample rate
reports ``available=False, speech_detected=True`` so a VAD problem can never
block transcription or misreport silence.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from threading import Lock
from typing import Any, Callable

logger = logging.getLogger("voxflow")

_SUPPORTED_RATES = (8000, 16000)


@dataclass(frozen=True)
class VADResult:
    speech_detected: bool
    speech_ratio: float  # fraction of the clip classified as speech, 0.0-1.0
    speech_ms: int
    available: bool  # False = VAD could not run; speech_detected fails open to True


def _default_loader() -> Any:
    from silero_vad import load_silero_vad

    return load_silero_vad()


class SileroVAD:
    def __init__(self, loader: Callable[[], Any] = _default_loader) -> None:
        self._loader = loader
        self._model: Any = None
        self._load_failed = False
        self._lock = Lock()

    def _load(self) -> Any:
        if self._model is not None or self._load_failed:
            return self._model
        with self._lock:
            if self._model is not None or self._load_failed:
                return self._model
            try:
                self._model = self._loader()
                logger.info("Loaded Silero VAD model")
            except Exception as exc:
                # Sticky, like WhisperEngine's _load_failed: retrying a
                # deterministic load failure per call would just burn time.
                self._load_failed = True
                logger.error("Failed to load Silero VAD model: %s", exc)
        return self._model

    def analyze(self, pcm: bytes, sample_rate: int) -> VADResult:
        """Classify a PCM16LE mono buffer. Fail-open on any problem."""
        if sample_rate not in _SUPPORTED_RATES:
            logger.warning("VAD: unsupported sample rate %d — failing open", sample_rate)
            return VADResult(speech_detected=True, speech_ratio=0.0, speech_ms=0, available=False)
        model = self._load()
        if model is None:
            return VADResult(speech_detected=True, speech_ratio=0.0, speech_ms=0, available=False)
        try:
            import numpy as np
            import torch
            from silero_vad import get_speech_timestamps

            samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
            if samples.size == 0:
                return VADResult(speech_detected=False, speech_ratio=0.0, speech_ms=0, available=True)
            audio = torch.from_numpy(samples)
            with self._lock:
                # The silero model keeps internal state across calls; serialize.
                timestamps = get_speech_timestamps(audio, model, sampling_rate=sample_rate)
            speech_samples = sum(t["end"] - t["start"] for t in timestamps)
            total = samples.size
            return VADResult(
                speech_detected=bool(timestamps),
                speech_ratio=min(1.0, speech_samples / total),
                speech_ms=int(speech_samples / sample_rate * 1000),
                available=True,
            )
        except Exception as exc:
            logger.error("VAD analysis failed: %s — failing open", exc)
            return VADResult(speech_detected=True, speech_ratio=0.0, speech_ms=0, available=False)


# Shared lazy singleton — the model is small but there is no reason to hold
# two copies for the whisper gate and the diagnose endpoint.
_shared: SileroVAD | None = None
_shared_lock = Lock()


def shared_vad() -> SileroVAD:
    global _shared
    if _shared is None:
        with _shared_lock:
            if _shared is None:
                _shared = SileroVAD()
    return _shared
