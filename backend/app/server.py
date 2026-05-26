from __future__ import annotations

import time
import sys
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

# 1. Re-export context variables and helper logic
from context import (
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
    private_api_client,
    prompt_framing_engine,
    provider_router,
    readiness_snapshot,
    resolve_effective_text,
    run_blocking,
    smart_action_engine,
    state,
    stt_fallback_active,
    translate_engine,
    whisper_engine,
)

# 2. Re-export engines and engine types
from engines import (
    OpenAIAudioClient,
    PolishEngine,
    PromptFramingEngine,
    STTExecutionResult,
    TranslateEngine,
    WhisperEngine,
)

# 3. Re-export NLP functions
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

# 4. Re-export privacy and routing components
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
from smart_actions import SmartActionEngine

# 4.5. Re-export schemas
from schemas import (
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

_WEBSOCKET_IDLE_TIMEOUT_S = 60.0


# 5. Import APIRouter and endpoint functions
from api.endpoints import (
    router as api_router,
    cleanup,
    events,
    health,
    meeting_summarize,
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

_LAST_CLEANUP_TIME = 0.0

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):  # type: ignore[no-untyped-def]
    global _LAST_CLEANUP_TIME
    client = request.client.host if request.client else "unknown"
    now = time.time()

    with _RATE_LIMIT_LOCK:
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

app.include_router(api_router)

if __name__ == "__main__":
    import uvicorn

    uvicorn.run("server:app", host="127.0.0.1", port=8765, reload=False)
