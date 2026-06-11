"""ProviderRouter — orchestration hub for all four workflows.

Owns the engine + private-API + consent-store wiring. Each public method
(cleanup / translate / meeting_summary / privacy_preview / frame_prompt /
transcribe) is invoked by a route handler with a Pydantic request payload.

ResolvedProviderInput captures the resolved input text plus whether the
private-API path is active and whether the redacted version was used.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException

from engines import (
    OpenAIAudioClient,
    PolishEngine,
    PromptFramingEngine,
    STTExecutionResult,
    TranslateEngine,
    WhisperEngine,
)
from nlp import (
    apply_tone,
    build_meeting_summary,
    light_cleanup,
    normalize_whitespace,
)
from privacy import ConsentStore, redact_sensitive_text
from schemas import (
    CleanupRequest,
    MeetingRequest,
    PrivacyPreviewRequest,
    PrivacyPreviewResponse,
    TranslateRequest,
)

from .private_api import PrivateAPIClient, PrivateAPIPolicy
from .utils import (
    is_placeholder_text,
    normalize_provider_mode,
    normalize_stt_backend,
)

logger = logging.getLogger("voxflow")


@dataclass
class ResolvedProviderInput:
    provider_mode: str
    effective_text: str
    redacted: bool


@dataclass
class CleanupResult:
    """Cleanup output plus provenance (R3.4)."""

    text: str
    guardrail_triggered: bool
    degraded_reason: str | None
    served_by: str
    model_id: str | None
    fallback_depth: int


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
        self._stt_fallback_used = False

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
        return self._stt_fallback_used

    def transcribe(self, pcm: bytes, sample_rate: int, language_hint: str) -> STTExecutionResult:
        backend = self.current_stt_backend()
        if backend == "whisper":
            result = self._whisper_engine.transcribe(pcm, sample_rate, language_hint)
            # R3.5: a dead local engine falls back to the configured cloud STT
            # instead of returning a placeholder. The flag feeds /v1/ready so
            # degradation is visible, never silent.
            if (
                result.text.startswith("[transcription unavailable")
                and self._openai_audio_client.configured
            ):
                logger.warning("Local Whisper unavailable — falling back to OpenAI STT")
                self._stt_fallback_used = True
                return self._openai_audio_client.transcribe(pcm, sample_rate, language_hint)
            self._stt_fallback_used = False
            return result
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

    def cleanup(self, payload: CleanupRequest) -> tuple[CleanupResult, ResolvedProviderInput]:
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
            return CleanupResult(
                text=output,
                guardrail_triggered=bool(triggered),
                degraded_reason="guardrail" if triggered else None,
                served_by="private_api",
                model_id=getattr(self._private_api_client, "model", None),
                fallback_depth=0,
            ), resolved

        if mode == "raw":
            return CleanupResult(
                normalize_whitespace(resolved.effective_text), False, None,
                served_by="rules", model_id=None, fallback_depth=0,
            ), resolved
        if mode == "light":
            return CleanupResult(
                apply_tone(light_cleanup(resolved.effective_text), tone), False, None,
                served_by="rules", model_id=None, fallback_depth=0,
            ), resolved
        if mode == "polish":
            outcome = self._polish_engine.run(resolved.effective_text, tone)
            return CleanupResult(
                outcome.text, outcome.guardrail_triggered, outcome.degraded_reason,
                served_by=outcome.served_by, model_id=outcome.model_id,
                fallback_depth=outcome.fallback_depth,
            ), resolved
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
