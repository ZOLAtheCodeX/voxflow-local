"""VoxFlow Local Backend — composition root.

This module is the FastAPI application entry point. It constructs the
``app`` object, registers CORS + rate-limit middleware, mounts the API
router from :mod:`api.endpoints`, and re-exports every singleton, helper,
and type that was historically imported as ``from server import X`` so
that the 360+ existing tests continue to work without modification.
"""

from __future__ import annotations

import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# ── Re-exports ────────────────────────────────────────────────────────
# Everything below is re-exported purely so that ``from server import X``
# keeps working across the test suite. New code should prefer importing
# directly from the originating module (context, engines, nlp, …).

from context import (  # noqa: F401
    MAX_AUDIO_BASE64_CHARS,
    MAX_AUDIO_PAYLOAD_BYTES,
    RuntimeState,
    _CLEANUP_INTERVAL,
    _RATE_LIMIT_LOCK,
    _RATE_LIMIT_MAX_REQUESTS,
    _RATE_LIMIT_WINDOW,
    _rate_limit_timestamps,
    active_stt_model_id,
    active_stt_model_loaded,
    audit_logger,
    consent_store,
    current_stt_backend,
    get_ml_semaphore,
    initialize_runtime_state,
    openai_audio_client,
    polish_engine,
    smart_action_polish_engine,
    private_api_client,
    prompt_framing_engine,
    provider_router,
    readiness_snapshot,
    resolve_effective_text,
    run_blocking,
    notion_client,
    smart_action_engine,
    state,
    stt_fallback_active,
    translate_engine,
    whisper_engine,
)

from integrations.notion_rest import NotionError  # noqa: F401

from engines import (  # noqa: F401
    OpenAIAudioClient,
    PolishEngine,
    PromptFramingEngine,
    STTExecutionResult,
    TranslateEngine,
    WhisperEngine,
)

from nlp import (  # noqa: F401
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

from privacy import (  # noqa: F401
    AuditLogger,
    ConsentRecord,
    ConsentStore,
    redact_sensitive_text,
)

from routing import (  # noqa: F401
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

from smart_actions import SmartActionEngine  # noqa: F401

from schemas import (  # noqa: F401
    NotionAppendRequest,
    NotionAppendResponse,
    NotionSearchRequest,
    NotionSearchResponse,
    NotionSearchResult,
    CleanupRequest,
    CleanupResponse,
    MeetingRequest,
    MeetingSpeakerSegment,
    MeetingSummaryResponse,
    MeetingTaskOwner,
    OllamaModelInfo,
    OllamaModelsResponse,
    OllamaPullRequest,
    PrivacyPreviewRequest,
    PrivacyPreviewResponse,
    PromptFrameRequest,
    PromptFrameResponse,
    ReadyResponse,
    SmartActionRequest,
    SmartActionResponse,
    TranscribeRequest,
    TranscribeResponse,
    TranslateRequest,
    TranslateResponse,
    TTSRequest,
    TTSResponse,
)

# WebSocket idle timeout — tests monkeypatch this via ``server._WEBSOCKET_IDLE_TIMEOUT_S``
_WEBSOCKET_IDLE_TIMEOUT_S = 60.0

from api.endpoints import (  # noqa: E402, F401
    router as api_router,
    cleanup,
    events,
    health,
    meeting_summarize,
    notion_append,
    notion_search,
    ollama_models,
    ollama_pull,
    privacy_preview,
    prompt_frame,
    ready,
    smart_action,
    transcribe,
    translate,
    tts,
)

# ── Application setup ────────────────────────────────────────────────


@asynccontextmanager
async def app_lifespan(_: FastAPI):
    initialize_runtime_state()
    yield


app = FastAPI(
    title="VoxFlow Local Backend",
    version="0.1.0",
    lifespan=app_lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1", "http://localhost"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)

# ── Rate-limit middleware ─────────────────────────────────────────────

_LAST_CLEANUP_TIME = 0.0


@app.middleware("http")
async def rate_limit_middleware(
    request: Request,
    call_next,
):  # type: ignore[no-untyped-def]
    global _LAST_CLEANUP_TIME
    client = request.client.host if request.client else "unknown"
    now = time.time()

    with _RATE_LIMIT_LOCK:
        # Periodic cleanup of stale clients (every 5 minutes)
        if now - _LAST_CLEANUP_TIME > _CLEANUP_INTERVAL:
            stale_cutoff = now - _RATE_LIMIT_WINDOW
            stale_clients = [
                ip
                for ip, timestamps in _rate_limit_timestamps.items()
                if not timestamps or timestamps[-1] < stale_cutoff
            ]
            for ip in stale_clients:
                _rate_limit_timestamps.pop(ip, None)
            _LAST_CLEANUP_TIME = now

        timestamps = _rate_limit_timestamps[client]
        valid_timestamps = [
            ts for ts in timestamps if now - ts < _RATE_LIMIT_WINDOW
        ]
        _rate_limit_timestamps[client] = valid_timestamps

        if len(valid_timestamps) >= _RATE_LIMIT_MAX_REQUESTS:
            return JSONResponse(
                status_code=429,
                content={"detail": "Rate limited"},
            )

        valid_timestamps.append(now)
    return await call_next(request)


app.include_router(api_router)

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("server:app", host="127.0.0.1", port=8765, reload=False)
