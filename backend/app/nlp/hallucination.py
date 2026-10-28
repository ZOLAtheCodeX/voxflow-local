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
4. 1-2 tokens, SHORT AUDIO ONLY (session 29): greeting/filler words and
   greeting + target pairs ("hello everyone"). On long audio a user may be
   dictating a real greeting line; the 1-2 word long-noise ghost is the
   coverage crush's job (TranscriptionConfidence / _estimate_confidence).
5. Short audio: 3+ identical repeated tokens -> filtered.
6. <= 8 tokens: YouTube outro families. Thank-you family requires a
   watching/listening co-occurrence so real gratitude ("thank you for the
   coffee") passes; bare "thank you so much" is short-audio-only. On LONG
   audio the thank-you outro must be PURE outro vocabulary — an outside
   word ("pitch", "kids") proves a real sentence (session 29).
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

# Words a pure YouTube-outro ghost is made of — the long-audio thank-you
# filter fires only when EVERY token is from this set.
_OUTRO_VOCABULARY = frozenset({
    "thank", "thanks", "you", "so", "much", "for", "watching",
    "listening", "everyone", "everybody", "guys", "all",
})

# Mirrors Swift's CharacterSet.alphanumerics.inverted tokenization for the
# inputs Whisper actually emits (ASCII + common punctuation).
_TOKEN_RE = re.compile(r"[a-z0-9]+")

_ENCLOSURES = (("[", "]"), ("(", ")"), ("*", "*"))

# Words Whisper writes inside a sound annotation such as "(water rushing)" or
# "*typing*". A parenthetical or asterisk group is stripped only when EVERY word
# is in this set, so a dictated aside that merely mentions one survives.
# Mirrors soundAnnotationWords in HallucinationFilter.swift.
_SOUND_ANNOTATION_WORDS = frozenset({
    "ambient", "applause", "background", "barking", "beep", "beeping", "beeps",
    "birds", "blank_audio", "blowing", "breathing", "buzzing", "chirping", "chuckles",
    "chuckling", "clack", "clacking", "clapping", "click", "clicking", "clicks",
    "cough", "coughing", "coughs", "crowd", "door", "engine", "footsteps", "gasps",
    "humming", "inaudible", "keyboard", "laughing", "laughs", "laughter", "mumbling",
    "music", "noise", "noises", "phone", "playing", "pop", "rain", "ringing",
    "running", "rushing", "sighs", "silence", "sniffs", "sound", "sounds", "static",
    "thunder", "traffic", "typing", "water", "whispering", "wind",
})

_SQUARE_GROUP_RE = re.compile(r"\[[^\[\]]*\]")
_ANNOTATION_GROUP_RES = (re.compile(r"\(([^()]*)\)"), re.compile(r"\*([^*]*)\*"))
_SPACE_RUN_RE = re.compile(r"\s+")
_SPACE_BEFORE_PUNCT_RE = re.compile(r"\s+([.,;:!?])")


# Sound words that are an annotation even alone ("(laughter)", "*typing*").
# Everyday words like "static", "running" or "water" count only beside another
# sound word, so "the (static) variable" and "the *running* total" survive.
# Mirrors singleSoundAnnotationWords in HallucinationFilter.swift.
_SINGLE_SOUND_ANNOTATION_WORDS = frozenset({
    "applause", "barking", "beeping", "blank_audio", "breathing", "buzzing", "chirping",
    "chuckles", "chuckling", "clacking", "clapping", "clicking", "coughing", "coughs",
    "footsteps", "gasps", "humming", "inaudible", "laughing", "laughs", "laughter",
    "mumbling", "music", "noise", "noises", "ringing", "sighs", "silence", "sniffs",
    "typing", "whispering",
})


def _is_sound_annotation(inner: str) -> bool:
    words = [w for w in re.split(r"[ -]", inner.lower()) if w]
    if not 1 <= len(words) <= 4:
        return False
    if len(words) == 1:
        return words[0] in _SINGLE_SOUND_ANNOTATION_WORDS
    return all(w in _SOUND_ANNOTATION_WORDS for w in words)


def strip_non_speech_annotations(text: str) -> str:
    """Remove Whisper's non-speech annotations so they never reach a transcript.

    Strips every square-bracket group ("[BLANK_AUDIO]", "[Silence]"), stray
    square brackets ("[ [" runs), and parenthetical or asterisk groups made only
    of sound words. Dictated speech never contains square brackets. Text with
    nothing to strip is returned trimmed and otherwise untouched. Mirrors
    HallucinationFilter.stripNonSpeechAnnotations; the shared contract is
    Tests/Fixtures/annotation_strip_parity.json.
    """
    result = text
    removed = False
    while True:
        result, count = _SQUARE_GROUP_RE.subn(" ", result)
        if not count:
            break
        removed = True

    def _drop(match: re.Match[str]) -> str:
        nonlocal removed
        if not _is_sound_annotation(match.group(1)):
            return match.group(0)
        removed = True
        return " "

    for pattern in _ANNOTATION_GROUP_RES:
        result = pattern.sub(_drop, result)
    if "[" in result or "]" in result:
        result = result.replace("[", "").replace("]", "")
        removed = True
    if not removed:
        return text.strip()
    result = _SPACE_RUN_RE.sub(" ", result)
    result = _SPACE_BEFORE_PUNCT_RE.sub(r"\1", result)
    return result.strip()


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
            if inner == "blank_audio":
                return True
            if any(cue in inner for cue in _NOISE_CUES):
                return True

    words = _TOKEN_RE.findall(stripped.lower())
    if not words:
        return True

    if short_audio and len(words) <= 2:
        if all(w in _ALWAYS_SINGLE or w in _SHORT_ONLY_SINGLE for w in words):
            return True
        if words == ["thank", "you"]:
            return True
        if len(words) == 2 and words[0] in _ALWAYS_SINGLE and words[1] in _GREETING_TARGETS:
            return True

    if short_audio and len(words) >= 3 and len(set(words)) == 1:
        return True

    if len(words) <= 8:
        if (
            words[0] in ("thank", "thanks")
            and ("watching" in words or "listening" in words)
            and (short_audio or all(w in _OUTRO_VOCABULARY for w in words))
        ):
            return True
        if short_audio and words == ["thank", "you", "so", "much"]:
            return True
        for prefix in _SUBSCRIBE_PREFIXES:
            if tuple(words[: len(prefix)]) == prefix:
                return True
        if tuple(words) in _OUTRO_EXACT:
            return True

    return False
