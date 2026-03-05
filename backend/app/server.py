from __future__ import annotations

import base64
import io
import json
import logging
import os
import re
import secrets
import sys
import time
import uuid
import wave
from collections import defaultdict
from contextlib import asynccontextmanager
from dataclasses import dataclass
from difflib import SequenceMatcher
from threading import Lock
from typing import Any
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

import numpy as np
from fastapi import FastAPI, HTTPException, Request, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from text_cleanup_rules import (
    ALWAYS_FILLERS,
    CASUAL_INTERJECTIONS,
    CONTRACTIONS,
    HEDGING_PHRASES,
    PHRASE_FILLERS,
    SOFTENERS,
    SPOKEN_PUNCTUATION,
)

logger = logging.getLogger("voxflow")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)

MAX_AUDIO_PAYLOAD_BYTES = 10 * 1024 * 1024  # 10 MB decoded PCM limit
MAX_AUDIO_BASE64_CHARS = int(MAX_AUDIO_PAYLOAD_BYTES * 4 / 3) + 100


def resolve_model_ref(model_id: str) -> str:
    models_dir = os.environ.get("VOXFLOW_MODELS_DIR")
    if not models_dir:
        return model_id

    candidate = os.path.join(models_dir, model_id.replace("/", "__"))
    return candidate if os.path.isdir(candidate) else model_id


def preferred_torch_device() -> str | int:
    try:
        import torch

        if bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available()):
            return "mps"
    except Exception as exc:
        logger.debug("MPS detection failed: %s", exc)
    return -1


@dataclass
class RuntimeState:
    service_status: str = "ok"
    model_loaded: bool = False
    mps_available: bool = False
    offline_mode: bool = True
    stt_backend: str = "whisper"


class TranscribeRequest(BaseModel):
    session_id: str
    audio_pcm16le: str
    sample_rate: int = Field(default=16000, ge=8000, le=192000)
    language_hint: str = "en"
    chunk_index: int = 0


class TranscribeResponse(BaseModel):
    text: str
    is_final: bool
    latency_ms: int
    confidence_estimate: float
    processing_time_ms: int = 0


class CleanupRequest(BaseModel):
    session_id: str
    mode: str
    input_text: str
    tone_style: str = "neutral"
    provider_mode: str = "localOnly"
    consent_token: str | None = None
    allow_raw: bool = False


class CleanupResponse(BaseModel):
    output_text: str
    mode_applied: str
    guardrail_triggered: bool


class TranslateRequest(BaseModel):
    session_id: str
    source_text: str
    source_language: str = "en"
    target_language: str = "de"
    provider_mode: str = "localOnly"
    consent_token: str | None = None
    allow_raw: bool = False


class TranslateResponse(BaseModel):
    source_text: str
    translated_text: str


class MeetingRequest(BaseModel):
    session_id: str
    transcript: str
    tone_style: str = "neutral"
    provider_mode: str = "localOnly"
    consent_token: str | None = None
    allow_raw: bool = False


class MeetingSpeakerSegment(BaseModel):
    speaker: str
    text: str
    utterance_count: int


class MeetingTaskOwner(BaseModel):
    task: str
    owner: str
    confidence: float


class MeetingSummaryResponse(BaseModel):
    transcript: str
    summary: str
    decisions: list[str]
    action_items: list[str]
    follow_ups: list[str]
    speaker_segments: list[MeetingSpeakerSegment] = Field(default_factory=list)
    task_owners: list[MeetingTaskOwner] = Field(default_factory=list)
    markdown_export: str = ""
    notion_export: str = ""


class PromptFrameRequest(BaseModel):
    session_id: str
    text: str
    consent_token: str | None = None


class PromptFrameResponse(BaseModel):
    framed_prompt: str
    detected_intent: str


class TTSRequest(BaseModel):
    text: str
    voice: str = "alloy"
    format: str = "mp3"


class TTSResponse(BaseModel):
    audio_base64: str
    format: str


class PrivacyPreviewRequest(BaseModel):
    session_id: str
    operation: str
    input_text: str


class PrivacyPreviewResponse(BaseModel):
    operation: str
    token: str
    original_text: str
    redacted_text: str


class ReadyResponse(BaseModel):
    service_status: str
    ready_for_dictation: bool
    stt_backend: str
    active_stt_model: str
    active_stt_model_loaded: bool
    stt_fallback_active: bool
    offline_mode: bool
    python_executable: str
    python_version: str
    models_dir: str
    models_dir_exists: bool
    openai_audio_configured: bool
    private_api_configured: bool
    private_api_policy_version: str
    private_api_policy_ready: bool
    issues: list[str] = Field(default_factory=list)


class WhisperEngine:
    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_WHISPER_MODEL", "openai/whisper-small")
        self.model_id = resolve_model_ref(model_ref)
        self._pipeline = None
        self._active_model_id = ""
        self._load_failed = False
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

    def retry_load(self) -> None:
        """Reset failure state to allow retrying model load."""
        self._load_failed = False
        self._load_pipeline()

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> tuple[str, float]:
        if not pcm:
            logger.warning("Whisper transcribe called with empty audio buffer")
            return "[transcription unavailable: no audio captured]", 0.0

        if len(pcm) % 2 != 0:
            logger.error("Whisper transcribe received odd-length PCM buffer (%d bytes)", len(pcm))
            return "[transcription unavailable: invalid audio format]", 0.0

        self._load_pipeline()

        audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0

        if not self._pipeline:
            if self._load_failed:
                return "[transcription unavailable: local Whisper model failed to load]", 0.0
            return "[transcription unavailable: local Whisper model not loaded]", 0.0

        try:
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": language_hint},
                return_timestamps=True,
            )
            text = str(output.get("text", "")).strip()
            confidence = 0.9 if text else 0.0
            return text, confidence
        except Exception as exc:
            logger.error("Whisper transcription failed: %s", exc)
            return f"[transcription failed: {exc}]", 0.0

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

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> tuple[str, float]:
        if not self.configured:
            return "[transcription unavailable: OpenAI API key not configured]", 0.0

        wav_bytes = self._wav_from_pcm16(pcm, sample_rate)
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
            with urlrequest.urlopen(request, timeout=40) as response:
                payload = response.read().decode("utf-8")
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise HTTPException(status_code=502, detail=f"OpenAI STT HTTP error: {detail[:160]}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"OpenAI STT request failed: {exc}") from exc

        try:
            parsed = json.loads(payload)
            text = normalize_whitespace(str(parsed.get("text", "")))
            return text, 0.88 if text else 0.0
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


class PolishEngine:
    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_POLISH_MODEL", "google/flan-t5-small")
        self.model_id = resolve_model_ref(model_ref)
        self._pipeline = None
        self._load_failed = False
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
                    task="text2text-generation",
                    model=self.model_id,
                    device=preferred_torch_device(),
                )
                logger.info("Loaded polish model: %s", self.model_id)
            except Exception as exc:
                logger.error("Failed to load polish model %s: %s", self.model_id, exc)
                self._load_failed = True

    def retry_load(self) -> None:
        """Reset failure state to allow retrying model load."""
        self._load_failed = False
        self._load_pipeline()

    _TONE_INSTRUCTIONS = {
        "concise": "Remove unnecessary words. Be direct and brief.",
        "formal": "Use professional language. Avoid contractions and slang.",
        "friendly": "Use warm, approachable language.",
        "neutral": "Use clear, natural language.",
    }

    def polish(self, text: str, tone: str) -> tuple[str, bool]:
        self._load_pipeline()

        if not text.strip():
            return "", False

        if self._pipeline:
            tone_instruction = self._TONE_INSTRUCTIONS.get(tone.lower(), self._TONE_INSTRUCTIONS["neutral"])
            prompt = (
                f"Rewrite this spoken transcript as clean written text. "
                f"Do not add new information. {tone_instruction} "
                f"Transcript: {text}"
            )
            word_count = len(text.split())
            max_tokens = min(200, max(60, word_count * 3))
            try:
                result = self._pipeline(prompt, max_new_tokens=max_tokens)[0]["generated_text"].strip()
                if self._guardrail_triggered(text, result):
                    return apply_tone(light_cleanup(text), tone), True
                # If model echoed the input unchanged, apply light_cleanup as floor
                if self._is_echo(text, result):
                    return apply_tone(light_cleanup(text), tone), False
                return result, False
            except Exception as exc:
                logger.error("Polish inference failed: %s", exc)

        return apply_tone(light_cleanup(text), tone), False

    @staticmethod
    def _is_echo(original: str, candidate: str) -> bool:
        """Check if the model just echoed the input back (possibly with minor punctuation changes)."""
        def _normalize(s: str) -> str:
            return re.sub(r"[^\w\s]", "", s.strip().lower())
        return _normalize(original) == _normalize(candidate)

    @staticmethod
    def _guardrail_triggered(original: str, candidate: str) -> bool:
        if not candidate.strip():
            return True

        similarity = SequenceMatcher(None, original.lower(), candidate.lower()).ratio()
        if similarity < 0.55:
            return True

        original_length = max(1, len(original.split()))
        candidate_length = len(candidate.split())
        length_ratio = candidate_length / original_length

        # Short inputs (<=5 words) naturally expand when polished — skip length ratio
        if original_length <= 5:
            return False

        # Medium inputs (6-10 words) get wider tolerance
        max_ratio = 2.5 if original_length <= 10 else 1.8
        return length_ratio < 0.6 or length_ratio > max_ratio


