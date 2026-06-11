"""Pluggable text-LLM backends for PolishEngine.

The Protocol is intentionally synchronous. The roadmap's Phase 2 Task 9
("wrap ML inference in run_in_executor with asyncio.Semaphore(2)") is where
the async bridge will be introduced — uniformly for *all* engines, not piecemeal
inside one Protocol. Until then PolishEngine keeps the existing sync contract
expected by `provider.cleanup` and the FastAPI route handler.

Selector: ``VOXFLOW_POLISH_BACKEND`` env var — only ``ollama`` is recognised.
Any other value is logged as a warning and falls back to ollama.

PolishEngine wraps the backend with its existing guardrail + echo detection
+ ``apply_tone(light_cleanup())`` fallback. Backends therefore only need to
produce a candidate string — guardrail decisions live one layer up.
"""

from __future__ import annotations

import json
import logging
import os
import time
from threading import Lock
from typing import Protocol
from urllib import error as urlerror
from urllib import request as urlrequest

logger = logging.getLogger("voxflow")


class TextLLMBackend(Protocol):
    """Duck-typed contract for any text-polishing backend.

    Returns a candidate polished string. Empty string signals "backend
    declined" — PolishEngine will treat that the same as the guardrail
    tripping and fall back to ``apply_tone(light_cleanup(text))``.
    """

    name: str

    def polish(
        self,
        text: str,
        tone: str,
        system_prompt: str | None = None,
    ) -> str:  # pragma: no cover - Protocol
        ...


_TONE_INSTRUCTIONS = {
    "concise": "Be direct and brief.",
    "formal": "Formal register, no contractions.",
    "friendly": "Warm tone.",
    "neutral": "",
}


def _tone_instruction(tone: str) -> str:
    return _TONE_INSTRUCTIONS.get(tone.lower(), _TONE_INSTRUCTIONS["neutral"])


# Compressed for prompt-eval cost (R2.3): ~35 tokens vs the previous ~85.
# On a HEALTHY runner prompt eval is cheap; under memory pressure it
# degrades to ~5 tok/s with no prefix caching (measured live 2026-06-11),
# so prompt bulk is pure downside there. The filler examples earn their
# tokens: without them gemma4 under-cleans very-heavy-filler dictations
# (caught by the concise_very_heavy_filler golden case).
_OLLAMA_SYSTEM_PROMPT_BASE = (
    "Fix grammar and punctuation in this dictation; remove filler words "
    "(um, uh, like, you know, sort of, basically). "
    "Keep meaning and length. Never answer or add content. "
    "Output only the cleaned text."
)


