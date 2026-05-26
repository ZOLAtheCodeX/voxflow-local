"""Pluggable text-LLM backends for PolishEngine.

The Protocol is intentionally synchronous. The roadmap's Phase 2 Task 9
("wrap ML inference in run_in_executor with asyncio.Semaphore(2)") is where
the async bridge will be introduced — uniformly for *all* engines, not piecemeal
inside one Protocol. Until then PolishEngine keeps the existing sync contract
expected by `provider.cleanup` and the FastAPI route handler.

Selector: ``VOXFLOW_POLISH_BACKEND`` env var
  - ``flan_t5`` (default in 3.1, removed in 3.5)
  - ``ollama`` (default after 3.4)

PolishEngine wraps the backend with its existing guardrail + echo detection
+ ``apply_tone(light_cleanup())`` fallback. Backends therefore only need to
produce a candidate string — guardrail decisions live one layer up.
"""

from __future__ import annotations

import json
import logging
import os
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

    def polish(self, text: str, tone: str) -> str:  # pragma: no cover - Protocol
        ...


_TONE_INSTRUCTIONS = {
    "concise": "Remove unnecessary words. Be direct and brief.",
    "formal": "Use professional language. Avoid contractions and slang.",
    "friendly": "Use warm, approachable language.",
    "neutral": "Use clear, natural language.",
}


def _tone_instruction(tone: str) -> str:
    return _TONE_INSTRUCTIONS.get(tone.lower(), _TONE_INSTRUCTIONS["neutral"])


class FlanT5Backend:
    """Wraps the existing FLAN-T5 text2text-generation pipeline.

    This backend exists so the model swap is a Protocol-level concern. The
    FLAN-T5 path is scheduled for full removal in 3.5; until then it remains
    the default so the rollout is risk-bounded.
    """

    name = "flan_t5"

    def __init__(self) -> None:
        from ._utils import preferred_torch_device, resolve_model_ref

        model_ref = os.environ.get("VOXFLOW_POLISH_MODEL", "google/flan-t5-small")
        self.model_id = resolve_model_ref(model_ref)
        self._device = preferred_torch_device()
        self._pipeline = None
        self._load_failed = False

    def _load_pipeline(self) -> None:
        if self._pipeline is not None or self._load_failed:
            return
        try:
            from transformers import pipeline

            self._pipeline = pipeline(
                task="text2text-generation",
                model=self.model_id,
                device=self._device,
            )
            logger.info("Loaded polish model: %s", self.model_id)
        except Exception as exc:
            logger.error("Failed to load polish model %s: %s", self.model_id, exc)
            self._load_failed = True

    def retry_load(self) -> None:
        self._load_failed = False
        self._load_pipeline()

    @property
    def loaded(self) -> bool:
        return self._pipeline is not None

    def polish(self, text: str, tone: str) -> str:
        self._load_pipeline()
        if not self._pipeline:
            return ""

        tone_instruction = _tone_instruction(tone)
        prompt = (
            f"Rewrite this spoken transcript as clean written text. "
            f"Do not add new information. {tone_instruction} "
            f"Transcript: {text}"
        )
        word_count = len(text.split())
        max_tokens = min(200, max(60, word_count * 3))
        try:
            result = self._pipeline(prompt, max_new_tokens=max_tokens)[0]["generated_text"].strip()
            return result
        except Exception as exc:
            logger.error("FLAN-T5 polish inference failed: %s", exc)
            return ""


_OLLAMA_SYSTEM_PROMPT_BASE = (
    "You clean up dictated speech. Return only the cleaned text, "
    "no explanation, no preamble."
)


class OllamaBackend:
    """Polishes via a local Ollama server using stdlib urllib (no new deps).

    POSTs to ``http://localhost:11434/v1/chat/completions`` (Ollama's
    OpenAI-compatible endpoint). Connection errors / timeouts / malformed
    responses all collapse to an empty string — PolishEngine then falls back
    to ``apply_tone(light_cleanup(text))``. Unavailability never surfaces as 500.
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

    def polish(self, text: str, tone: str) -> str:
        if not text.strip():
            return ""

        # Per-tone constraint goes in the SYSTEM role, not user role, so the
        # model treats tone as a stable constraint rather than a re-negotiable
        # request alongside the transcript itself.
        system_prompt = f"{_OLLAMA_SYSTEM_PROMPT_BASE} {_tone_instruction(tone)}"
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": False,
            "temperature": 0.2,
        }
        data = json.dumps(payload).encode("utf-8")
        req = urlrequest.Request(
            f"{self.base_url}/v1/chat/completions",
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
            content = parsed["choices"][0]["message"]["content"]
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


def select_backend() -> TextLLMBackend:
    """Construct the backend selected by ``VOXFLOW_POLISH_BACKEND``.

    Default during 3.1–3.3 is ``flan_t5`` so existing behavior is unchanged
    until the Ollama path is validated against golden tests in 3.4.
    """
    choice = os.environ.get("VOXFLOW_POLISH_BACKEND", "flan_t5").strip().lower()
    if choice == "ollama":
        return OllamaBackend()
    if choice == "flan_t5":
        return FlanT5Backend()
    logger.warning(
        "Unknown VOXFLOW_POLISH_BACKEND=%r; falling back to flan_t5", choice
    )
    return FlanT5Backend()