class TranslateEngine:
    def __init__(self) -> None:
        model_ref = os.environ.get("VOXFLOW_TRANSLATE_MODEL", "google/translategemma-4b-it")
        self.model_id = resolve_model_ref(model_ref)
        configured_backend = os.environ.get("VOXFLOW_TRANSLATE_BACKEND", "auto").lower()
        self.backend = self._resolve_backend(configured_backend, self.model_id)
        self._pipeline = None
        self._lock = Lock()

    @staticmethod
    def _resolve_backend(configured_backend: str, model_id: str) -> str:
        if configured_backend in {"translategemma", "marian"}:
            return configured_backend

        return "translategemma" if "translategemma" in model_id.lower() else "marian"

    def _load_pipeline(self) -> None:
        if self._pipeline is not None:
            return

        with self._lock:
            if self._pipeline is not None:
                return
            try:
                from transformers import pipeline

                if self.backend == "translategemma":
                    self._pipeline = pipeline(
                        task="image-text-to-text",
                        model=self.model_id,
                        device=preferred_torch_device(),
                        torch_dtype="auto",
                    )
                else:
                    self._pipeline = pipeline(task="translation", model=self.model_id, device=preferred_torch_device())
                logger.info("Loaded translate model: %s (backend=%s)", self.model_id, self.backend)
            except Exception as exc:
                logger.error("Failed to load translate model %s: %s", self.model_id, exc)
                self._pipeline = False

    def translate(self, text: str) -> str:
        self._load_pipeline()
        if self._pipeline:
            try:
                if self.backend == "translategemma":
                    messages = [
                        {
                            "role": "user",
                            "content": [
                                {
                                    "type": "text",
                                    "source_lang_code": "en",
                                    "target_lang_code": "de-DE",
                                    "text": text,
                                }
                            ],
                        }
                    ]
                    result = self._pipeline(text=messages, max_new_tokens=220, do_sample=False)
                    translated = self._extract_translategemma_output(result)
                    return translated or "[translation unavailable: malformed TranslateGemma output]"

                result = self._pipeline(text)
                return str(result[0]["translation_text"]).strip()
            except Exception as exc:
                logger.error("Translation inference failed: %s", exc)

        return "[translation unavailable: local EN→DE model not loaded]"

    @staticmethod
    def _extract_translategemma_output(result: list[dict[str, Any]]) -> str:
        if not result:
            return ""

        generated = result[0].get("generated_text")
        if isinstance(generated, list) and generated:
            last_message = generated[-1]
            if isinstance(last_message, dict):
                content = last_message.get("content")
                return str(content).strip() if content is not None else ""

        if isinstance(generated, str):
            return generated.strip()

        return ""


class PromptFramingEngine:
    _INTENT_KEYWORDS: list[tuple[str, list[str]]] = [
        ("email", ["email", "reply", "message to", "follow up", "follow-up"]),
        ("code", [r"\bfunction\b", r"\bcode\b", "debug", "refactor", "review", "implement", r"\bapi\b", "endpoint", "algorithm", r"\bclass\b", r"\bmethod\b"]),
        ("explain", ["explain", "what is", "how does", "teach", "break down", "why does", "how do"]),
        ("creative", ["blog", "tweet", "post", "story", "tagline", r"\bcopy\b", "headline", "slogan", "draft"]),
        ("data", ["summarize", "compare", "extract", "analyze", "list the", "differences between", "table of"]),
    ]

    _PRIORITY = ["email", "code", "explain", "creative", "data"]

    _TEMPLATES: dict[str, str] = {
        "email": (
            "Task: Draft an email based on the following instructions.\n\n"
            "Instructions: {text}\n\n"
            "Constraints:\n"
            "- Professional tone unless otherwise specified\n"
            "- Concise — aim for 3-5 sentences\n"
            "- Include subject line suggestion\n\n"
            "Output format: Complete email with Subject and Body."
        ),
        "code": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Write clean, production-ready code\n"
            "- Include brief comments for non-obvious logic\n"
            "- Handle edge cases\n\n"
            "Output format: Code with explanation of approach."
        ),
        "explain": (
            "Task: Explain the following clearly and concisely.\n\n"
            "Topic: {text}\n\n"
            "Constraints:\n"
            "- Assume intermediate knowledge level\n"
            "- Use concrete examples where helpful\n"
            "- Keep it under 200 words unless complexity requires more\n\n"
            "Output format: Clear explanation with examples."
        ),
        "creative": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Engaging and original\n"
            "- Match the tone implied in the instructions\n"
            "- Provide 2-3 variations if the output is short-form\n\n"
            "Output format: Creative content as described."
        ),
        "data": (
            "Task: {text}\n\n"
            "Constraints:\n"
            "- Be precise and factual\n"
            "- Use structured format (bullets, tables) where appropriate\n"
            "- Call out assumptions\n\n"
            "Output format: Structured analysis."
        ),
        "general": (
            "Task: {text}\n\n"
            "Please provide a thorough, well-structured response."
        ),
    }

    @staticmethod
    def _phrase_matches(phrase: str, text: str) -> bool:
        if r"\b" in phrase:
            return bool(re.search(phrase, text))
        return phrase in text

    def detect_intent(self, text: str) -> str:
        lowered = text.lower()
        if not lowered.strip():
            return "general"

        scores: dict[str, int] = {}
        for intent, phrases in self._INTENT_KEYWORDS:
            count = sum(1 for p in phrases if self._phrase_matches(p, lowered))
            if count > 0:
                scores[intent] = count

        if not scores:
            return "general"

        max_score = max(scores.values())
        for intent in self._PRIORITY:
            if scores.get(intent) == max_score:
                return intent

        return "general"

    def frame(self, text: str, intent: str) -> str:
        template = self._TEMPLATES.get(intent, self._TEMPLATES["general"])
        return template.format(text=text)


