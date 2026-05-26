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

from engines import (
    OpenAIAudioClient,
    PolishEngine,
    PromptFramingEngine,
    STTExecutionResult,
    TranslateEngine,
    WhisperEngine,
    preferred_torch_device,
    resolve_model_ref,
)
from nlp import (
    _WHISPER_HALLUCINATION_ALWAYS,
    _WHISPER_HALLUCINATION_SHORT_ONLY,
    apply_tone,
    build_meeting_summary,
    coerce_speaker_segments,
    coerce_task_owners,
    infer_speaker_segments,
    infer_task_owners,
    is_whisper_hallucination,
    light_cleanup,
    normalize_whitespace,
    remove_fillers,
    remove_repeated_words,
    render_meeting_markdown_export,
    render_meeting_notion_export,
    replace_spoken_punctuation,
    split_and_recase,
    split_sentences,
)
from privacy import AuditLogger, ConsentRecord, ConsentStore, redact_sensitive_text

logger = logging.getLogger("voxflow")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)

MAX_AUDIO_PAYLOAD_BYTES = 10 * 1024 * 1024  # 10 MB decoded PCM limit
MAX_AUDIO_BASE64_CHARS = int(MAX_AUDIO_PAYLOAD_BYTES * 4 / 3) + 100




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
    stage_timings_ms: dict[str, int] = Field(default_factory=dict)
    model_loaded_before_request: bool | None = None
    model_loaded_after_request: bool | None = None
    cold_start: bool = False


class CleanupRequest(BaseModel):
    session_id: str
    mode: str
    input_text: str = Field(max_length=50_000)
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
    source_text: str = Field(max_length=50_000)
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
    transcript: str = Field(max_length=50_000)
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




def normalize_provider_mode(provider_mode: str) -> str:
    normalized = provider_mode.strip().lower()
    if normalized in {"privateapi", "private_api", "private-api"}:
        return "private_api"
    return "local_only"


def normalize_stt_backend(raw: str) -> str:
    normalized = raw.strip().lower()
    if normalized in {"whisper", "whisperkit", "openai"}:
        return normalized
    return "whisper"


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
        task_owners = coerce_task_owners(parsed.get("task_owners"), action_items, transcript, speaker_segments)

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
        if backend == "whisperkit":
            return True
        if backend == "openai":
            return self._openai_audio_client.configured
        return self._whisper_engine.model_loaded

    def active_stt_model_id(self) -> str:
        backend = self.current_stt_backend()
        if backend == "whisper":
            return self._whisper_engine.active_model_id
        if backend == "whisperkit":
            return "whisperkit (in-app)"
        if backend == "openai":
            return self._openai_audio_client.stt_model
        return self._whisper_engine.active_model_id

    def stt_fallback_active(self) -> bool:
        return False

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> STTExecutionResult:
        backend = self.current_stt_backend()
        if backend == "whisper":
            return self._whisper_engine.transcribe(pcm, sample_rate, language_hint)
        if backend == "whisperkit":
            return STTExecutionResult(
                text="[transcription unavailable: WhisperKit runs in the app process]",
                confidence=0.0,
                stage_timings_ms={},
                model_loaded_before_request=True,
                model_loaded_after_request=True,
                cold_start=False,
            )
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
        whisper_engine.warmup_inference()
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
    stage_timings_ms: dict[str, int] = {}

    if len(payload.audio_pcm16le) > MAX_AUDIO_BASE64_CHARS:
        raise HTTPException(status_code=413, detail="Audio payload too large")

    try:
        decode_started = time.perf_counter()
        audio_bytes = base64.b64decode(payload.audio_pcm16le, validate=True)
        stage_timings_ms["request_decode"] = int((time.perf_counter() - decode_started) * 1000)
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
            stage_timings_ms=stage_timings_ms,
        )

    if len(audio_bytes) % 2 != 0:
        raise HTTPException(status_code=400, detail="PCM16 audio must have even byte length")

    result = provider_router.transcribe(audio_bytes, payload.sample_rate, payload.language_hint)
    stage_timings_ms.update(result.stage_timings_ms)
    latency_ms = int((time.perf_counter() - started) * 1000)

    # Two-tier hallucination filter (Whisper-only — OpenAI API does its own filtering):
    # - Known YouTube/podcast phrases: filtered at ANY duration (never real dictation)
    # - Single words, repeated words: filtered only on short audio (< 3s)
    stt_backend = current_stt_backend()
    text = result.text
    confidence = result.confidence
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
        stage_timings_ms=stage_timings_ms,
        model_loaded_before_request=result.model_loaded_before_request,
        model_loaded_after_request=result.model_loaded_after_request,
        cold_start=result.cold_start,
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
    action_items = coerce_string_list(structured.get("action_items"), 6)
    speaker_segments = coerce_speaker_segments(structured.get("speaker_segments"), effective_text)
    return MeetingSummaryResponse(
        transcript=normalize_whitespace(effective_text),
        summary=normalize_whitespace(str(structured.get("summary", ""))),
        decisions=coerce_string_list(structured.get("decisions"), 5),
        action_items=action_items,
        follow_ups=coerce_string_list(structured.get("follow_ups"), 4),
        speaker_segments=speaker_segments,
        task_owners=coerce_task_owners(
            structured.get("task_owners"),
            action_items,
            effective_text,
            speaker_segments,
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
