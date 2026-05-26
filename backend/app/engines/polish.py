"""PolishEngine — pluggable text-LLM polish + tone application.

Wraps a ``TextLLMBackend`` (today: Ollama / Gemma 4) with:
  - the guardrail / echo / similarity / length-ratio rules
  - the ``apply_tone(light_cleanup(text), tone)`` regex fallback floor

Callers always get usable output: backend declined (empty string) → fallback;
backend returned a degenerate candidate → guardrail fires → fallback.

Backend construction is driven by ``select_backend()`` in ``llm_backend.py``.
"""

from __future__ import annotations

import logging
import re
from difflib import SequenceMatcher
from threading import Lock

from nlp import apply_tone, light_cleanup

from .llm_backend import TextLLMBackend, select_backend

logger = logging.getLogger("voxflow")


class PolishEngine:
    def __init__(self, backend: TextLLMBackend | None = None) -> None:
        self._backend: TextLLMBackend = backend or select_backend()
        self._lock = Lock()

    @property
    def backend_name(self) -> str:
        return getattr(self._backend, "name", "unknown")

    @property
    def model_id(self) -> str:
        """Compat with prior API surface (used in /v1/ready logging).

        Returns the underlying model identifier when the backend exposes one.
        """
        return getattr(self._backend, "model_id", None) or getattr(self._backend, "model", "") or ""

    def retry_load(self) -> None:
        """Reset failure state for backends that support lazy reload."""
        retry = getattr(self._backend, "retry_load", None)
        if callable(retry):
            with self._lock:
                retry()

    def polish(self, text: str, tone: str) -> tuple[str, bool]:
        if not text.strip():
            return "", False

        try:
            candidate = self._backend.polish(text, tone)
        except Exception as exc:
            logger.error("Polish backend %s raised: %s", self.backend_name, exc)
            candidate = ""

        if not candidate:
            return apply_tone(light_cleanup(text), tone), False

        if self._guardrail_triggered(text, candidate):
            return apply_tone(light_cleanup(text), tone), True

        if self._is_echo(text, candidate):
            return apply_tone(light_cleanup(text), tone), False

        return candidate, False

    @staticmethod
    def _is_echo(original: str, candidate: str) -> bool:
        """Backend just echoed the input (modulo punctuation/case)."""
        def _normalize(s: str) -> str:
            return re.sub(r"[^\w\s]", "", s.strip().lower())
        return _normalize(original) == _normalize(candidate)

    @staticmethod
    def _guardrail_triggered(original: str, candidate: str) -> bool:
        if not candidate.strip():
            return True

        similarity = SequenceMatcher(None, original.lower(), candidate.lower()).ratio()
        if similarity < 0.55:
            return True

        original_length = max(1, len(original.split()))
        candidate_length = len(candidate.split())
        length_ratio = candidate_length / original_length

        if original_length <= 5:
            return False

        max_ratio = 2.5 if original_length <= 10 else 1.8
        return length_ratio < 0.6 or length_ratio > max_ratio