def normalize_provider_mode(provider_mode: str) -> str:
    normalized = provider_mode.strip().lower()
    if normalized in {"privateapi", "private_api", "private-api"}:
        return "private_api"
    return "local_only"


def normalize_stt_backend(raw: str) -> str:
    normalized = raw.strip().lower()
    if normalized in {"whisper", "openai"}:
        return normalized
    return "whisper"


def redact_sensitive_text(text: str) -> str:
    redacted = text
    patterns: list[tuple[str, str]] = [
        (r"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b", "[EMAIL]"),
        (r"https?://[^\s,)>\"']+", "[URL]"),
        (r"\b(?:\+?\d{1,3}[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b", "[PHONE]"),
        (r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)", "[SSN]"),
        (r"\b(?:\d[ -]*?){13,19}\b", "[ACCOUNT_NUMBER]"),
        (r"\b\d{9,}\b", "[ID]"),
    ]
    for pattern, replacement in patterns:
        redacted = re.sub(pattern, replacement, redacted, flags=re.IGNORECASE)
    return normalize_whitespace(redacted)


def extract_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        return {}

    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, flags=re.IGNORECASE)
        stripped = re.sub(r"\s*```$", "", stripped)

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return {}

    try:
        parsed = json.loads(stripped[start : end + 1])
    except Exception as exc:
        logger.error("Failed to parse JSON object: %s", exc)
        return {}

    return parsed if isinstance(parsed, dict) else {}


def coerce_string_list(value: Any, limit: int) -> list[str]:
    if isinstance(value, list):
        items = value
    elif value is None:
        items = []
    else:
        items = [value]
    return [normalize_whitespace(str(item)) for item in items if str(item).strip()][:limit]


def is_placeholder_text(text: str) -> bool:
    lowered = text.lower()
    return lowered.startswith("[translation unavailable") or lowered.startswith("[transcription unavailable")


# Phrases Whisper hallucinates that are NEVER real dictation — filter at any duration
_WHISPER_HALLUCINATION_ALWAYS = frozenset(
    p.lower()
    for p in [
        "Thank you for watching.",
        "Thank you for watching!",
        "Thanks for watching.",
        "Thanks for watching!",
        "Thank you so much for watching.",
        "Thank you so much for watching!",
        "Subscribe to my channel.",
        "Subscribe to the channel.",
        "Subscribe for more.",
        "Subscribe for more!",
        "Please subscribe.",
        "Like and subscribe.",
        "Please like and subscribe.",
        "♪",
        "♪♪",
        "♪♪♪",
        "...",
        # Common Whisper silence hallucinations — filtered at any duration
        "Hello.",
        "Hello",
        "Hi.",
        "Hi",
        "Hey.",
        "Hey",
    ]
)

# Phrases only filtered on short audio (< 3s) — could be real speech in longer recordings
_WHISPER_HALLUCINATION_SHORT_ONLY = frozenset(
    p.lower()
    for p in [
        "Thank you.",
        "Thanks.",
        "Bye.",
        "Goodbye.",
        "you",
        "You",
    ]
)


def is_whisper_hallucination(text: str, short_audio: bool = True) -> bool:
    """Detect common Whisper hallucination patterns.

    Args:
        text: The transcribed text to check.
        short_audio: If True, also filters single-word/short phrases that could
                     be real speech in longer recordings.
    """
    stripped = text.strip()
    if not stripped:
        return True
    lowered = stripped.lower()
    # Always-filter phrases (never real dictation)
    if lowered in _WHISPER_HALLUCINATION_ALWAYS:
        return True
    # Short-audio-only filters
    if short_audio:
        if lowered in _WHISPER_HALLUCINATION_SHORT_ONLY:
            return True
        # Repeated single word (e.g., "you you you")
        words = lowered.split()
        if len(words) >= 3 and len(set(words)) == 1:
            return True
    return False


@dataclass
class ConsentRecord:
    token: str
    session_id: str
    operation: str
    original_text: str
    redacted_text: str
    created_at: float
    max_uses: int = 1
    use_count: int = 0


class ConsentStore:
    def __init__(self, ttl_seconds: int = 1800) -> None:
        self._ttl_seconds = ttl_seconds
        self._records: dict[str, ConsentRecord] = {}
        self._lock = Lock()

    def create(self, session_id: str, operation: str, original_text: str, redacted_text: str, max_uses: int = 1) -> ConsentRecord:
        token = secrets.token_urlsafe(20)
        record = ConsentRecord(
            token=token,
            session_id=session_id,
            operation=operation,
            original_text=original_text,
            redacted_text=redacted_text,
            created_at=time.time(),
            max_uses=max(1, max_uses),
        )
        with self._lock:
            self._prune_locked()
            self._records[token] = record
        return record

    def resolve(self, token: str, session_id: str, operation: str) -> ConsentRecord | None:
        with self._lock:
            self._prune_locked()
            record = self._records.get(token)
            if not record:
                return None
            if record.session_id != session_id or record.operation != operation:
                return None
            # Bounded-use: increment counter, consume when limit reached
            record.use_count += 1
            if record.use_count >= record.max_uses:
                self._records.pop(token, None)
            return record

    def _prune_locked(self) -> None:
        cutoff = time.time() - self._ttl_seconds
        expired = [token for token, record in self._records.items() if record.created_at < cutoff]
        for token in expired:
            self._records.pop(token, None)


class AuditLogger:
    _audit_logger = logging.getLogger("voxflow.audit")

    def log(self, *, operation: str, provider_mode: str, session_id: str, payload_length: int, redacted: bool) -> None:
        self._audit_logger.info(
            json.dumps(
                {
                    "event": "privacy_audit",
                    "operation": operation,
                    "provider_mode": provider_mode,
                    "session_id": session_id,
                    "payload_length": payload_length,
                    "redacted": redacted,
                    "timestamp": int(time.time()),
                }
            ),
        )


