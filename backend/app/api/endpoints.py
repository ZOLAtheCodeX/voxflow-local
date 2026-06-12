from __future__ import annotations

import base64
import time
import asyncio
import os
import logging
from typing import Any

from fastapi import APIRouter, HTTPException, WebSocket
from fastapi.responses import StreamingResponse

# Import singletons, status variables and helper logic from context
from context import (
    provider_registry,
    MAX_AUDIO_BASE64_CHARS,
    MAX_AUDIO_PAYLOAD_BYTES,
    state,
    audit_logger,
    notion_client,
    private_api_client,
    openai_audio_client,
    provider_router,
    smart_action_engine,
    current_stt_backend,
    active_stt_model_loaded,
    active_stt_model_id,
    stt_fallback_active,
    readiness_snapshot,
    get_ml_semaphore,
    run_blocking,
)

from integrations.notion_rest import NotionError

from engines.llm_backend import (
    detect_host_memory_bytes,
    list_ollama_models,
    probe_ollama_available,
    pull_ollama_model_stream,
    recommend_ollama_model,
)

from nlp import (
    is_whisper_hallucination,
    normalize_whitespace,
    coerce_speaker_segments,
    coerce_task_owners,
)

from privacy import redact_sensitive_text

from routing import (
    coerce_string_list,
)

