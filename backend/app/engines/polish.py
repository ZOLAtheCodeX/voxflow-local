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
import os
import re
import time
from dataclasses import dataclass
from difflib import SequenceMatcher
from threading import Lock
from typing import Callable

from nlp import apply_tone, light_cleanup, replace_spoken_punctuation
from privacy import redact_sensitive_text

from . import llm_backend
from .llm_backend import TextLLMBackend, select_backend
from .provider_registry import ProviderSpec

logger = logging.getLogger("voxflow")

# Maximal digit run, hoisted so the guardrail reuses one compiled pattern.
# (Python's re module already caches compiled patterns, so this is a clarity
# change more than a perf one — it makes the digit-preservation invariant a
# named module constant rather than an inline literal.)
_DIGIT_RUN_RE = re.compile(r"\d+")


@dataclass(frozen=True)
class PolishOutcome:
    """Full result of a chain run, with provenance (R3.4).

    ``served_by`` is the provider id that produced the text, ``"regex"`` for
    the degraded floor (providers configured but all failed), or ``"rules"``
    for the deliberately CHOSEN floor (user set chains.polish = ["rules"]);
    ``fallback_depth`` is how many chain entries were skipped or rejected
    before this one served (len(chain) when the floor served).
    """

    text: str
    guardrail_triggered: bool
    degraded_reason: str | None
    served_by: str
    model_id: str | None
    fallback_depth: int