class PrivateAPIClient:
    def __init__(self) -> None:
        self.base_url = os.environ.get("VOXFLOW_PRIVATE_API_BASE_URL", "").strip()
        self.model = os.environ.get("VOXFLOW_PRIVATE_API_MODEL", "gpt-4o-mini").strip() or "gpt-4o-mini"
        self.api_key = os.environ.get("VOXFLOW_PRIVATE_API_KEY", "").strip()

    @property
    def configured(self) -> bool:
        return bool(self.base_url and self.model and self.api_key)

    def _endpoint(self, path: str) -> str:
        base = self.base_url.rstrip("/")
        normalized_path = path.lstrip("/")
        if base.lower().endswith("/v1") and normalized_path.lower().startswith("v1/"):
            normalized_path = normalized_path[3:]
        return urlparse.urljoin(f"{base}/", normalized_path)

    def _chat_completion(self, system_prompt: str, user_prompt: str, max_tokens: int = 260) -> str:
        if not self.configured:
            raise HTTPException(status_code=503, detail="Private API not configured")

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.2,
            "max_tokens": max_tokens,
        }

        body = json.dumps(payload).encode("utf-8")
        request = urlrequest.Request(
            url=self._endpoint("/v1/chat/completions"),
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.api_key}",
            },
        )

        try:
            with urlrequest.urlopen(request, timeout=20) as response:
                response_body = response.read().decode("utf-8")
        except urlerror.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise HTTPException(status_code=502, detail=f"Private API HTTP error: {detail[:160]}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Private API request failed: {exc}") from exc

        try:
            parsed = json.loads(response_body)
            choices = parsed.get("choices", [])
            if not choices:
                raise ValueError("empty choices")
            message = choices[0].get("message", {})
            content = message.get("content", "")
            if isinstance(content, list):
                joined = []
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        joined.append(str(item.get("text", "")))
                    elif isinstance(item, str):
                        joined.append(item)
                return normalize_whitespace(" ".join(joined))
            return normalize_whitespace(str(content))
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Private API response parse failure: {exc}") from exc

    def cleanup(self, mode: str, tone: str, text: str) -> tuple[str, bool]:
        if mode == "raw":
            return normalize_whitespace(text), False

        system_prompt = (
            "You transform dictated text. Preserve meaning, proper nouns, dates, and numbers. "
            "Return only final text."
        )

        if mode == "light":
            user_prompt = (
                f"Apply light cleanup with tone '{tone}'. "
                "Fix punctuation/casing and remove obvious filler words conservatively.\n\n"
                f"Text:\n{text}"
            )
            return self._chat_completion(system_prompt, user_prompt, max_tokens=220), False

        if mode == "polish":
            user_prompt = (
                f"Apply polish cleanup with tone '{tone}'. "
                "Improve readability and fluency while preserving meaning exactly.\n\n"
                f"Text:\n{text}"
            )
            candidate = self._chat_completion(system_prompt, user_prompt, max_tokens=280)
            if PolishEngine._guardrail_triggered(text, candidate):
                return apply_tone(light_cleanup(text), tone), True
            return candidate, False

        raise HTTPException(status_code=400, detail=f"Unsupported cleanup mode: {mode}")

    def translate_en_de(self, text: str) -> str:
        system_prompt = "Translate English to German accurately. Return only German text."
        user_prompt = f"Translate this to German:\n{text}"
        translated = self._chat_completion(system_prompt, user_prompt, max_tokens=260)
        return translated or "[translation unavailable: private API returned empty text]"

    def meeting_summary(self, transcript: str, tone: str) -> dict[str, Any]:
        system_prompt = (
            "You summarize meeting transcripts into structured JSON. "
            "Return JSON only with keys: summary, decisions, action_items, follow_ups, speaker_segments, task_owners."
        )
        user_prompt = (
            f"Tone: {tone}\n"
            "Transcript:\n"
            f"{transcript}\n\n"
            "JSON schema:\n"
            "{"
            '"summary":"string",'
            '"decisions":["string"],'
            '"action_items":["string"],'
            '"follow_ups":["string"],'
            '"speaker_segments":[{"speaker":"string","text":"string","utterance_count":1}],'
            '"task_owners":[{"task":"string","owner":"string","confidence":0.0}]'
            "}"
        )
        content = self._chat_completion(system_prompt, user_prompt, max_tokens=420)
        parsed = extract_json_object(content)

        decisions = coerce_string_list(parsed.get("decisions"), 5)
        action_items = coerce_string_list(parsed.get("action_items"), 6)
        follow_ups = coerce_string_list(parsed.get("follow_ups"), 4)
        speaker_segments = coerce_speaker_segments(parsed.get("speaker_segments"), transcript)
        task_owners = coerce_task_owners(parsed.get("task_owners"), action_items, transcript)

        markdown_export = render_meeting_markdown_export(
            summary=normalize_whitespace(str(parsed.get("summary", ""))),
            decisions=decisions,
            action_items=action_items,
            follow_ups=follow_ups,
            speaker_segments=speaker_segments,
            task_owners=task_owners,
        )
        notion_export = render_meeting_notion_export(
            summary=normalize_whitespace(str(parsed.get("summary", ""))),
            decisions=decisions,
            action_items=action_items,
            follow_ups=follow_ups,
            speaker_segments=speaker_segments,
            task_owners=task_owners,
        )

        return {
            "summary": normalize_whitespace(str(parsed.get("summary", ""))),
            "decisions": decisions,
            "action_items": action_items,
            "follow_ups": follow_ups,
            "speaker_segments": speaker_segments,
            "task_owners": task_owners,
            "markdown_export": markdown_export,
            "notion_export": notion_export,
        }

def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


# ── Text cleanup helpers (parity with Swift TextCleanupService) ─────


def replace_spoken_punctuation(text: str) -> str:
    """Convert spoken punctuation words to actual punctuation characters."""
    result = text
    for pattern, replacement in SPOKEN_PUNCTUATION:
        result = pattern.sub(replacement, result)
    return result


def remove_repeated_words(text: str) -> str:
    """Remove adjacent duplicate words (case-insensitive)."""
    words = text.split()
    if len(words) <= 1:
        return text
    result = [words[0]]
    for word in words[1:]:
        if word.lower() != result[-1].lower():
            result.append(word)
    return " ".join(result)


def remove_fillers(text: str) -> str:
    """Remove filler words and phrases.

    Phase 0: Multi-word phrase fillers (regex).
    Phase 1: Single-word always-fillers (set membership).
    No Phase 2 (POS-aware ambiguous fillers) — accepted gap vs Swift.
    """
    result = text
    # Phase 0: phrase fillers
    for pattern, replacement in PHRASE_FILLERS:
        result = pattern.sub(replacement, result)
    result = normalize_whitespace(result)
    # Phase 1: always-fillers
    words = result.split()
    words = [w for w in words if w.lower() not in ALWAYS_FILLERS]
    return " ".join(words)


def split_and_recase(text: str) -> str:
    """Split on sentence-ending punctuation and uppercase first char of each.

    Intentional divergence from Swift: Python uses regex-only splitting while
    Swift uses NLTokenizer + regex sub-splitting. This can diverge on edge
    cases like abbreviations ("Dr.") or punctuation without following whitespace.
    Accepted tradeoff to avoid adding nltk/spacy dependency.
    """
    segments = re.split(r"(?<=[.!?])\s+", text)
    recased = []
    for seg in segments:
        seg = seg.strip()
        if seg:
            seg = seg[0].upper() + seg[1:]
        recased.append(seg)
    return " ".join(recased)


# ── Tone helpers ────────────────────────────────────────────────────


def _apply_concise_tone(text: str) -> str:
    result = text
    for pattern, replacement in HEDGING_PHRASES + SOFTENERS:
        result = pattern.sub(replacement, result)
    return normalize_whitespace(result)


def _apply_formal_tone(text: str) -> str:
    result = text
    for pattern, replacement in CONTRACTIONS + CASUAL_INTERJECTIONS:
        result = pattern.sub(replacement, result)
    result = normalize_whitespace(result)
    if result and result[-1] not in ".!?":
        result += "."
    return result


def _apply_friendly_tone(text: str) -> str:
    """Intentional divergence from Swift: Python only appends '!' when no
    terminal punctuation exists. Swift also does POS-based imperative softening
    ("Send X" → "Let's send X") using NLTagger. Accepted tradeoff — same
    reasoning as POS-aware filler removal.
    """
    if text and text[-1] not in ".!?":
        return text + "!"
    return text


def apply_tone(text: str, tone: str) -> str:
    """Apply tone transform. Dispatches to private helpers."""
    normalized = normalize_whitespace(text)
    tone = tone.lower().strip()
    if tone == "concise":
        return _apply_concise_tone(normalized)
    if tone == "formal":
        return _apply_formal_tone(normalized)
    if tone == "friendly":
        return _apply_friendly_tone(normalized)
    # neutral or unknown → no transform
    return normalized


def light_cleanup(text: str) -> str:
    """6-step cleanup pipeline mirroring Swift TextCleanupService.cleanup(.light)."""
    # Step 1: normalize whitespace
    cleaned = normalize_whitespace(text)
    if not cleaned:
        return ""
    # Step 2: spoken punctuation → actual characters
    cleaned = replace_spoken_punctuation(cleaned)
    # Step 3: repeated word dedup
    cleaned = remove_repeated_words(cleaned)
    # Step 4: sentence split + recase
    cleaned = split_and_recase(cleaned)
    # Step 5: filler removal
    cleaned = remove_fillers(cleaned)
    # Step 6: final normalization + trailing punctuation + capitalize
    cleaned = normalize_whitespace(cleaned)
    if not cleaned:
        return ""
    if cleaned[-1] not in ".!?":
        cleaned += "."
    if cleaned[0].islower():
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned


