"""Tone transforms (concise / formal / friendly / neutral).

Dispatches by tone string. Each private helper applies a tone-specific
set of regex substitutions plus light normalization.
"""

from __future__ import annotations

from text_cleanup_rules import (
    CASUAL_INTERJECTIONS,
    CONTRACTIONS,
    HEDGING_PHRASES,
    SOFTENERS,
)

from .cleanup import normalize_whitespace


def _apply_concise_tone(text: str) -> str:
    result = text
    for pattern, replacement in HEDGING_PHRASES + SOFTENERS:
        result = pattern.sub(replacement, result)
    return normalize_whitespace(result)


def _apply_formal_tone(text: str) -> str:
    result = text
    for pattern, replacement in CONTRACTIONS + CASUAL_INTERJECTIONS:
        result = pattern.sub(replacement, result)
    result = normalize_whitespace(result)
    if result and result[-1] not in ".!?":
        result += "."
    return result


def _apply_friendly_tone(text: str) -> str:
    """Intentional divergence from Swift: Python only appends '!' when no
    terminal punctuation exists. Swift also does POS-based imperative softening
    ("Send X" → "Let's send X") using NLTagger. Accepted tradeoff — same
    reasoning as POS-aware filler removal.
    """
    if text and text[-1] not in ".!?":
        return text + "!"
    return text


def apply_tone(text: str, tone: str) -> str:
    """Apply tone transform. Dispatches to private helpers."""
    normalized = normalize_whitespace(text)
    tone = tone.lower().strip()
    if tone == "concise":
        return _apply_concise_tone(normalized)
    if tone == "formal":
        return _apply_formal_tone(normalized)
    if tone == "friendly":
        return _apply_friendly_tone(normalized)
    return normalized
