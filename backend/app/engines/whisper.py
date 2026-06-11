"""Whisper STT engines.

WhisperEngine wraps the local HuggingFace transformers pipeline for on-device
transcription with coverage-based confidence estimation. OpenAIAudioClient
talks to the OpenAI Whisper-1 API (cloud fallback) plus TTS endpoint.

Both engines return STTExecutionResult to give callers a uniform shape.
"""

from __future__ import annotations

import io
import json
import logging
import os
import time
import uuid
import wave
from threading import Lock
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

import numpy as np
from fastapi import HTTPException

from nlp import normalize_whitespace

from ._utils import preferred_torch_device, resolve_model_ref
from .results import STTExecutionResult

logger = logging.getLogger("voxflow")


class WhisperEngine:
    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_WHISPER_MODEL", "openai/whisper-small")
        self.model_id = resolve_model_ref(model_ref)
        self._pipeline = None
        self._active_model_id = ""
        self._load_failed = False
        self._warmed_up = False
        self._lock = Lock()

    def _load_pipeline(self) -> None:
        if self._pipeline is not None:
            return
        if self._load_failed:
            return

        with self._lock:
            if self._pipeline is not None:
                return
            if self._load_failed:
                return
            try:
                from transformers import pipeline

                self._pipeline = pipeline(
                    task="automatic-speech-recognition",
                    model=self.model_id,
                    device=preferred_torch_device(),
                    torch_dtype="auto",
                    chunk_length_s=30,
                    stride_length_s=[5, 1],
                )
                self._active_model_id = self.model_id
                logger.info("Loaded Whisper model: %s", self.model_id)
            except Exception as exc:
                logger.error("Failed to load Whisper model %s: %s", self.model_id, exc)
                self._load_failed = True

    def warmup_inference(self, sample_rate: int = 16000, duration_ms: int = 250) -> int:
        if self._pipeline is None or self._warmed_up:
            return 0

        warmup_samples = max(1, int(sample_rate * duration_ms / 1000))
        warmup_audio = np.zeros(warmup_samples, dtype=np.float32)
        started = time.perf_counter()
        try:
            self._pipeline(
                {"array": warmup_audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": "en"},
                return_timestamps=True,
            )
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            self._warmed_up = True
            logger.info("Whisper inference warmup completed in %dms", elapsed_ms)
            return elapsed_ms
        except Exception as exc:
            logger.warning("Whisper inference warmup failed: %s", exc)
            return 0

    def retry_load(self) -> None:
        """Reset failure state to allow retrying model load."""
        self._load_failed = False
        self._warmed_up = False
        self._load_pipeline()

    # Parity with Swift CapturedAudio.isSilent (AudioCaptureService.swift):
    # normalized RMS below this is dead air / digital silence.
    SILENCE_RMS_THRESHOLD = 0.003

    @staticmethod
    def _rms_energy(pcm: bytes) -> float:
        """Normalized RMS (0.0-1.0) of a PCM16 buffer.

        Computed from the raw bytes (not the numpy array) so the energy gate
        stays deterministic under test mocks that stub out numpy — same
        rationale as the duration computation below. Uses stdlib audioop
        (C-speed, present through 3.12) with a strided pure-Python fallback.
        """
        sample_count = len(pcm) // 2
        if sample_count == 0:
            return 0.0
        try:
            import audioop

            return audioop.rms(pcm, 2) / 32768.0
        except ImportError:
            import struct

            samples = struct.unpack(f"<{sample_count}h", pcm)
            stride = max(1, sample_count // 65536)
            strided = samples[::stride]
            return (sum(s * s for s in strided) / len(strided)) ** 0.5 / 32768.0

    @staticmethod
    def _estimate_confidence(output: dict, text: str, audio: "np.ndarray", sample_rate: int) -> float:
        """Derive confidence from pipeline output instead of hardcoding 0.9.

        Uses chunk timestamps to estimate how much of the audio was actually
        spoken. A lone "hello" from 5 seconds of noise will have very low
        coverage and thus low confidence — matching WhisperKit's avgLogprob
        behavior for hallucinated greetings.
        """
        if not text:
            return 0.0

        audio_duration = len(audio) / max(sample_rate, 1)
        word_count = len(text.split())
        chunks = output.get("chunks", [])

        spoken_duration = 0.0
        for chunk in chunks:
            ts = chunk.get("timestamp")
            if ts and len(ts) == 2 and ts[0] is not None and ts[1] is not None:
                spoken_duration += max(0.0, ts[1] - ts[0])

        if spoken_duration > 0 and audio_duration > 0:
            coverage = min(1.0, spoken_duration / audio_duration)
        else:
            expected_words = audio_duration * 2.5
            coverage = min(1.0, word_count / max(expected_words, 1.0))

        confidence = min(0.95, max(0.05, coverage))

        if word_count <= 2 and audio_duration > 2.0 and coverage < 0.3:
            confidence = min(confidence, 0.1)

        return round(confidence, 3)

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> STTExecutionResult:
        stage_timings_ms: dict[str, int] = {}
        model_loaded_before_request = self.model_loaded
        if not pcm:
            logger.warning("Whisper transcribe called with empty audio buffer")
            return STTExecutionResult(
                text="[transcription unavailable: no audio captured]",
                confidence=0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=False,
            )

        if len(pcm) % 2 != 0:
            logger.error("Whisper transcribe received odd-length PCM buffer (%d bytes)", len(pcm))
            return STTExecutionResult(
                text="[transcription unavailable: invalid audio format]",
                confidence=0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=False,
            )

        # Energy gate: no-speech audio must never reach the model. Whisper
        # invents text from silence — empirically, a 3.0s silence clip yields
        # "you" with coverage-confidence 0.687, past every downstream filter.
        # Runs before model load: silence costs ~0ms instead of ~1.4s. (R1.2)
        rms = self._rms_energy(pcm)
        if rms < self.SILENCE_RMS_THRESHOLD:
            logger.info("Energy gate: silent audio (RMS %.4f) — skipping inference", rms)
            stage_timings_ms["energy_gate_rms"] = 0
            return STTExecutionResult(
                text="",
                confidence=0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=False,
            )

        load_started = time.perf_counter()
        self._load_pipeline()
        if not model_loaded_before_request:
            stage_timings_ms["model_load"] = int((time.perf_counter() - load_started) * 1000)

        conversion_started = time.perf_counter()
        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
        stage_timings_ms["pcm_to_float"] = int((time.perf_counter() - conversion_started) * 1000)

        if not self._pipeline:
            if self._load_failed:
                return STTExecutionResult(
                    text="[transcription unavailable: local Whisper model failed to load]",
                    confidence=0.0,
                    stage_timings_ms=stage_timings_ms,
                    model_loaded_before_request=model_loaded_before_request,
                    model_loaded_after_request=self.model_loaded,
                    cold_start=False,
                )
            return STTExecutionResult(
                text="[transcription unavailable: local Whisper model not loaded]",
                confidence=0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=False,
            )

        try:
            # Skip chunking for short audio: the pipeline was constructed
            # with chunk_length_s=30 + stride=[5,1] which adds ~6s of
            # redundant pre/post padding around every chunk. For a 2-10s
            # dictation that fits in a single chunk anyway, the padding is
            # pure overhead. We override chunk_length_s=0 per-call to
            # disable chunking and let the pipeline run the audio as a
            # single sample. (Phase 5.1.)
            #
            # Duration is computed from the raw PCM bytes (int16 = 2 bytes
            # per sample) rather than the numpy array so the path stays
            # deterministic under test mocks that stub out numpy.
            audio_duration_s = (len(pcm) // 2) / max(sample_rate, 1)
            short_audio = audio_duration_s < 20.0
            inference_started = time.perf_counter()
            pipeline_kwargs: dict[str, object] = {
                "generate_kwargs": {"language": language_hint},
                "return_timestamps": True,
            }
            if short_audio:
                pipeline_kwargs["chunk_length_s"] = 0
                logger.debug(
                    "Whisper short-audio fast path: %.2fs < 20s, chunking disabled",
                    audio_duration_s,
                )
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                **pipeline_kwargs,
            )
            stage_timings_ms["stt_inference"] = int((time.perf_counter() - inference_started) * 1000)
            stage_timings_ms["audio_duration_ms"] = int(audio_duration_s * 1000)
            text = str(output.get("text", "")).strip()
            confidence = self._estimate_confidence(output, text, audio, sample_rate)
            return STTExecutionResult(
                text=text,
                confidence=confidence,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=(not model_loaded_before_request and self.model_loaded),
            )
        except Exception as exc:
            logger.error("Whisper transcription failed: %s", exc)
            return STTExecutionResult(
                text=f"[transcription failed: {exc}]",
                confidence=0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=model_loaded_before_request,
                model_loaded_after_request=self.model_loaded,
                cold_start=False,
            )

    @property
    def model_loaded(self) -> bool:
        return self._pipeline is not None

    @property
    def active_model_id(self) -> str:
        return self._active_model_id or self.model_id


class OpenAIAudioClient:
    def __init__(self) -> None:
        self.base_url = os.environ.get("VOXFLOW_OPENAI_BASE_URL", "https://api.openai.com").strip() or "https://api.openai.com"
        self.api_key = os.environ.get("VOXFLOW_OPENAI_API_KEY", "").strip()
        self.stt_model = os.environ.get("VOXFLOW_OPENAI_STT_MODEL", "whisper-1").strip() or "whisper-1"
        self.tts_model = os.environ.get("VOXFLOW_OPENAI_TTS_MODEL", "gpt-4o-mini-tts").strip() or "gpt-4o-mini-tts"
        self.tts_voice = os.environ.get("VOXFLOW_OPENAI_TTS_VOICE", "alloy").strip() or "alloy"

    @property
    def configured(self) -> bool:
        return bool(self.api_key)

    def _endpoint(self, path: str) -> str:
        base = self.base_url.rstrip("/")
        normalized_path = path.lstrip("/")
        if base.lower().endswith("/v1") and normalized_path.lower().startswith("v1/"):
            normalized_path = normalized_path[3:]
        return urlparse.urljoin(f"{base}/", normalized_path)

    @staticmethod
    def _wav_from_pcm16(pcm: bytes, sample_rate: int) -> bytes:
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(pcm)
        return buffer.getvalue()

    @staticmethod
    def _multipart_body(fields: dict[str, str], file_field: str, filename: str, file_bytes: bytes, mime_type: str) -> tuple[bytes, str]:
        boundary = f"----voxflow-{uuid.uuid4().hex}"
        chunks: list[bytes] = []

        for name, value in fields.items():
            chunks.extend(
                [
                    f"--{boundary}\r\n".encode("utf-8"),
                    f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"),
                    str(value).encode("utf-8"),
                    b"\r\n",
                ]
            )

        chunks.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'.encode("utf-8"),
                f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"),
                file_bytes,
                b"\r\n",
                f"--{boundary}--\r\n".encode("utf-8"),
            ]
        )

        return b"".join(chunks), boundary

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> STTExecutionResult:
        if not self.configured:
            return STTExecutionResult(
                text="[transcription unavailable: OpenAI API key not configured]",
                confidence=0.0,
                stage_timings_ms={},
                model_loaded_before_request=False,
                model_loaded_after_request=False,
                cold_start=False,
            )

        wav_encode_started = time.perf_counter()
        wav_bytes = self._wav_from_pcm16(pcm, sample_rate)
        stage_timings_ms = {"wav_encode": int((time.perf_counter() - wav_encode_started) * 1000)}
        body, boundary = self._multipart_body(
            fields={"model": self.stt_model, "language": language_hint},
            file_field="file",
            filename="capture.wav",
            file_bytes=wav_bytes,
            mime_type="audio/wav",
        )

        request = urlrequest.Request(
            url=self._endpoint("/v1/audio/transcriptions"),
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
        )

        try:
            request_started = time.perf_counter()
            with urlrequest.urlopen(request, timeout=40) as response:
                payload = response.read().decode("utf-8")
            stage_timings_ms["stt_request"] = int((time.perf_counter() - request_started) * 1000)
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise HTTPException(status_code=502, detail=f"OpenAI STT HTTP error: {detail[:160]}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"OpenAI STT request failed: {exc}") from exc

        try:
            parsed = json.loads(payload)
            text = normalize_whitespace(str(parsed.get("text", "")))
            return STTExecutionResult(
                text=text,
                confidence=0.88 if text else 0.0,
                stage_timings_ms=stage_timings_ms,
                model_loaded_before_request=True,
                model_loaded_after_request=True,
                cold_start=False,
            )
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"OpenAI STT parse failure: {exc}") from exc

    def synthesize(self, text: str, voice: str, fmt: str) -> bytes:
        if not self.configured:
            raise HTTPException(status_code=503, detail="OpenAI API key not configured")

        payload = {
            "model": self.tts_model,
            "voice": voice or self.tts_voice,
            "input": text,
            "response_format": fmt,
        }
        body = json.dumps(payload).encode("utf-8")
        request = urlrequest.Request(
            url=self._endpoint("/v1/audio/speech"),
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
        )

        try:
            with urlrequest.urlopen(request, timeout=40) as response:
                return response.read()
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise HTTPException(status_code=502, detail=f"OpenAI TTS HTTP error: {detail[:160]}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"OpenAI TTS request failed: {exc}") from exc