def split_sentences(text: str) -> list[str]:
    normalized = normalize_whitespace(text)
    if not normalized:
        return []

    sentences = [chunk.strip() for chunk in re.split(r"(?<=[.!?])\s+", normalized) if chunk.strip()]
    if sentences:
        return sentences
    return [normalized]


def infer_speaker_segments(transcript: str) -> list[dict[str, Any]]:
    normalized = transcript.strip()
    if not normalized:
        return []

    segments: list[dict[str, Any]] = []
    by_speaker: dict[str, list[str]] = {}
    speaker_pattern = re.compile(r"^\s*(?P<speaker>[A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+)?|Speaker\s+\d+)\s*[:\-]\s*(?P<text>.+)$")

    for line in transcript.splitlines():
        line = line.strip()
        if not line:
            continue
        match = speaker_pattern.match(line)
        if not match:
            continue
        speaker = normalize_whitespace(match.group("speaker"))
        utterance = normalize_whitespace(match.group("text"))
        if not utterance:
            continue
        by_speaker.setdefault(speaker, []).append(utterance)

    if by_speaker:
        for speaker, utterances in by_speaker.items():
            segments.append(
                {
                    "speaker": speaker,
                    "text": " ".join(utterances[:2]),
                    "utterance_count": len(utterances),
                }
            )
        return segments[:6]

    fallback_excerpt = normalize_whitespace(transcript)
    if len(fallback_excerpt) > 220:
        fallback_excerpt = f"{fallback_excerpt[:217]}..."
    return [{"speaker": "Speaker 1", "text": fallback_excerpt, "utterance_count": 1}]


def infer_task_owners(action_items: list[str], transcript: str) -> list[dict[str, Any]]:
    if not action_items:
        return []

    results: list[dict[str, Any]] = []
    name_lead_pattern = re.compile(r"^(?P<owner>[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\s+(will|to|should|needs to|is going to)\b")
    name_any_pattern = re.compile(r"\b(?P<owner>[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\s+(will|to|should|needs to|is going to)\b")

    known_speakers = {segment["speaker"] for segment in infer_speaker_segments(transcript) if segment.get("speaker")}

    for item in action_items[:10]:
        cleaned_item = normalize_whitespace(item)
        owner = "Unassigned"
        confidence = 0.35

        lead_match = name_lead_pattern.search(cleaned_item)
        if lead_match:
            owner = normalize_whitespace(lead_match.group("owner"))
            confidence = 0.92
        else:
            any_match = name_any_pattern.search(cleaned_item)
            if any_match:
                owner = normalize_whitespace(any_match.group("owner"))
                confidence = 0.78

        results.append(
            {
                "task": cleaned_item,
                "owner": owner,
                "confidence": round(confidence, 2),
            }
        )

    return results


