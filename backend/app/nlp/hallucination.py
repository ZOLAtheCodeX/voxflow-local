"""Whisper hallucination filter — parity with Swift HallucinationFilter.

Two-tier filter: ALWAYS-filtered phrases (e.g., YouTube outros, musical notes)
suppressed regardless of audio duration; SHORT-ONLY phrases (e.g., "thank you",
"bye") suppressed only when the source audio was short (< 3s) — they could be
real speech in longer recordings.

Punctuation normalization makes "hello!", "hello?", '"hello"' all match the
"hello" entry. The parity test in test_utils.py asserts this set stays
synchronized with Sources/VoxFlowApp/Services/HallucinationFilter.swift.
"""

from __future__ import annotations

import re

# Phrases Whisper hallucinates that are NEVER real dictation — filter at any duration
_WHISPER_HALLUCINATION_ALWAYS = frozenset(
    p.lower()
    for p in [
        "Thank you for watching.",
        "Thank you for watching!",
        "Thanks for watching.",
        "Thanks for watching!",
        "Thank you so much for watching.",
        "Thank you so much for watching!",
        "Subscribe to my channel.",
        "Subscribe to the channel.",
        "Subscribe for more.",
        "Subscribe for more!",
        "Please subscribe.",
        "Like and subscribe.",
        "Please like and subscribe.",
        "♪",
        "♪♪",
        "♪♪♪",
        "♫",
        "♬",
        "...",
        "…",
        "Hello.",
        "Hello",
        "Hi.",
        "Hi",
        "Hey.",
        "Hey",
    ]
)

# Phrases only filtered on short audio (< 3s) — could be real speech in longer recordings
_WHISPER_HALLUCINATION_SHORT_ONLY = frozenset(
    p.lower()
    for p in [
        "Thank you.",
        "Thanks.",
        "Bye.",
        "Goodbye.",
        "you",
        "You",
    ]
)


_BOUNDARY_PUNCTUATION_RE = re.compile(r"^[.!?,;:…\"']+|[.!?,;:…\"']+$")

# Pre-computed normalized (punctuation-stripped) versions for O(1) lookup
_WHISPER_HALLUCINATION_ALWAYS_NORMALIZED = frozenset(
    _BOUNDARY_PUNCTUATION_RE.sub("", p) for p in _WHISPER_HALLUCINATION_ALWAYS if _BOUNDARY_PUNCTUATION_RE.sub("", p)
)
_WHISPER_HALLUCINATION_SHORT_NORMALIZED = frozenset(
    _BOUNDARY_PUNCTUATION_RE.sub("", p) for p in _WHISPER_HALLUCINATION_SHORT_ONLY if _BOUNDARY_PUNCTUATION_RE.sub("", p)
)


def is_whisper_hallucination(text: str, short_audio: bool = True) -> bool:
    """Detect common Whisper hallucination patterns.

    Args:
        text: The transcribed text to check.
        short_audio: If True, also filters single-word/short phrases that could
                     be real speech in longer recordings.
    """
    stripped = text.strip()
    if not stripped:
        return True
    lowered = stripped.lower()
    if lowered in _WHISPER_HALLUCINATION_ALWAYS:
        return True
    normalized = _BOUNDARY_PUNCTUATION_RE.sub("", lowered)
    if normalized and normalized != lowered and normalized in _WHISPER_HALLUCINATION_ALWAYS_NORMALIZED:
        return True
    if short_audio:
        if lowered in _WHISPER_HALLUCINATION_SHORT_ONLY or normalized in _WHISPER_HALLUCINATION_SHORT_NORMALIZED:
            return True
        words = lowered.split()
        if len(words) >= 3 and len(set(words)) == 1:
            return True
    return False