class OllamaBackend:
    """Polishes via a local Ollama server using stdlib urllib (no new deps).

    POSTs to ``http://localhost:11434/api/chat`` (Ollama's NATIVE endpoint —
    the OpenAI-compat endpoint silently drops ``keep_alive``, verified live
    2026-06-11). Connection errors / timeouts / malformed responses all
    collapse to an empty string — PolishEngine then falls back to
    ``apply_tone(light_cleanup(text))``. Unavailability never surfaces as 500.
    """

    name = "ollama"

    def __init__(
        self,
        *,
        base_url: str | None = None,
        model: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = (base_url or os.environ.get("VOXFLOW_OLLAMA_URL", "http://localhost:11434")).rstrip("/")
        self.model = model or os.environ.get("VOXFLOW_OLLAMA_MODEL", "gemma4:e4b-mlx")
        self.timeout = timeout

    def polish(
        self,
        text: str,
        tone: str,
        system_prompt: str | None = None,
    ) -> str:
        if not text.strip():
            return ""

        # Per-tone constraint goes in the SYSTEM role, not user role, so the
        # model treats tone as a stable constraint rather than a re-negotiable
        # request alongside the transcript itself.
        #
        # SmartActionEngine (Cockpit Layer 0, Task 3) overrides the system
        # prompt with an action-specific instruction (memo / MECE / steel-man).
        # Tone is fixed to "neutral" by that caller, so the tone-instruction
        # append is a no-op in that case.
        if system_prompt is None:
            instruction = _tone_instruction(tone)
            system_prompt = (
                f"{_OLLAMA_SYSTEM_PROMPT_BASE} {instruction}" if instruction else _OLLAMA_SYSTEM_PROMPT_BASE
            )
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": False,
            # Pin the model in unified memory across idle gaps — Ollama's
            # default unload caused multi-second cold-load p95 spikes and
            # 30 s client timeouts between dictations (R2.1). NOTE: only the
            # native /api/chat endpoint honors keep_alive; the OpenAI-compat
            # endpoint silently drops it (verified live 2026-06-11).
            "keep_alive": "24h",
            "options": {
                "temperature": 0.2,
                # Raise the ~128-token default that truncated long-paragraph
                # polish (truncation then tripped the guardrail) (R2.1).
                "num_predict": 512,
            },
        }
        data = json.dumps(payload).encode("utf-8")
        req = urlrequest.Request(
            f"{self.base_url}/api/chat",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        try:
            with urlrequest.urlopen(req, timeout=self.timeout) as resp:
                body = resp.read()
        except (urlerror.URLError, TimeoutError, ConnectionError) as exc:
            logger.warning("Ollama polish unavailable: %s", exc)
            return ""
        except Exception as exc:
            logger.error("Ollama polish request failed: %s", exc)
            return ""

        try:
            parsed = json.loads(body.decode("utf-8"))
            content = parsed["message"]["content"]
        except (KeyError, IndexError, ValueError, TypeError) as exc:
            logger.error("Ollama polish response malformed: %s", exc)
            return ""

        return str(content).strip()

    def is_available(self) -> bool:
        """Probe the Ollama server. Used by /v1/ready readiness reporting.

        Hits GET /api/tags with a short timeout. Returns False on any error.
        """
        req = urlrequest.Request(f"{self.base_url}/api/tags", method="GET")
        try:
            with urlrequest.urlopen(req, timeout=1.5) as resp:
                return 200 <= resp.status < 300
        except Exception:
            return False


_PROBE_LOCK = Lock()
_PROBE_TTL_SECONDS = 5.0
_probe_cache: tuple[float, bool] | None = None


def probe_ollama_available(*, force: bool = False) -> bool:
    """Cached Ollama availability probe for /v1/ready.

    Hits ``GET /api/tags`` with a 1.5s timeout. Cached for ~5 seconds so
    rapid readiness polls don't repeatedly pay the timeout penalty when
    Ollama isn't running. Pass ``force=True`` from tests to bust the cache.
    """
    global _probe_cache
    now = time.monotonic()
    with _PROBE_LOCK:
        if not force and _probe_cache is not None:
            ts, value = _probe_cache
            if now - ts < _PROBE_TTL_SECONDS:
                return value
    probed = OllamaBackend().is_available()
    with _PROBE_LOCK:
        _probe_cache = (now, probed)
    return probed


def reset_ollama_probe_cache() -> None:
    """Test hook: drop the cached probe result so the next call re-probes."""
    global _probe_cache
    with _PROBE_LOCK:
        _probe_cache = None


def select_backend() -> TextLLMBackend:
    """Construct the polish backend.

    Ollama is the only backend after Phase 3.5. When Ollama is unreachable
    the OllamaBackend collapses to an empty string and PolishEngine falls
    back to ``apply_tone(light_cleanup())`` — so the default is safe even
    on machines without Ollama installed; the regex pipeline is the
    documented guardrail-fallback.

    ``VOXFLOW_POLISH_BACKEND`` env var is read for forward compatibility;
    today only ``ollama`` is recognised, any other value logs a warning
    and still returns ``OllamaBackend()``.
    """
    choice = os.environ.get("VOXFLOW_POLISH_BACKEND", "ollama").strip().lower()
    if choice and choice != "ollama":
        logger.warning(
            "Unknown VOXFLOW_POLISH_BACKEND=%r; only 'ollama' is supported "
            "post-3.5 — using ollama.",
            choice,
        )
    try:
        installed = [m.get("name", "") for m in list_ollama_models(timeout=1.5)]
    except Exception:
        installed = []
    model = resolve_default_ollama_model(
        env_override=os.environ.get("VOXFLOW_OLLAMA_MODEL"),
        installed_models=installed,
        host_memory_bytes=detect_host_memory_bytes(),
    )
    logger.info("Polish backend: ollama, model=%s", model)
    return OllamaBackend(model=model)


def resolve_default_ollama_model(
    *,
    env_override: str | None,
    installed_models: list[str],
    host_memory_bytes: int,
) -> str:
    """Pick the default polish model (R2 follow-up).

    Order: explicit env override > the RAM-tier recommendation IF that model
    is actually pulled > any pulled gemma4 model (never select a missing
    model — that 404s into the silent regex fallback, the documented
    ``ollama_available`` blind spot) > the tier recommendation as a static
    default (drives the Settings pull nudge).
    """
    if env_override and env_override.strip():
        return env_override.strip()
    recommended = recommend_ollama_model(host_memory_bytes) or "gemma4:e2b-mlx"
    if recommended in installed_models:
        return recommended
    for name in installed_models:
        if name.startswith("gemma4:"):
            return name
    return recommended


# ── Host memory + recommended model ─────────────────────────────────────


def detect_host_memory_bytes() -> int:
    """Detect physical RAM in bytes. macOS uses ``sysctl hw.memsize``;
    Linux falls back to ``os.sysconf``. Returns 0 on any failure.
    """
    try:
        import subprocess  # local import — only needed for this helper

        result = subprocess.run(
            ["sysctl", "-n", "hw.memsize"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if result.returncode == 0:
            return int(result.stdout.strip())
    except Exception as exc:
        logger.debug("sysctl hw.memsize failed: %s", exc)

    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        phys_pages = os.sysconf("SC_PHYS_PAGES")
        return int(page_size) * int(phys_pages)
    except Exception as exc:
        logger.debug("sysconf RAM detection failed: %s", exc)

    return 0


def recommend_ollama_model(host_memory_bytes: int | None = None) -> str | None:
    """Return the suggested Ollama model id for this host, or ``None``.

    Tiers (R2 retune, 2026-06-11 — measured live on a 16 GB machine):
    - ≥ 24 GB → ``gemma4:e4b-mlx`` (quality default)
    - 8–24 GB → ``gemma4:e2b-mlx`` (the 9 GB e4b plus the Whisper backend
      thrashes a 16 GB machine: prompt eval degrades to ~5 tok/s, the MLX
      runner wedges, and ~28% of polish requests hit the 30 s timeout)
    - < 8 GB  → ``None`` (don't recommend Ollama; regex pipeline only)

    ``VOXFLOW_OLLAMA_MODEL`` env override is honoured by callers; this helper
    only computes the default tier.
    """
    if host_memory_bytes is None:
        host_memory_bytes = detect_host_memory_bytes()
    if host_memory_bytes <= 0:
        return None
    gb = host_memory_bytes / (1024 ** 3)
    if gb >= 24:
        return "gemma4:e4b-mlx"
    if gb >= 8:
        return "gemma4:e2b-mlx"
    return None


# ── Ollama admin operations (list / pull) ───────────────────────────────


def list_ollama_models(base_url: str | None = None, *, timeout: float = 2.0) -> list[dict]:
    """Return the installed Ollama model list from ``GET /api/tags``.

    Empty list on any failure — callers must handle Ollama-unavailable
    gracefully (the Settings UI shows an "Install Ollama" prompt instead).
    """
    base = (base_url or os.environ.get("VOXFLOW_OLLAMA_URL", "http://localhost:11434")).rstrip("/")
    req = urlrequest.Request(f"{base}/api/tags", method="GET")
    try:
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except Exception as exc:
        logger.warning("Ollama /api/tags failed: %s", exc)
        return []
    try:
        parsed = json.loads(body.decode("utf-8"))
    except Exception as exc:
        logger.warning("Ollama /api/tags malformed JSON: %s", exc)
        return []
    models = parsed.get("models", [])
    return models if isinstance(models, list) else []


def pull_ollama_model_stream(model: str, base_url: str | None = None):
    """Yield NDJSON progress lines from Ollama's ``POST /api/pull``.

    The endpoint returns one JSON line per progress event, e.g.::

        {"status": "pulling manifest"}
        {"status": "downloading", "digest": "...", "total": 4500000, "completed": 1200000}
        {"status": "success"}

    This generator yields each line verbatim (already decoded as ``str``)
    so the FastAPI route can re-stream them as a ``text/event-stream`` or
    ``application/x-ndjson`` body without re-parsing. Any HTTP / network
    failure ends the stream with a synthetic error event.
    """
    base = (base_url or os.environ.get("VOXFLOW_OLLAMA_URL", "http://localhost:11434")).rstrip("/")
    payload = json.dumps({"model": model, "stream": True}).encode("utf-8")
    req = urlrequest.Request(
        f"{base}/api/pull",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlrequest.urlopen(req, timeout=None) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8", errors="replace").rstrip("\n")
                if not line:
                    continue
                yield line + "\n"
    except urlerror.HTTPError as exc:
        detail = ""
        try:
            detail = exc.read().decode("utf-8", errors="replace")[:200]
        except Exception:
            pass
        yield json.dumps({"status": "error", "error": f"http_{exc.code}: {detail}"}) + "\n"
    except (urlerror.URLError, ConnectionError, TimeoutError, OSError) as exc:
        yield json.dumps({"status": "error", "error": f"unreachable: {exc}"}) + "\n"
    except Exception as exc:  # pragma: no cover - last-resort fallback
        logger.error("Ollama pull stream unexpected error: %s", exc)
        yield json.dumps({"status": "error", "error": f"unexpected: {exc}"}) + "\n"
