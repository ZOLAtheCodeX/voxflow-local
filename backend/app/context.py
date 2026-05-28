from __future__ import annotations

import logging
import os
import sys
import asyncio
from collections import defaultdict
from dataclasses import dataclass
from threading import Lock

from engines import (
    OpenAIAudioClient,
    PolishEngine,
    PromptFramingEngine,
    TranslateEngine,
    WhisperEngine,
)
from engines.llm_backend import (
    probe_ollama_available,
)
from privacy import AuditLogger, ConsentStore
from routing import (
    PrivateAPIClient,
    ProviderRouter,
)
from schemas import (
    ReadyResponse,
)
from integrations.notion_rest import NotionRestClient
from smart_actions import SmartActionEngine

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

smart_action_engine = SmartActionEngine(polish_backend=polish_engine)
notion_client = NotionRestClient()


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
        ollama_available=probe_ollama_available(),
        issues=issues,
    )


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


# Concurrency Semaphores
_ml_semaphore: asyncio.Semaphore | None = None
_ml_semaphore_loop: asyncio.AbstractEventLoop | None = None


def get_ml_semaphore() -> asyncio.Semaphore:
    global _ml_semaphore, _ml_semaphore_loop
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if _ml_semaphore is None or (loop is not None and _ml_semaphore_loop is not loop):
        _ml_semaphore = asyncio.Semaphore(2)
        _ml_semaphore_loop = loop
    return _ml_semaphore


async def run_blocking(func, *args, **kwargs):
    from functools import partial
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, partial(func, *args, **kwargs))


# Rate limit globals
_rate_limit_timestamps: dict[str, list[float]] = defaultdict(list)
_RATE_LIMIT_WINDOW = 60.0
_RATE_LIMIT_MAX_REQUESTS = 120
_LAST_CLEANUP_TIME = 0.0
_CLEANUP_INTERVAL = 300.0  # 5 minutes
_RATE_LIMIT_LOCK = Lock()

_WEBSOCKET_IDLE_TIMEOUT_S = 60.0