from schemas import (
    ProviderTestRequest,
    ProviderTestResponse,
    CleanupRequest,
    CleanupResponse,
    MeetingRequest,
    MeetingSummaryResponse,
    NotionAppendRequest,
    NotionAppendResponse,
    NotionSearchRequest,
    NotionSearchResponse,
    NotionSearchResult,
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

logger = logging.getLogger("voxflow")

router = APIRouter()


@router.get("/v1/health")
def health() -> dict[str, str]:
    state.stt_backend = current_stt_backend()
    state.model_loaded = active_stt_model_loaded()
    active_model = active_stt_model_id()
    privacy_policy = provider_router.private_api_policy()
    return {
        "service_status": state.service_status,
        # R4.7: echoes VOXFLOW_INSTANCE_STAMP from the launch environment so
        # the app can detect a stale/foreign backend squatting on the port
        # (a 2-week-old backend served the app undetected on 2026-06-12).
        "instance_stamp": os.environ.get("VOXFLOW_INSTANCE_STAMP", ""),
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


@router.get("/v1/ready", response_model=ReadyResponse)
def ready() -> ReadyResponse:
    return readiness_snapshot()


@router.post("/v1/providers/test", response_model=ProviderTestResponse)
def providers_test(payload: ProviderTestRequest) -> ProviderTestResponse:
    """Probe one configured provider for the Settings test-connection button (R3.6)."""
    try:
        spec = provider_registry.spec(payload.provider_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown provider id: {payload.provider_id}")

    backend = provider_registry.backend(spec.id)
    if spec.kind == "ollama":
        from engines.llm_backend import list_ollama_models, probe_ollama_available

        reachable = probe_ollama_available(force=True)
        if not reachable:
            return ProviderTestResponse(provider_id=spec.id, reachable=False, detail="Ollama server unreachable")
        model = spec.model or getattr(backend, "model", "")
        try:
            installed = {m.get("name", "") for m in list_ollama_models(timeout=2.0)}
            if model and model not in installed:
                return ProviderTestResponse(
                    provider_id=spec.id, reachable=True,
                    detail=f"Server reachable but model '{model}' is not pulled — run: ollama pull {model}",
                )
        except Exception:
            pass
        return ProviderTestResponse(provider_id=spec.id, reachable=True, detail=f"Reachable; model '{model}' available")

    if spec.kind in ("openai_compat", "openai"):
        reachable = bool(getattr(backend, "is_available", lambda: False)())
        detail = "Reachable" if reachable else "Server unreachable or rejected the request"
        return ProviderTestResponse(provider_id=spec.id, reachable=reachable, detail=detail)

    if spec.kind == "anthropic":
        if not spec.api_key:
            return ProviderTestResponse(
                provider_id=spec.id, reachable=False,
                detail="No API key configured (set it in Settings; stored in the Keychain)",
            )
        return ProviderTestResponse(provider_id=spec.id, reachable=True, detail="API key on file (verified at first request)")

    return ProviderTestResponse(provider_id=spec.id, reachable=False, detail=f"Unknown kind {spec.kind}")


@router.post("/v1/transcribe", response_model=TranscribeResponse)
async def transcribe(payload: TranscribeRequest) -> TranscribeResponse:
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

    sem = get_ml_semaphore()
    if sem.locked():
        raise HTTPException(status_code=503, detail="Server busy: maximum concurrent model evaluations reached")

    async with sem:
        result = await run_blocking(provider_router.transcribe, audio_bytes, payload.sample_rate, payload.language_hint)

    stage_timings_ms.update(result.stage_timings_ms)
    latency_ms = int((time.perf_counter() - started) * 1000)

    # Two-tier hallucination filter — applied on EVERY STT backend. The OpenAI
    # exemption was audit ghost cause #7: cloud Whisper hallucinates on noise
    # just like local Whisper, and the old hardcoded 0.88 confidence defeated
    # the client-side gate.
    stt_backend = current_stt_backend()
    text = result.text
    confidence = result.confidence
    audio_duration_s = len(audio_bytes) / max(payload.sample_rate * 2, 1)
    is_short = audio_duration_s < 3.0
    if is_whisper_hallucination(text, short_audio=is_short):
        logger.info(
            "Filtered Whisper hallucination (%.1fs, short=%s, backend=%s)",
            audio_duration_s, is_short, stt_backend,
        )
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


@router.post("/v1/tts", response_model=TTSResponse)
def tts(payload: TTSRequest) -> TTSResponse:
    text = normalize_whitespace(payload.text)
    if not text:
        raise HTTPException(status_code=400, detail="text is empty")

    fmt = payload.format.lower()
    if fmt not in {"mp3", "wav", "opus"}:
        raise HTTPException(status_code=400, detail="Unsupported format. Use mp3, wav, or opus.")

    audio_bytes = openai_audio_client.synthesize(text=text, voice=payload.voice, fmt=fmt)
    return TTSResponse(audio_base64=base64.b64encode(audio_bytes).decode("utf-8"), format=fmt)


@router.post("/v1/privacy/preview", response_model=PrivacyPreviewResponse)
def privacy_preview(payload: PrivacyPreviewRequest) -> PrivacyPreviewResponse:
    return provider_router.privacy_preview(payload)


@router.post("/v1/cleanup", response_model=CleanupResponse)
async def cleanup(payload: CleanupRequest) -> CleanupResponse:
    sem = get_ml_semaphore()
    if sem.locked():
        raise HTTPException(status_code=503, detail="Server busy: maximum concurrent model evaluations reached")

    async with sem:
        result, resolved = await run_blocking(provider_router.cleanup, payload)

    provider_mode = resolved.provider_mode
    effective_text = resolved.effective_text

    audit_logger.log(
        operation="cleanup",
        provider_mode=provider_mode,
        session_id=payload.session_id,
        payload_length=len(effective_text),
        redacted=resolved.redacted,
    )
    return CleanupResponse(
        output_text=result.text,
        mode_applied=payload.mode.lower(),
        guardrail_triggered=result.guardrail_triggered,
        degraded_reason=result.degraded_reason,
        served_by=result.served_by,
        model_id=result.model_id,
        fallback_depth=result.fallback_depth,
    )


@router.post("/v1/translate", response_model=TranslateResponse)
async def translate(payload: TranslateRequest) -> TranslateResponse:
    sem = get_ml_semaphore()
    if sem.locked():
        raise HTTPException(status_code=503, detail="Server busy: maximum concurrent model evaluations reached")

    async with sem:
        effective_text, translated, resolved = await run_blocking(provider_router.translate, payload)

    provider_mode = resolved.provider_mode

    audit_logger.log(
        operation="translate",
        provider_mode=provider_mode,
        session_id=payload.session_id,
        payload_length=len(effective_text),
        redacted=resolved.redacted,
    )
    return TranslateResponse(source_text=effective_text, translated_text=translated)


@router.post("/v1/meeting_summarize", response_model=MeetingSummaryResponse)
async def meeting_summarize(payload: MeetingRequest) -> MeetingSummaryResponse:
    sem = get_ml_semaphore()
    if sem.locked():
        raise HTTPException(status_code=503, detail="Server busy: maximum concurrent model evaluations reached")

    async with sem:
        structured, resolved = await run_blocking(provider_router.meeting_summary, payload)

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


@router.post("/v1/smart_action", response_model=SmartActionResponse)
async def smart_action(payload: SmartActionRequest) -> SmartActionResponse:
    """Cockpit Layer 0 — apply a smart action to a captured transcript."""
    sem = get_ml_semaphore()
    if sem.locked():
        raise HTTPException(status_code=503, detail="Server busy: maximum concurrent model evaluations reached")

    safe_transcript = redact_sensitive_text(payload.transcript)

    async with sem:
        result = await run_blocking(
            smart_action_engine.apply,
            action_id=payload.action_id,
            transcript=safe_transcript,
        )

    return SmartActionResponse(
        action_id=result.action_id,
        output=result.output,
        guardrail_triggered=result.guardrail_triggered,
        error=result.error,
        served_by=result.served_by,
        model_id=result.model_id,
        degraded_reason=result.degraded_reason,
    )


@router.post("/v1/prompt/frame", response_model=PromptFrameResponse)
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


@router.get("/v1/ollama/models", response_model=OllamaModelsResponse)
def ollama_models() -> OllamaModelsResponse:
    """List installed Ollama models + the recommended model for this host."""
    available = probe_ollama_available()
    raw_models = list_ollama_models() if available else []
    models: list[OllamaModelInfo] = []
    for entry in raw_models:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name", "")).strip()
        if not name:
            continue
        models.append(
            OllamaModelInfo(
                name=name,
                size=int(entry.get("size", 0) or 0),
                digest=str(entry.get("digest", ""))[:64],
                modified_at=str(entry.get("modified_at", "")),
            )
        )

    host_memory_bytes = detect_host_memory_bytes()
    host_memory_gb = round(host_memory_bytes / (1024 ** 3), 2) if host_memory_bytes else 0.0
    recommended = (
        os.environ.get("VOXFLOW_OLLAMA_MODEL", "").strip()
        or recommend_ollama_model(host_memory_bytes)
    )
    current_model = os.environ.get("VOXFLOW_OLLAMA_MODEL", "").strip() or (recommended or "")

    return OllamaModelsResponse(
        available=available,
        models=models,
        current_model=current_model,
        recommended_model=recommended,
        host_memory_gb=host_memory_gb,
    )


@router.post("/v1/ollama/pull")
def ollama_pull(payload: OllamaPullRequest) -> StreamingResponse:
    """Stream NDJSON progress lines from Ollama's /api/pull endpoint to the client."""
    if not probe_ollama_available(force=True):
        raise HTTPException(status_code=503, detail="Ollama is not reachable at the configured URL")
    return StreamingResponse(
        pull_ollama_model_stream(payload.model),
        media_type="application/x-ndjson",
    )


@router.post("/v1/notion/search", response_model=NotionSearchResponse)
async def notion_search(payload: NotionSearchRequest) -> NotionSearchResponse:
    try:
        results = await run_blocking(
            notion_client.search, token=payload.notion_token, query=payload.query
        )
    except NotionError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return NotionSearchResponse(results=[NotionSearchResult(**r) for r in results])


@router.post("/v1/notion/append", response_model=NotionAppendResponse)
async def notion_append(payload: NotionAppendRequest) -> NotionAppendResponse:
    try:
        count = await run_blocking(
            notion_client.append,
            token=payload.notion_token, page_id=payload.page_id, text=payload.text,
        )
    except NotionError as exc:
        raise HTTPException(status_code=502, detail=str(exc))
    return NotionAppendResponse(appended_blocks=count)


@router.websocket("/v1/events")
async def events(websocket: WebSocket) -> None:
    """Event stream with idle timeout (Phase 5.4)."""
    import server

    await websocket.accept()
    await websocket.send_json({"event": "connected", "message": "VoxFlow event stream ready"})
    try:
        while True:
            try:
                _msg: Any = await asyncio.wait_for(  # noqa: F841
                    websocket.receive_text(),
                    timeout=server._WEBSOCKET_IDLE_TIMEOUT_S,
                )
            except asyncio.TimeoutError:
                logger.info(
                    "WebSocket idle for %.0fs — closing cleanly",
                    server._WEBSOCKET_IDLE_TIMEOUT_S,
                )
                await websocket.close(code=1000, reason="idle timeout")
                return
            await websocket.send_json({"event": "ack"})
    except Exception as exc:
        logger.debug("WebSocket closed: %s", exc)
        await websocket.close()
