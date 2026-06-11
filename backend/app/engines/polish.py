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

from nlp import apply_tone, light_cleanup, replace_spoken_punctuation

from .llm_backend import TextLLMBackend, probe_ollama_available, select_backend

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

    def is_available(self) -> bool:
        """Whether the configured backend can actually serve requests now.

        Polish has a regex fallback so this is informational, but
        SmartActionEngine uses it to fail closed — a regex-cleaned
        transcript is not a valid substitute for "convert to MECE".
        The Ollama probe is cached (~5s TTL) so this is cheap to call.
        """
        if self.backend_name != "ollama":
            return True
        return probe_ollama_available()

    def polish(
        self,
        text: str,
        tone: str,
        system_prompt: str | None = None,
    ) -> tuple[str, bool, str | None]:
        """Polish ``text`` through the configured backend.

        Returns ``(output, guardrail_triggered, degraded_reason)``.
        ``degraded_reason`` distinguishes WHY output is not clean LLM text:
        ``backend_unavailable`` (declined/error -> regex fallback),
        ``guardrail_similarity`` / ``guardrail_length`` / ``guardrail_empty``
        (candidate rejected -> regex fallback), ``echo`` (backend returned
        the input unchanged -> regex fallback), or ``None`` (clean output).
        Previously all of these collapsed into one boolean (audit BYOM gap #2).

        When ``system_prompt`` is supplied (e.g. from SmartActionEngine for
        memo / MECE / steel-man / Pyramid transformations), the guardrail
        + echo checks are skipped — those rules are designed for polish
        ("output should look like input but cleaner") and would reject
        legitimate structural transformations whose whole point is to
        diverge from the input. The empty-output fallback still applies
        so a backend failure still gives the caller usable text.
        """
        if not text.strip():
            return "", False, None

        # Polish path only: convert spoken punctuation deterministically
        # BEFORE the LLM — small models read "the new policy period" as a
        # noun phrase (caught live on gemma4:e2b-mlx). Light/raw modes
        # already convert via light_cleanup; this keeps polish consistent.
        # The smart-action path receives transcripts verbatim: converting
        # "period" inside a memo transform could corrupt real content.
        if system_prompt is None:
            text = replace_spoken_punctuation(text)

        try:
            if system_prompt is not None:
                candidate = self._backend.polish(text, tone, system_prompt=system_prompt)
            else:
                candidate = self._backend.polish(text, tone)
        except Exception as exc:
            logger.error("Polish backend %s raised: %s", self.backend_name, exc)
            candidate = ""

        if not candidate:
            return apply_tone(light_cleanup(text), tone), False, "backend_unavailable"

        # Smart-action path: trust the LLM output. Unchanged-echo is filtered
        # one layer up (SmartActionService undo stack + CockpitCoordinator
        # session history), so we don't need to detect it here.
        if system_prompt is not None:
            return candidate, False, None

        reason = self._guardrail_triggered(text, candidate, tone)
        if reason:
            return apply_tone(light_cleanup(text), tone), True, reason

        if self._is_echo(text, candidate):
            return apply_tone(light_cleanup(text), tone), False, "echo"

        return candidate, False, None

    @staticmethod
    def _is_echo(original: str, candidate: str) -> bool:
        """Backend just echoed the input (modulo punctuation/case)."""
        def _normalize(s: str) -> str:
            return re.sub(r"[^\w\s]", "", s.strip().lower())
        return _normalize(original) == _normalize(candidate)

    @staticmethod
    def _tokens(s: str) -> list[str]:
        return re.findall(r"[a-z0-9']+", s.lower())

    @staticmethod
    def _guardrail_triggered(original: str, candidate: str, tone: str = "neutral") -> str | None:
        """Reject degenerate LLM output. Returns a reason string or None.

        R2.2 retune, validated against the golden set:
        - WORD-level SequenceMatcher (threshold 0.3). The old character-level
          0.55 punished legitimate restructuring ("I think we should" ->
          "We should") and fired on ~29% of correct outputs.
        - Length floor 0.3 for >10-word inputs (0.4 for 6-10; the old 0.6
          floor made correct filler-removal mathematically impossible for
          filler-heavy dictations — the golden set's own filler case could
          never pass).
        - The concise tone is exempted down to 0.15: shortening is its job.
        Truthy return keeps PrivateAPIClient's boolean use working.
        """
        if not candidate.strip():
            return "guardrail_empty"

        concise = tone.lower() == "concise"
        original_words = PolishEngine._tokens(original)
        candidate_words = PolishEngine._tokens(candidate)
        similarity = SequenceMatcher(None, original_words, candidate_words).ratio()
        # Concise output legitimately shares fewer tokens with the input —
        # both floors relax together or the exemption is meaningless.
        if similarity < (0.15 if concise else 0.3):
            return "guardrail_similarity"

        original_length = max(1, len(original_words))
        length_ratio = len(candidate_words) / original_length

        if original_length <= 5:
            return None

        max_ratio = 2.5 if original_length <= 10 else 1.8
        min_ratio = 0.3 if original_length > 10 else 0.4
        if concise:
            min_ratio = 0.15
        if length_ratio < min_ratio or length_ratio > max_ratio:
            return "guardrail_length"
        return None
