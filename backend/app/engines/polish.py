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
from dataclasses import dataclass
from difflib import SequenceMatcher
from threading import Lock

from nlp import apply_tone, light_cleanup, replace_spoken_punctuation
from privacy import redact_sensitive_text

from .llm_backend import TextLLMBackend, probe_ollama_available, select_backend
from .provider_registry import ProviderSpec

logger = logging.getLogger("voxflow")


@dataclass(frozen=True)
class PolishOutcome:
    """Full result of a chain run, with provenance (R3.4).

    ``served_by`` is the provider id that produced the text ("regex" for the
    rules floor); ``fallback_depth`` is how many chain entries were skipped
    or rejected before this one served (len(chain) when the floor served).
    """

    text: str
    guardrail_triggered: bool
    degraded_reason: str | None
    served_by: str
    model_id: str | None
    fallback_depth: int


class PolishEngine:
    def __init__(
        self,
        backend: TextLLMBackend | None = None,
        *,
        chain: list[tuple[ProviderSpec | None, TextLLMBackend]] | None = None,
    ) -> None:
        if chain is not None:
            self._chain = chain
        else:
            resolved = backend or select_backend()
            self._chain = [(None, resolved)]
        self._lock = Lock()

    @property
    def _backend(self) -> TextLLMBackend:
        """First backend in the chain — compat for probes and legacy tests."""
        return self._chain[0][1]

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
        """Compat wrapper over :meth:`run` returning the R2 3-tuple."""
        out = self.run(text, tone, system_prompt=system_prompt)
        return out.text, out.guardrail_triggered, out.degraded_reason

    def run(
        self,
        text: str,
        tone: str,
        system_prompt: str | None = None,
    ) -> PolishOutcome:
        """Run the provider chain and return text plus provenance (R3.3/R3.4).

        Chain semantics: providers handle AVAILABILITY (empty/error output
        falls to the next provider); the guardrail handles QUALITY (a
        rejected candidate falls straight to the regex floor — retrying a
        different model on a quality failure would double latency). The
        regex floor is appended unconditionally and never fails.

        Privacy posture (R3.3): payloads bound for a cloud provider pass
        through ``redact_sensitive_text`` first; local providers receive the
        raw text. The regex floor always works on the original local text.

        When ``system_prompt`` is supplied (SmartActionEngine), guardrail +
        echo checks are skipped — those rules are designed for polish and
        would reject legitimate structural transformations.
        """
        if not text.strip():
            return PolishOutcome("", False, None, served_by="none", model_id=None, fallback_depth=0)

        # Polish path only: convert spoken punctuation deterministically
        # BEFORE the LLM — small models read "the new policy period" as a
        # noun phrase (caught live on gemma4:e2b-mlx). The smart-action path
        # receives transcripts verbatim: converting "period" inside a memo
        # transform could corrupt real content.
        if system_prompt is None:
            text = replace_spoken_punctuation(text)

        redacted_text: str | None = None
        for depth, (spec, backend) in enumerate(self._chain):
            is_cloud = bool(spec and spec.is_cloud)
            if is_cloud:
                if redacted_text is None:
                    redacted_text = redact_sensitive_text(text)
                send_text = redacted_text
            else:
                send_text = text

            try:
                candidate = backend.polish(
                    send_text,
                    tone,
                    system_prompt=system_prompt,
                    model=spec.model if spec else None,
                    timeout=spec.timeout if spec else None,
                )
            except TypeError:
                # Legacy backend without the per-request override params.
                try:
                    if system_prompt is not None:
                        candidate = backend.polish(send_text, tone, system_prompt=system_prompt)
                    else:
                        candidate = backend.polish(send_text, tone)
                except Exception as exc:
                    logger.error("Polish backend %s raised: %s", getattr(backend, "name", "?"), exc)
                    candidate = ""
            except Exception as exc:
                logger.error("Polish backend %s raised: %s", getattr(backend, "name", "?"), exc)
                candidate = ""

            if not candidate:
                continue  # availability failure -> next provider

            served_by = spec.id if spec else getattr(backend, "name", "backend")
            model_id = (spec.model if spec else None) or getattr(backend, "model", None)

            if system_prompt is not None:
                return PolishOutcome(candidate, False, None, served_by=served_by, model_id=model_id, fallback_depth=depth)

            reason = self._guardrail_triggered(send_text, candidate, tone)
            if reason:
                return PolishOutcome(
                    apply_tone(light_cleanup(text), tone), True, reason,
                    served_by="regex", model_id=None, fallback_depth=depth,
                )
            if self._is_echo(send_text, candidate):
                return PolishOutcome(
                    apply_tone(light_cleanup(text), tone), False, "echo",
                    served_by="regex", model_id=None, fallback_depth=depth,
                )
            return PolishOutcome(candidate, False, None, served_by=served_by, model_id=model_id, fallback_depth=depth)

        return PolishOutcome(
            apply_tone(light_cleanup(text), tone), False, "backend_unavailable",
            served_by="regex", model_id=None, fallback_depth=len(self._chain),
        )

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

        # Digit preservation (2026-06-12): every maximal digit run in the
        # input must survive as a substring of the candidate. The e2b
        # default model converts digits to words under tone=formal
        # ("client 42" -> "client forty-two") and prompt wording does not
        # reliably stop it — hard invariants belong here, not in the
        # prompt. Substring match keeps this lenient: "10 30" -> "10:30"
        # passes; words->digits ("five hundred" -> "500") adds digits and
        # loses nothing, so it never trips. Checked before the short-input
        # early exit below — digit loss in a 3-word utterance still counts.
        for digit_run in re.findall(r"\d+", original):
            if digit_run not in candidate:
                return "guardrail_digits"

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
