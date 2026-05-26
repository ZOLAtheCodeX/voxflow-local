"""Text cleanup helpers — parity with Swift TextCleanupService.

Six-step pipeline: normalize whitespace → spoken punctuation → repeated-word
dedup → sentence split + recase → filler removal → final normalization.

POS-aware ambiguous filler removal (Phase 2 in Swift) is intentionally omitted
here to avoid the nltk/spacy dependency.
"""

from __future__ import annotations

import re

from text_cleanup_rules import (
    ALWAYS_FILLERS,
    PHRASE_FILLERS,
    SPOKEN_PUNCTUATION,
)


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def replace_spoken_punctuation(text: str) -> str:
    """Convert spoken punctuation words to actual punctuation characters."""
    result = text
    for pattern, replacement in SPOKEN_PUNCTUATION:
        result = pattern.sub(replacement, result)
    return result


def remove_repeated_words(text: str) -> str:
    """Remove adjacent duplicate words (case-insensitive)."""
    words = text.split()
    if len(words) <= 1:
        return text
    result = [words[0]]
    for word in words[1:]:
        if word.lower() != result[-1].lower():
            result.append(word)
    return " ".join(result)


def remove_fillers(text: str) -> str:
    """Remove filler words and phrases.

    Phase 0: Multi-word phrase fillers (regex).
    Phase 1: Single-word always-fillers (set membership).
    No Phase 2 (POS-aware ambiguous fillers) — accepted gap vs Swift.
    """
    result = text
    for pattern, replacement in PHRASE_FILLERS:
        result = pattern.sub(replacement, result)
    result = normalize_whitespace(result)
    words = result.split()
    words = [w for w in words if w.lower() not in ALWAYS_FILLERS]
    return " ".join(words)


def split_and_recase(text: str) -> str:
    """Split on sentence-ending punctuation and uppercase first char of each.

    Intentional divergence from Swift: Python uses regex-only splitting while
    Swift uses NLTokenizer + regex sub-splitting. This can diverge on edge
    cases like abbreviations ("Dr.") or punctuation without following whitespace.
    Accepted tradeoff to avoid adding nltk/spacy dependency.
    """
    segments = re.split(r"(?<=[.!?])\s+", text)
    recased = []
    for seg in segments:
        seg = seg.strip()
        if seg:
            seg = seg[0].upper() + seg[1:]
        recased.append(seg)
    return " ".join(recased)


def light_cleanup(text: str) -> str:
    """6-step cleanup pipeline mirroring Swift TextCleanupService.cleanup(.light)."""
    cleaned = normalize_whitespace(text)
    if not cleaned:
        return ""
    cleaned = replace_spoken_punctuation(cleaned)
    cleaned = remove_repeated_words(cleaned)
    cleaned = split_and_recase(cleaned)
    cleaned = remove_fillers(cleaned)
    cleaned = normalize_whitespace(cleaned)
    if not cleaned:
        return ""
    if cleaned[-1] not in ".!?":
        cleaned += "."
    if cleaned[0].islower():
        cleaned = cleaned[0].upper() + cleaned[1:]
    return cleaned
