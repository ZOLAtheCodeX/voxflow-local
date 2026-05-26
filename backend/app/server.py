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
from routing import (
    PrivateAPIClient,
    PrivateAPIPolicy,
    ProviderRouter,
    ResolvedProviderInput,
    coerce_string_list,
    extract_json_object,
    is_placeholder_text,
    normalize_provider_mode,
    normalize_stt_backend,
)
from schemas import (
    CleanupRequest,
    CleanupResponse,
    MeetingRequest,
    MeetingSpeakerSegment,
    MeetingSummaryResponse,
    MeetingTaskOwner,
    PrivacyPreviewRequest,
    PrivacyPreviewResponse,
    PromptFrameRequest,
    PromptFrameResponse,
    ReadyResponse,
    TranscribeRequest,
    TranscribeResponse,
    TranslateRequest,
    TranslateResponse,
    TTSRequest,
    TTSResponse,
)

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
