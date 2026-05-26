"""Pydantic request and response schemas for the VoxFlow API.

Co-located here (rather than in api/) so the routing layer can depend on
schemas without depending on api/ — keeping the dependency graph
acyclic (api -> routing -> schemas; api also imports schemas directly).
"""

from __future__ import annotations

from pydantic import BaseModel, Field


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


class SmartActionRequest(BaseModel):
    action_id: str = Field(min_length=1, max_length=32)
    transcript: str = Field(min_length=1, max_length=50_000)


class SmartActionResponse(BaseModel):
    action_id: str
    output: str
    guardrail_triggered: bool
    error: str | None = None


class OllamaModelInfo(BaseModel):
    name: str
    size: int = 0
    digest: str = ""
    modified_at: str = ""


class OllamaModelsResponse(BaseModel):
    available: bool
    models: list[OllamaModelInfo] = Field(default_factory=list)
    current_model: str = ""
    recommended_model: str | None = None
    host_memory_gb: float = 0.0


class OllamaPullRequest(BaseModel):
    model: str = Field(min_length=1, max_length=128)


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
    ollama_available: bool = False
    issues: list[str] = Field(default_factory=list)