def coerce_speaker_segments(value: Any, transcript: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return infer_speaker_segments(transcript)

    rows: list[dict[str, Any]] = []
    for entry in value[:6]:
        if not isinstance(entry, dict):
            continue
        speaker = normalize_whitespace(str(entry.get("speaker", "Speaker 1")))
        text = normalize_whitespace(str(entry.get("text", "")))
        if not text:
            continue
        try:
            utterance_count = max(1, int(entry.get("utterance_count", 1)))
        except Exception as exc:
            logger.error("Failed to coerce utterance_count: %s", exc)
            utterance_count = 1
        rows.append({"speaker": speaker, "text": text, "utterance_count": utterance_count})

    return rows or infer_speaker_segments(transcript)


def coerce_task_owners(value: Any, action_items: list[str], transcript: str) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return infer_task_owners(action_items, transcript)

    rows: list[dict[str, Any]] = []
    for entry in value[:10]:
        if not isinstance(entry, dict):
            continue
        task = normalize_whitespace(str(entry.get("task", "")))
        owner = normalize_whitespace(str(entry.get("owner", "Unassigned")))
        if not task:
            continue
        try:
            confidence = float(entry.get("confidence", 0.5))
        except Exception as exc:
            logger.error("Failed to coerce confidence: %s", exc)
            confidence = 0.5
        confidence = max(0.0, min(1.0, confidence))
        rows.append({"task": task, "owner": owner or "Unassigned", "confidence": round(confidence, 2)})

    return rows or infer_task_owners(action_items, transcript)


def render_meeting_markdown_export(
    *,
    summary: str,
    decisions: list[str],
    action_items: list[str],
    follow_ups: list[str],
    speaker_segments: list[dict[str, Any]],
    task_owners: list[dict[str, Any]],
) -> str:
    lines: list[str] = []
    lines.append("# Meeting Notes")
    lines.append("")
    lines.append("## Summary")
    lines.append(summary or "No summary captured.")
    lines.append("")
    lines.append("## Decisions")
    lines.extend(decisions and [f"- {item}" for item in decisions] or ["- None captured"])
    lines.append("")
    lines.append("## Action Items")
    lines.extend(action_items and [f"- [ ] {item}" for item in action_items] or ["- [ ] None captured"])
    lines.append("")
    lines.append("## Follow Ups")
    lines.extend(follow_ups and [f"- {item}" for item in follow_ups] or ["- None captured"])
    lines.append("")
    lines.append("## Task Owners")
    if task_owners:
        lines.extend(
            [
                f"- {row.get('task', 'Unknown task')} — {row.get('owner', 'Unassigned')} "
                f"({float(row.get('confidence', 0.0)):.2f})"
                for row in task_owners
            ]
        )
    else:
        lines.append("- None inferred")
    lines.append("")
    lines.append("## Speaker Segments")
    if speaker_segments:
        lines.extend(
            [
                f"- **{row.get('speaker', 'Speaker')}** ({int(row.get('utterance_count', 1))}): "
                f"{row.get('text', '')}"
                for row in speaker_segments
            ]
        )
    else:
        lines.append("- None inferred")
    return "\n".join(lines).strip()


def render_meeting_notion_export(
    *,
    summary: str,
    decisions: list[str],
    action_items: list[str],
    follow_ups: list[str],
    speaker_segments: list[dict[str, Any]],
    task_owners: list[dict[str, Any]],
) -> str:
    lines: list[str] = []
    lines.append("# Meeting Summary")
    lines.append(summary or "No summary captured.")
    lines.append("")
    lines.append("## Decisions")
    lines.extend(decisions and [f"- {item}" for item in decisions] or ["- None captured"])
    lines.append("")
    lines.append("## Action Items")
    if task_owners:
        lines.extend([f"- [ ] {row.get('task', 'Unknown task')} (Owner: {row.get('owner', 'Unassigned')})" for row in task_owners])
    else:
        lines.extend(action_items and [f"- [ ] {item}" for item in action_items] or ["- [ ] None captured"])
    lines.append("")
    lines.append("## Follow Ups")
    lines.extend(follow_ups and [f"- {item}" for item in follow_ups] or ["- None captured"])
    lines.append("")
    lines.append("## Speakers")
    lines.extend(
        speaker_segments and [f"- {row.get('speaker', 'Speaker')}: {row.get('text', '')}" for row in speaker_segments] or ["- Speaker segments unavailable"]
    )
    return "\n".join(lines).strip()


def build_meeting_summary(transcript: str, tone: str) -> dict[str, Any]:
    sentences = split_sentences(transcript)
    if not sentences:
        return {
            "summary": "",
            "decisions": [],
            "action_items": [],
            "follow_ups": [],
            "speaker_segments": [],
            "task_owners": [],
            "markdown_export": "",
            "notion_export": "",
        }

    summary_base = " ".join(sentences[:2])
    summary = apply_tone(summary_base, tone)

    decision_keywords = ("decide", "decision", "approved", "agree", "agreed", "resolved")
    action_keywords = ("will", "need to", "todo", "action", "follow up", "by ", "next step")
    followup_keywords = ("follow up", "next", "later", "tomorrow", "by ")

    decisions = [s for s in sentences if any(keyword in s.lower() for keyword in decision_keywords)]
    action_items = [s for s in sentences if any(keyword in s.lower() for keyword in action_keywords)]
    follow_ups = [s for s in sentences if any(keyword in s.lower() for keyword in followup_keywords)]

    if not decisions and len(sentences) >= 2:
        decisions = [sentences[1]]
    if not action_items and sentences:
        action_items = [sentences[-1]]
    if not follow_ups and action_items:
        follow_ups = action_items[:1]

    speaker_segments = infer_speaker_segments(transcript)
    task_owners = infer_task_owners(action_items, transcript)
    markdown_export = render_meeting_markdown_export(
        summary=summary,
        decisions=decisions[:5],
        action_items=action_items[:6],
        follow_ups=follow_ups[:4],
        speaker_segments=speaker_segments,
        task_owners=task_owners,
    )
    notion_export = render_meeting_notion_export(
        summary=summary,
        decisions=decisions[:5],
        action_items=action_items[:6],
        follow_ups=follow_ups[:4],
        speaker_segments=speaker_segments,
        task_owners=task_owners,
    )

    return {
        "summary": summary,
        "decisions": decisions[:5],
        "action_items": action_items[:6],
        "follow_ups": follow_ups[:4],
        "speaker_segments": speaker_segments,
        "task_owners": task_owners,
        "markdown_export": markdown_export,
        "notion_export": notion_export,
    }


@dataclass
class PrivateAPIPolicy:
    version: str
    require_consent: bool
    require_raw_confirmation: bool


@dataclass
class ResolvedProviderInput:
    provider_mode: str
    effective_text: str
    redacted: bool


class ProviderRouter:
    def __init__(
        self,
        *,
        whisper_engine: WhisperEngine,
        openai_audio_client: OpenAIAudioClient,
        polish_engine: PolishEngine,
        translate_engine: TranslateEngine,
        private_api_client: PrivateAPIClient,
        consent_store: ConsentStore,
        prompt_framing_engine: PromptFramingEngine,
    ) -> None:
        self._whisper_engine = whisper_engine
        self._openai_audio_client = openai_audio_client
        self._polish_engine = polish_engine
        self._translate_engine = translate_engine
        self._private_api_client = private_api_client
        self._consent_store = consent_store
        self._prompt_framing_engine = prompt_framing_engine

    @staticmethod
    def _bool_from_env(name: str) -> bool:
        value = os.environ.get(name, "").strip().lower()
        return value in {"1", "true", "yes", "on"}

    def private_api_policy(self) -> PrivateAPIPolicy:
        return PrivateAPIPolicy(
            version=os.environ.get("VOXFLOW_PRIVACY_POLICY_VERSION", "").strip(),
            require_consent=self._bool_from_env("VOXFLOW_PRIVACY_REQUIRE_CONSENT"),
            require_raw_confirmation=self._bool_from_env("VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED"),
        )

    def ensure_private_api_policy(self) -> PrivateAPIPolicy:
        required_flags = [
            "VOXFLOW_PRIVACY_POLICY_VERSION",
            "VOXFLOW_PRIVACY_REQUIRE_CONSENT",
            "VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED",
        ]
        missing = [name for name in required_flags if not os.environ.get(name, "").strip()]
        if missing:
            raise HTTPException(
                status_code=503,
                detail=f"Private API policy flags missing: {', '.join(missing)}",
            )

        policy = self.private_api_policy()
        if not policy.require_consent:
            raise HTTPException(status_code=503, detail="Private API policy requires consent enforcement")
        if not policy.require_raw_confirmation:
            raise HTTPException(status_code=503, detail="Private API policy requires explicit raw-send confirmation")
        return policy

    def current_stt_backend(self) -> str:
        return normalize_stt_backend(os.environ.get("VOXFLOW_STT_BACKEND", "whisper"))

    def active_stt_model_loaded(self) -> bool:
        backend = self.current_stt_backend()
        if backend == "whisper":
            return self._whisper_engine.model_loaded
        if backend == "openai":
            return self._openai_audio_client.configured
        return self._whisper_engine.model_loaded

    def active_stt_model_id(self) -> str:
        backend = self.current_stt_backend()
        if backend == "whisper":
            return self._whisper_engine.active_model_id
        if backend == "openai":
            return self._openai_audio_client.stt_model
        return self._whisper_engine.active_model_id

    def stt_fallback_active(self) -> bool:
        return False

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> tuple[str, float]:
        backend = self.current_stt_backend()
        if backend == "whisper":
            return self._whisper_engine.transcribe(pcm, sample_rate, language_hint)
        if backend == "openai":
            return self._openai_audio_client.transcribe(pcm, sample_rate, language_hint)
        return self._whisper_engine.transcribe(pcm, sample_rate, language_hint)

    def resolve_effective_text(
        self,
        *,
        provider_mode: str,
        operation: str,
        session_id: str,
        submitted_text: str,
        consent_token: str | None,
        allow_raw: bool,
    ) -> ResolvedProviderInput:
        normalized_mode = normalize_provider_mode(provider_mode)
        if normalized_mode == "local_only":
            return ResolvedProviderInput(provider_mode=normalized_mode, effective_text=submitted_text, redacted=False)

        if normalized_mode != "private_api":
            raise HTTPException(status_code=400, detail=f"Unsupported provider mode: {provider_mode}")

        self.ensure_private_api_policy()
        if not self._private_api_client.configured:
            raise HTTPException(status_code=503, detail="Private API mode selected but backend is not configured")
        if not consent_token:
            raise HTTPException(status_code=400, detail="consent_token is required for private API mode")

        record = self._consent_store.resolve(token=consent_token, session_id=session_id, operation=operation)
        if not record:
            raise HTTPException(status_code=400, detail="Invalid or expired privacy consent token")

        selected = record.original_text if allow_raw else record.redacted_text
        return ResolvedProviderInput(provider_mode=normalized_mode, effective_text=selected, redacted=not allow_raw)

    def privacy_preview(self, payload: PrivacyPreviewRequest) -> PrivacyPreviewResponse:
        operation = payload.operation.strip().lower()
        if operation not in {"cleanup", "translate", "meeting"}:
            raise HTTPException(status_code=400, detail=f"Unsupported privacy preview operation: {payload.operation}")

        self.ensure_private_api_policy()
        if not self._private_api_client.configured:
            raise HTTPException(status_code=503, detail="Private API mode selected but backend is not configured")

        original = normalize_whitespace(payload.input_text)
        if not original:
            raise HTTPException(status_code=400, detail="input_text is empty")

        redacted = original if is_placeholder_text(original) else redact_sensitive_text(original)
        # Cleanup needs 2 uses (light + polish); translate/meeting need 1
        uses = 2 if operation == "cleanup" else 1
        record = self._consent_store.create(
            session_id=payload.session_id,
            operation=operation,
            original_text=original,
            redacted_text=redacted,
            max_uses=uses,
        )
        return PrivacyPreviewResponse(
            operation=operation,
            token=record.token,
            original_text=record.original_text,
            redacted_text=record.redacted_text,
        )

    def cleanup(self, payload: CleanupRequest) -> tuple[str, bool, ResolvedProviderInput]:
        mode = payload.mode.lower()
        tone = payload.tone_style.lower()
        resolved = self.resolve_effective_text(
            provider_mode=payload.provider_mode,
            operation="cleanup",
            session_id=payload.session_id,
            submitted_text=payload.input_text,
            consent_token=payload.consent_token,
            allow_raw=payload.allow_raw,
        )

        if resolved.provider_mode == "private_api":
            output, triggered = self._private_api_client.cleanup(mode, tone, resolved.effective_text)
            return output, triggered, resolved

        if mode == "raw":
            return normalize_whitespace(resolved.effective_text), False, resolved
        if mode == "light":
            return apply_tone(light_cleanup(resolved.effective_text), tone), False, resolved
        if mode == "polish":
            output, triggered = self._polish_engine.polish(resolved.effective_text, tone)
            return output, triggered, resolved
        raise HTTPException(status_code=400, detail=f"Unsupported cleanup mode: {payload.mode}")

    def translate(self, payload: TranslateRequest) -> tuple[str, str, ResolvedProviderInput]:
        if payload.source_language.lower() != "en" or payload.target_language.lower() != "de":
            raise HTTPException(status_code=400, detail="v1 supports EN->DE only")

        resolved = self.resolve_effective_text(
            provider_mode=payload.provider_mode,
            operation="translate",
            session_id=payload.session_id,
            submitted_text=payload.source_text,
            consent_token=payload.consent_token,
            allow_raw=payload.allow_raw,
        )

        if resolved.provider_mode == "private_api":
            translated = self._private_api_client.translate_en_de(resolved.effective_text)
        else:
            translated = self._translate_engine.translate(resolved.effective_text)
        return resolved.effective_text, translated, resolved

    def meeting_summary(self, payload: MeetingRequest) -> tuple[dict[str, Any], ResolvedProviderInput]:
        resolved = self.resolve_effective_text(
            provider_mode=payload.provider_mode,
            operation="meeting",
            session_id=payload.session_id,
            submitted_text=payload.transcript,
            consent_token=payload.consent_token,
            allow_raw=payload.allow_raw,
        )

        if resolved.provider_mode == "private_api":
            structured = self._private_api_client.meeting_summary(resolved.effective_text, payload.tone_style.lower())
        else:
            structured = build_meeting_summary(resolved.effective_text, payload.tone_style.lower())
        return structured, resolved

    def frame_prompt(self, session_id: str, text: str, consent_token: str | None) -> tuple[str, str]:
        intent = self._prompt_framing_engine.detect_intent(text)
        framed = self._prompt_framing_engine.frame(text, intent)
        return framed, intent


def initialize_runtime_state() -> None:
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

    try:
        import torch

        state.mps_available = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    except Exception as exc:
        logger.warning("MPS check at startup failed: %s", exc)
        state.mps_available = False

    state.stt_backend = current_stt_backend()
    # Eagerly load the STT model at startup so health polls don't trigger loading
    if state.stt_backend == "whisper":
        whisper_engine._load_pipeline()
    state.model_loaded = active_stt_model_loaded()


@asynccontextmanager
async def app_lifespan(_: FastAPI):
    initialize_runtime_state()
    yield


app = FastAPI(title="VoxFlow Local Backend", version="0.1.0", lifespan=app_lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1", "http://localhost"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)

_rate_limit_timestamps: dict[str, list[float]] = defaultdict(list)
_RATE_LIMIT_WINDOW = 60.0
_RATE_LIMIT_MAX_REQUESTS = 120
_LAST_CLEANUP_TIME = 0.0
_CLEANUP_INTERVAL = 300.0  # 5 minutes


@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):  # type: ignore[no-untyped-def]
    global _LAST_CLEANUP_TIME
    client = request.client.host if request.client else "unknown"
    now = time.time()

    # Periodic cleanup of stale clients (every 5 minutes)
    if now - _LAST_CLEANUP_TIME > _CLEANUP_INTERVAL:
        stale_cutoff = now - _RATE_LIMIT_WINDOW
        # Create a list of keys to remove to avoid modifying dict during iteration
        stale_clients = [
            ip for ip, timestamps in _rate_limit_timestamps.items()
            if not timestamps or timestamps[-1] < stale_cutoff
        ]
        for ip in stale_clients:
            _rate_limit_timestamps.pop(ip, None)
        _LAST_CLEANUP_TIME = now

    timestamps = _rate_limit_timestamps[client]
    # Filter only current client's timestamps
    valid_timestamps = [ts for ts in timestamps if now - ts < _RATE_LIMIT_WINDOW]
    _rate_limit_timestamps[client] = valid_timestamps

    if len(valid_timestamps) >= _RATE_LIMIT_MAX_REQUESTS:
        return JSONResponse(status_code=429, content={"detail": "Rate limited"})

    valid_timestamps.append(now)
    return await call_next(request)
state = RuntimeState()
whisper_engine = WhisperEngine()
polish_engine = PolishEngine()
translate_engine = TranslateEngine()
prompt_framing_engine = PromptFramingEngine()
consent_store = ConsentStore()
audit_logger = AuditLogger()
private_api_client = PrivateAPIClient()
openai_audio_client = OpenAIAudioClient()
provider_router = ProviderRouter(
    whisper_engine=whisper_engine,
    openai_audio_client=openai_audio_client,
    polish_engine=polish_engine,
    translate_engine=translate_engine,
    private_api_client=private_api_client,
    consent_store=consent_store,
    prompt_framing_engine=prompt_framing_engine,
)


def resolve_effective_text(
    *,
    provider_mode: str,
    operation: str,
    session_id: str,
    submitted_text: str,
    consent_token: str | None,
    allow_raw: bool,
) -> tuple[str, bool]:
    resolved = provider_router.resolve_effective_text(
        provider_mode=provider_mode,
        operation=operation,
        session_id=session_id,
        submitted_text=submitted_text,
        consent_token=consent_token,
        allow_raw=allow_raw,
    )
    return resolved.effective_text, resolved.redacted


def current_stt_backend() -> str:
    return provider_router.current_stt_backend()


def active_stt_model_loaded() -> bool:
    return provider_router.active_stt_model_loaded()


def active_stt_model_id() -> str:
    return provider_router.active_stt_model_id()


def stt_fallback_active() -> bool:
    return provider_router.stt_fallback_active()


def readiness_snapshot() -> ReadyResponse:
    state.stt_backend = current_stt_backend()
    state.model_loaded = active_stt_model_loaded()
    active_model = active_stt_model_id()
    privacy_policy = provider_router.private_api_policy()

    models_dir = os.environ.get("VOXFLOW_MODELS_DIR", "")
    models_dir_exists = bool(models_dir and os.path.isdir(models_dir))
    private_api_policy_ready = bool(
        privacy_policy.version and privacy_policy.require_consent and privacy_policy.require_raw_confirmation
    )

    issues: list[str] = []
    if state.service_status != "ok":
        issues.append("service status is not ok")
    if not state.model_loaded:
        issues.append("active STT model is not loaded")
    if models_dir and not models_dir_exists:
        issues.append(f"configured models directory does not exist: {models_dir}")
    if not models_dir:
        issues.append("VOXFLOW_MODELS_DIR is not configured")

    return ReadyResponse(
        service_status=state.service_status,
        ready_for_dictation=(state.service_status == "ok" and state.model_loaded),
        stt_backend=state.stt_backend,
        active_stt_model=active_model,
        active_stt_model_loaded=state.model_loaded,
        stt_fallback_active=stt_fallback_active(),
        offline_mode=state.offline_mode,
        python_executable=sys.executable,
        python_version=sys.version.split()[0],
        models_dir=models_dir,
        models_dir_exists=models_dir_exists,
        openai_audio_configured=openai_audio_client.configured,
        private_api_configured=private_api_client.configured,
        private_api_policy_version=privacy_policy.version or "unset",
        private_api_policy_ready=private_api_policy_ready,
        issues=issues,
    )


@app.get("/v1/health")
def health() -> dict[str, str]:
    state.stt_backend = current_stt_backend()
    state.model_loaded = active_stt_model_loaded()
    active_model = active_stt_model_id()
    privacy_policy = provider_router.private_api_policy()
    return {
        "service_status": state.service_status,
        "model_loaded": str(state.model_loaded).lower(),
        "mps_available": str(state.mps_available).lower(),
        "offline_mode": str(state.offline_mode).lower(),
        "stt_backend": state.stt_backend,
        "active_stt_model": active_model,
        "stt_fallback_active": str(stt_fallback_active()).lower(),
        "openai_audio_configured": str(openai_audio_client.configured).lower(),
        "private_api_configured": str(private_api_client.configured).lower(),
        "private_api_policy_version": privacy_policy.version or "unset",
        "private_api_policy_ready": str(
            bool(privacy_policy.version and privacy_policy.require_consent and privacy_policy.require_raw_confirmation)
        ).lower(),
    }


@app.get("/v1/ready", response_model=ReadyResponse)
def ready() -> ReadyResponse:
    return readiness_snapshot()


@app.post("/v1/transcribe", response_model=TranscribeResponse)
def transcribe(payload: TranscribeRequest) -> TranscribeResponse:
    started = time.perf_counter()

    if len(payload.audio_pcm16le) > MAX_AUDIO_BASE64_CHARS:
        raise HTTPException(status_code=413, detail="Audio payload too large")

    try:
        audio_bytes = base64.b64decode(payload.audio_pcm16le, validate=True)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid audio payload: {exc}") from exc

    if len(audio_bytes) > MAX_AUDIO_PAYLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Decoded audio exceeds size limit")

    if not audio_bytes:
        logger.warning("Transcribe called with empty audio buffer")
        return TranscribeResponse(
            text="[transcription unavailable: no audio captured]",
            is_final=True,
            latency_ms=0,
            confidence_estimate=0.0,
            processing_time_ms=0,
        )

    if len(audio_bytes) % 2 != 0:
        raise HTTPException(status_code=400, detail="PCM16 audio must have even byte length")

    text, confidence = provider_router.transcribe(audio_bytes, payload.sample_rate, payload.language_hint)
    latency_ms = int((time.perf_counter() - started) * 1000)

    # Two-tier hallucination filter (Whisper-only — OpenAI API does its own filtering):
    # - Known YouTube/podcast phrases: filtered at ANY duration (never real dictation)
    # - Single words, repeated words: filtered only on short audio (< 3s)
    stt_backend = current_stt_backend()
    if stt_backend != "openai":
        audio_duration_s = len(audio_bytes) / max(payload.sample_rate * 2, 1)
        is_short = audio_duration_s < 3.0
        if is_whisper_hallucination(text, short_audio=is_short):
            logger.info("Filtered Whisper hallucination (%.1fs, short=%s, backend=%s)", audio_duration_s, is_short, stt_backend)
            text = ""
            confidence = 0.0

    return TranscribeResponse(
        text=text,
        is_final=True,
        latency_ms=latency_ms,
        confidence_estimate=confidence,
        processing_time_ms=latency_ms,
    )


@app.post("/v1/tts", response_model=TTSResponse)
def tts(payload: TTSRequest) -> TTSResponse:
    text = normalize_whitespace(payload.text)
    if not text:
        raise HTTPException(status_code=400, detail="text is empty")

    fmt = payload.format.lower()
    if fmt not in {"mp3", "wav", "opus"}:
        raise HTTPException(status_code=400, detail="Unsupported format. Use mp3, wav, or opus.")

    audio_bytes = openai_audio_client.synthesize(text=text, voice=payload.voice, fmt=fmt)
    return TTSResponse(audio_base64=base64.b64encode(audio_bytes).decode("utf-8"), format=fmt)


@app.post("/v1/privacy/preview", response_model=PrivacyPreviewResponse)
def privacy_preview(payload: PrivacyPreviewRequest) -> PrivacyPreviewResponse:
    return provider_router.privacy_preview(payload)


@app.post("/v1/cleanup", response_model=CleanupResponse)
def cleanup(payload: CleanupRequest) -> CleanupResponse:
    output, triggered, resolved = provider_router.cleanup(payload)
    provider_mode = resolved.provider_mode
    effective_text = resolved.effective_text

    audit_logger.log(
        operation="cleanup",
        provider_mode=provider_mode,
        session_id=payload.session_id,
        payload_length=len(effective_text),
        redacted=resolved.redacted,
    )
    return CleanupResponse(output_text=output, mode_applied=payload.mode.lower(), guardrail_triggered=triggered)


@app.post("/v1/translate", response_model=TranslateResponse)
def translate(payload: TranslateRequest) -> TranslateResponse:
    effective_text, translated, resolved = provider_router.translate(payload)
    provider_mode = resolved.provider_mode

    audit_logger.log(
        operation="translate",
        provider_mode=provider_mode,
        session_id=payload.session_id,
        payload_length=len(effective_text),
        redacted=resolved.redacted,
    )
    return TranslateResponse(source_text=effective_text, translated_text=translated)


@app.post("/v1/meeting_summarize", response_model=MeetingSummaryResponse)
def meeting_summarize(payload: MeetingRequest) -> MeetingSummaryResponse:
    structured, resolved = provider_router.meeting_summary(payload)
    provider_mode = resolved.provider_mode
    effective_text = resolved.effective_text

    audit_logger.log(
        operation="meeting",
        provider_mode=provider_mode,
        session_id=payload.session_id,
        payload_length=len(effective_text),
        redacted=resolved.redacted,
    )
    return MeetingSummaryResponse(
        transcript=normalize_whitespace(effective_text),
        summary=normalize_whitespace(str(structured.get("summary", ""))),
        decisions=coerce_string_list(structured.get("decisions"), 5),
        action_items=coerce_string_list(structured.get("action_items"), 6),
        follow_ups=coerce_string_list(structured.get("follow_ups"), 4),
        speaker_segments=coerce_speaker_segments(structured.get("speaker_segments"), effective_text),
        task_owners=coerce_task_owners(
            structured.get("task_owners"),
            coerce_string_list(structured.get("action_items"), 6),
            effective_text,
        ),
        markdown_export=str(structured.get("markdown_export", "")).strip(),
        notion_export=str(structured.get("notion_export", "")).strip(),
    )


@app.post("/v1/prompt/frame", response_model=PromptFrameResponse)
def prompt_frame(payload: PromptFrameRequest) -> PromptFrameResponse:
    framed, intent = provider_router.frame_prompt(
        session_id=payload.session_id,
        text=payload.text,
        consent_token=payload.consent_token,
    )
    audit_logger.log(
        operation="prompt_frame",
        provider_mode="local_only",
        session_id=payload.session_id,
        payload_length=len(payload.text),
        redacted=False,
    )
    return PromptFrameResponse(framed_prompt=framed, detected_intent=intent)


@app.websocket("/v1/events")
async def events(websocket: WebSocket) -> None:
    await websocket.accept()
    await websocket.send_json({"event": "connected", "message": "VoxFlow event stream ready"})
    try:
        while True:
            # Keep socket open; client may send pings.
            _msg: Any = await websocket.receive_text()
            await websocket.send_json({"event": "ack"})
    except Exception as exc:
        logger.debug("WebSocket closed: %s", exc)
        await websocket.close()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("server:app", host="127.0.0.1", port=8765, reload=False)
