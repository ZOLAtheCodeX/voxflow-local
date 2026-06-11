"""Whisper hallucination filter — behavioral parity with the Swift filter.

Token-based port of Sources/VoxFlowApp/Services/HallucinationFilter.swift.
The shared contract lives in Tests/Fixtures/hallucination_parity.json and is
enforced by TestHallucinationParity (Python) and the fixture-driven case in
HallucinationFilterTests (Swift). Change behavior by changing the fixture
first, then both implementations.

Layers (mirrors the Swift order):
1. Empty / whitespace-only -> filtered.
2. Whole string enclosed in []/()/** containing a noise cue -> filtered.
3. No alphanumeric tokens at all (music notes, ellipsis) -> filtered.
4. 1-2 tokens: greeting words always; filler words short-audio-only;
   greeting + target pair ("hello everyone") always.
5. Short audio: 3+ identical repeated tokens -> filtered.
6. <= 8 tokens: YouTube outro families. Thank-you family requires a
   watching/listening co-occurrence so real gratitude ("thank you for the
   coffee") passes; bare "thank you so much" is short-audio-only.
"""

from __future__ import annotations

import re

_ALWAYS_SINGLE = frozenset({"hello", "hi", "hey"})
_SHORT_ONLY_SINGLE = frozenset({"bye", "goodbye", "you", "thanks", "yeah", "yes", "okay", "ok"})
_GREETING_TARGETS = frozenset({"everyone", "everybody", "guys", "there"})
_NOISE_CUES = ("typing", "clack", "keyboard", "silence", "noise")

_SUBSCRIBE_PREFIXES = (
    ("subscribe", "to", "my", "channel"),
    ("subscribe", "to", "the", "channel"),
    ("subscribe", "for", "more"),
    ("please", "subscribe"),
    ("like", "and", "subscribe"),
    ("please", "like", "and", "subscribe"),
)

_OUTRO_EXACT = (
    ("i", "will", "see", "you", "in", "the", "next", "one"),
    ("i", "ll", "see", "you", "in", "the", "next", "one"),
    ("see", "you", "next", "time"),
)

# Mirrors Swift's CharacterSet.alphanumerics.inverted tokenization for the
# inputs Whisper actually emits (ASCII + common punctuation).
_TOKEN_RE = re.compile(r"[a-z0-9]+")

_ENCLOSURES = (("[", "]"), ("(", ")"), ("*", "*"))


def is_whisper_hallucination(text: str, short_audio: bool = True) -> bool:
    """Detect common Whisper hallucination patterns.

    Args:
        text: The transcribed text to check.
        short_audio: True when the source clip was < 3 s. Filler words and
            repeats that could be real speech in longer recordings are only
            filtered when this is True.
    """
    stripped = text.strip()
    if not stripped:
        return True

    for open_char, close_char in _ENCLOSURES:
        if len(stripped) >= 2 and stripped.startswith(open_char) and stripped.endswith(close_char):
            inner = stripped[1:-1].strip().lower()
            if any(cue in inner for cue in _NOISE_CUES):
                return True

    words = _TOKEN_RE.findall(stripped.lower())
    if not words:
        return True

    if len(words) <= 2:
        if all(w in _ALWAYS_SINGLE for w in words):
            return True
        if short_audio and all(w in _ALWAYS_SINGLE or w in _SHORT_ONLY_SINGLE for w in words):
            return True
        if short_audio and words == ["thank", "you"]:
            return True
        if len(words) == 2 and words[0] in _ALWAYS_SINGLE and words[1] in _GREETING_TARGETS:
            return True

    if short_audio and len(words) >= 3 and len(set(words)) == 1:
        return True

    if len(words) <= 8:
        if words[0] in ("thank", "thanks") and ("watching" in words or "listening" in words):
            return True
        if short_audio and words == ["thank", "you", "so", "much"]:
            return True
        for prefix in _SUBSCRIBE_PREFIXES:
            if tuple(words[: len(prefix)]) == prefix:
                return True
        if tuple(words) in _OUTRO_EXACT:
            return True

    return False
