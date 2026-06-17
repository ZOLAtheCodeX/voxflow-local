"""SmartActionEngine — Gemma-powered transcript transformations.

Each action wraps a single instruction (memo / MECE / action items / …)
and delegates to the existing PolishEngine for inference. The engine is
deliberately thin: it builds the action-specific system prompt, passes
the user transcript through, and relies on PolishEngine's guardrail to
catch degenerate outputs (low-similarity, runaway length, exact echo)
and substitute the regex fallback when needed.

Unknown action ids return the transcript verbatim with an error tag —
callers can surface this as a non-blocking warning rather than 5xx.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any, Optional

logger = logging.getLogger("voxflow")


@dataclass(frozen=True)
class SmartActionResult:
    action_id: str
    output: str
    guardrail_triggered: bool
    error: Optional[str] = None
    # Provenance (R3.4)
    served_by: Optional[str] = None
    model_id: Optional[str] = None
    degraded_reason: Optional[str] = None


_ACTION_DESCRIPTIONS: dict[str, str] = {
    "memo": (
        "Restructure as a formal memo with H2 headings for "
        "Issue, Analysis, and Recommendation."
    ),
    "mece": (
        "Reorganize the content into mutually exclusive, "
        "collectively exhaustive bullet groups."
    ),
    "items": (
        "Extract a clean checkbox list of action items. "
        "Include any owners or dates mentioned."
    ),
    "steel": (
        "Produce the strongest steel-manned counter-argument or "
        "alternative framing of the position stated in the text."
    ),
    "pyramid": (
        "Restructure as a Pyramid Principle: a single-sentence conclusion "
        "first, then supporting points, then evidence."
    ),
    "disclaimer": (
        "Append a one-sentence legal-information disclaimer noting this "
        "is informational only and not legal advice."
    ),
}


_SYSTEM_PROMPT_TEMPLATE = (
    "You are a writing assistant. Apply the requested transformation to "
    "the user's text. Return only the transformed text. No explanation, "
    "no preamble, no quotes around the output.\n\n"
    "Transformation: {action_description}\n\n"
    "Constraints:\n"
    "- Preserve the user's meaning and intent.\n"
    "- Do not add information not present in the input.\n"
    "- Do not add caveats, hedging, or apologies."
)


class SmartActionEngine:
    """Orchestrates smart-action transformations over a polish backend.

    The polish backend is expected to expose a ``polish(text, ...)`` method
    returning ``(output, guardrail_triggered)``. The exact tone parameter
    is fixed to ``"neutral"`` here — smart actions are about structure,
    not tone (tone selection lives on the dictation path).
    """

    def __init__(self, polish_backend: Any):
        self._polish_backend = polish_backend

    def apply(self, action_id: str, transcript: str) -> SmartActionResult:
        description = _ACTION_DESCRIPTIONS.get(action_id)
        if description is None:
            return SmartActionResult(
                action_id=action_id,
                output=transcript,
                guardrail_triggered=False,
                error=f"unknown action: {action_id}",
            )

        system_prompt = _SYSTEM_PROMPT_TEMPLATE.format(action_description=description)
        # Let the WHOLE provider chain attempt the transformation. Availability
        # is decided by EXECUTION, not a preflight on the chain head: a
        # head-only ``is_available()`` probe would refuse the action even when a
        # healthy fallback provider could serve it.
        #
        # Chain engines expose run() with provenance (R3.4); legacy/stub
        # backends only expose polish() — fall back to the 3-tuple.
        run = getattr(self._polish_backend, "run", None)
        if callable(run):
            from engines.polish import PolishOutcome

            try:
                outcome = run(transcript, "neutral", system_prompt=system_prompt)
            except TypeError:
                outcome = None
            if isinstance(outcome, PolishOutcome):
                # Fail closed when NO real provider served and the chain fell to
                # the regex floor (served_by == "regex"). PolishEngine's floor
                # (apply_tone(light_cleanup())) is fine for polish but
                # structurally wrong for smart actions — returning grammar-cleaned
                # text to a user who asked for MECE / steel-man / disclaimer is
                # misleading. Surface ``provider_unavailable`` + the verbatim
                # transcript so callers can show a "configure a provider" message
                # rather than inserting the floor output. (The label is provider-
                # neutral because the chain may hold non-Ollama providers.)
                if outcome.served_by == "regex":
                    logger.warning(
                        "SmartActionEngine: chain served only the regex floor — "
                        "refusing action %r",
                        action_id,
                    )
                    return SmartActionResult(
                        action_id=action_id,
                        output=transcript,
                        guardrail_triggered=False,
                        error="provider_unavailable",
                    )
                return SmartActionResult(
                    action_id=action_id,
                    output=outcome.text,
                    guardrail_triggered=outcome.guardrail_triggered,
                    served_by=outcome.served_by,
                    model_id=outcome.model_id,
                    degraded_reason=outcome.degraded_reason,
                )
        output, guardrail, reason = self._polish_backend.polish(
            text=transcript,
            system_prompt=system_prompt,
            tone="neutral",
        )
        return SmartActionResult(
            action_id=action_id,
            output=output,
            guardrail_triggered=guardrail,
            degraded_reason=reason,
        )