class PolishEngine:
    # Wedged-warm circuit breaker (session 29 stability review): a wedged MLX
    # runner answers /api/tags fine (so availability probes stay green) while
    # every chat request burns the full 30 s timeout — without a breaker each
    # polished dictation stalled 30 s until the user manually ran
    # `ollama stop` (~28% of requests during documented thrash). A failure is
    # "wedge-shaped" when the provider returned nothing AND consumed most of
    # its timeout budget; two in a row open the breaker for the cooldown, and
    # expiry lets one probe request through (half-open).
    _WEDGE_TRIP_COUNT = 2
    _WEDGE_COOLDOWN_S = 120.0
    _WEDGE_TIMEOUT_FRACTION = 0.8

    # Memory-pressure skip thresholds (kern.memorystatus_vm_pressure_level:
    # 1 normal, 2 warn, 4 critical). Polish sits on the dictation hot path
    # and yields at WARN so the resident LLM never competes with live
    # capture. Smart actions run in the cockpit's review state with no
    # capture live, so they yield only at CRITICAL: a 16 GB machine rests at
    # warn (measured 2026-08-24), and the shared threshold had turned every
    # smart action into `provider_unavailable`.
    _POLISH_PRESSURE_SKIP_LEVEL = 2
    _SMART_ACTION_PRESSURE_SKIP_LEVEL = 4

    def __init__(
        self,
        backend: TextLLMBackend | None = None,
        *,
        chain: list[tuple[ProviderSpec | None, TextLLMBackend]] | None = None,
        clock: Callable[[], float] = time.monotonic,
        rules_only: bool = False,
    ) -> None:
        if chain is not None:
            self._chain = chain
        else:
            resolved = backend or select_backend()
            self._chain = [(None, resolved)]
        self._lock = Lock()
        self._clock = clock
        self._rules_only = rules_only
        # Keyed by chain depth (stable identity even for spec-less entries).
        self._wedge_failures: dict[int, int] = {}
        self._breaker_open_until: dict[int, float] = {}

    @property
    def _backend(self) -> TextLLMBackend | None:
        """First backend in the chain — compat for probes and legacy tests.

        None when the chain is empty (rules-only polish) — every accessor
        below must tolerate that rather than IndexError.
        """
        return self._chain[0][1] if self._chain else None

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
        if self._backend is None:
            return
        retry = getattr(self._backend, "retry_load", None)
        if callable(retry):
            with self._lock:
                retry()

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

        # Rules-only (user-chosen "Local rules only" polish): serve the floor
        # deliberately. served_by="rules" ≠ served_by="regex" — chosen is not
        # degraded, so degraded_reason stays None. Smart actions never carry
        # the sentinel (UI does not offer it); a system_prompt call on a
        # rules-only engine falls through to the normal (empty) chain walk.
        if self._rules_only and system_prompt is None:
            return PolishOutcome(
                apply_tone(light_cleanup(text), tone), False, None,
                served_by="rules", model_id=None, fallback_depth=0,
            )

        # Polish path only: convert spoken punctuation deterministically
        # BEFORE the LLM — small models read "the new policy period" as a
        # noun phrase (caught live on gemma4:e2b-mlx). The smart-action path
        # receives transcripts verbatim: converting "period" inside a memo
        # transform could corrupt real content.
        if system_prompt is None:
            text = replace_spoken_punctuation(text)

        # Memory-aware degrade: under OS memory pressure (warn or worse),
        # skip LOCAL providers — the resident LLM must never compete with
        # live capture for unified memory on a constrained machine. Cloud
        # providers cost no local RAM and still run. The pressure signal is
        # the kernel's own damped level (fail-open to normal), so no
        # hysteresis is needed here. Disable via VOXFLOW_POLISH_MEMORY_GUARD=0.
        # Called through the module so tests can monkeypatch the source.
        guard_enabled = os.environ.get("VOXFLOW_POLISH_MEMORY_GUARD", "1").strip() != "0"
        pressure = llm_backend.detect_memory_pressure_level() if guard_enabled else 1
        skip_level = (
            self._SMART_ACTION_PRESSURE_SKIP_LEVEL if system_prompt is not None
            else self._POLISH_PRESSURE_SKIP_LEVEL
        )
        memory_skipped = False

        redacted_text: str | None = None
        wedge_skipped = False
        for depth, (spec, backend) in enumerate(self._chain):
            is_cloud = bool(spec and spec.is_cloud)
            if not is_cloud and pressure >= skip_level:
                if not memory_skipped:
                    logger.info(
                        "Memory pressure level %d — skipping local polish provider(s); cloud chain entries still run",
                        pressure,
                    )
                memory_skipped = True
                continue
            with self._lock:
                open_until = self._breaker_open_until.get(depth, 0.0)
            if self._clock() < open_until:
                wedge_skipped = True
                continue
            if is_cloud:
                if redacted_text is None:
                    redacted_text = redact_sensitive_text(text)
                send_text = redacted_text
            else:
                send_text = text

            started = self._clock()
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
                self._record_empty_result(depth, spec, backend, elapsed=self._clock() - started)
                continue  # availability failure -> next provider
            self._record_success(depth)

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

        if memory_skipped:
            floor_reason = "memory_pressure"
        elif wedge_skipped:
            floor_reason = "provider_wedged"
        else:
            floor_reason = "backend_unavailable"
        return PolishOutcome(
            apply_tone(light_cleanup(text), tone), False, floor_reason,
            served_by="regex", model_id=None, fallback_depth=len(self._chain),
        )

    def _record_empty_result(
        self,
        depth: int,
        spec: ProviderSpec | None,
        backend: TextLLMBackend,
        *,
        elapsed: float,
    ) -> None:
        """Classify an empty polish result: timeout-shaped (burned most of the
        provider's timeout budget → wedge evidence) vs fast (connection
        refused → the chain already handles it cheaply, no breaker needed)."""
        budget = (spec.timeout if spec and spec.timeout else None) or getattr(backend, "timeout", 30.0)
        if elapsed < budget * self._WEDGE_TIMEOUT_FRACTION:
            return
        with self._lock:
            failures = self._wedge_failures.get(depth, 0) + 1
            self._wedge_failures[depth] = failures
            if failures >= self._WEDGE_TRIP_COUNT:
                self._breaker_open_until[depth] = self._clock() + self._WEDGE_COOLDOWN_S
                # Half-open on expiry: the next request probes once; another
                # wedge-shaped failure re-opens immediately (count stays high).
                self._wedge_failures[depth] = failures - 1
                logger.warning(
                    "Polish provider %s wedged (%d consecutive timeout-shaped failures) — "
                    "skipping it for %.0f s; run `ollama stop <model>` to recover the runner",
                    (spec.id if spec else getattr(backend, "name", "?")),
                    failures,
                    self._WEDGE_COOLDOWN_S,
                )

    def _record_success(self, depth: int) -> None:
        with self._lock:
            self._wedge_failures.pop(depth, None)
            self._breaker_open_until.pop(depth, None)

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
        for digit_run in _DIGIT_RUN_RE.findall(original):
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
