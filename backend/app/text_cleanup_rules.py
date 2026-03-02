"""Text cleanup rule constants — ported from Swift TextCleanupRules.swift.

Pure data module: pre-compiled regex patterns for spoken punctuation,
filler removal, and tone transforms. No external dependencies beyond ``re``.
"""

from __future__ import annotations

import re

# ── Spoken punctuation ──────────────────────────────────────────────
# Order matters: "new paragraph" must match before "new line" (both start
# with "new"), and multi-word punctuation before single-word.

SPOKEN_PUNCTUATION: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\s+new paragraph\b\s*", re.IGNORECASE), "\n\n"),
    (re.compile(r"\s+new ?line\b\s*", re.IGNORECASE), "\n"),
    (re.compile(r"\s+period\b", re.IGNORECASE), "."),
    (re.compile(r"\s+full stop\b", re.IGNORECASE), "."),
    (re.compile(r"\s+comma\b", re.IGNORECASE), ","),
    (re.compile(r"\s+question mark\b", re.IGNORECASE), "?"),
    (re.compile(r"\s+exclamation (?:point|mark)\b", re.IGNORECASE), "!"),
    (re.compile(r"\s+colon\b", re.IGNORECASE), ":"),
    (re.compile(r"\s+semicolon\b", re.IGNORECASE), ";"),
    (re.compile(r"\bopen quote\s+", re.IGNORECASE), '"'),
    (re.compile(r"\s+close quote\b", re.IGNORECASE), '"'),
    (re.compile(r"\s+dash\b", re.IGNORECASE), " \u2014"),
    (re.compile(r"\s+hyphen\b", re.IGNORECASE), "-"),
]

# ── Filler words (always safe to remove) ────────────────────────────

ALWAYS_FILLERS: frozenset[str] = frozenset({
    "um", "umm", "uh", "uhh", "er", "err",
    "ah", "ahh", "hmm", "hm", "mm", "mmm", "mhm",
})

# ── Phrase fillers (multi-word, regex) ──────────────────────────────

PHRASE_FILLERS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\byou know\b", re.IGNORECASE), ""),
    (re.compile(r"\bI mean\b", re.IGNORECASE), ""),
    (re.compile(r"\bkind of\b", re.IGNORECASE), ""),
    (re.compile(r"\bsort of\b", re.IGNORECASE), ""),
    (re.compile(r"\bokay so\b", re.IGNORECASE), ""),
]

# ── Tone: concise ───────────────────────────────────────────────────

HEDGING_PHRASES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bI think maybe\b", re.IGNORECASE), ""),
    (re.compile(r"\bit seems like\b", re.IGNORECASE), ""),
    (re.compile(r"\bin my opinion\b", re.IGNORECASE), ""),
    (re.compile(r"\bI feel like\b", re.IGNORECASE), ""),
    (re.compile(r"\bI guess\b", re.IGNORECASE), ""),
    (re.compile(r"\bto be honest\b", re.IGNORECASE), ""),
]

SOFTENERS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bjust\b", re.IGNORECASE), ""),
    (re.compile(r"\breally\b", re.IGNORECASE), ""),
    (re.compile(r"\bvery\b", re.IGNORECASE), ""),
    (re.compile(r"\bquite\b", re.IGNORECASE), ""),
    (re.compile(r"\ba bit\b", re.IGNORECASE), ""),
]

# ── Tone: formal ────────────────────────────────────────────────────
# Swift has 70 entries (35 pairs for ' and \u2019). We consolidate to 35
# using [\u2019'] character class — same match behavior, half the entries.

CONTRACTIONS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bdon[\u2019']t\b", re.IGNORECASE), "do not"),
    (re.compile(r"\bcan[\u2019']t\b", re.IGNORECASE), "cannot"),
    (re.compile(r"\bwon[\u2019']t\b", re.IGNORECASE), "will not"),
    (re.compile(r"\bshouldn[\u2019']t\b", re.IGNORECASE), "should not"),
    (re.compile(r"\bwouldn[\u2019']t\b", re.IGNORECASE), "would not"),
    (re.compile(r"\bcouldn[\u2019']t\b", re.IGNORECASE), "could not"),
    (re.compile(r"\bisn[\u2019']t\b", re.IGNORECASE), "is not"),
    (re.compile(r"\baren[\u2019']t\b", re.IGNORECASE), "are not"),
    (re.compile(r"\bwasn[\u2019']t\b", re.IGNORECASE), "was not"),
    (re.compile(r"\bweren[\u2019']t\b", re.IGNORECASE), "were not"),
    (re.compile(r"\bhasn[\u2019']t\b", re.IGNORECASE), "has not"),
    (re.compile(r"\bhaven[\u2019']t\b", re.IGNORECASE), "have not"),
    (re.compile(r"\bhadn[\u2019']t\b", re.IGNORECASE), "had not"),
    (re.compile(r"\bdoesn[\u2019']t\b", re.IGNORECASE), "does not"),
    (re.compile(r"\bdidn[\u2019']t\b", re.IGNORECASE), "did not"),
    (re.compile(r"\bI[\u2019']m\b", re.IGNORECASE), "I am"),
    (re.compile(r"\bI[\u2019']ve\b", re.IGNORECASE), "I have"),
    (re.compile(r"\bI[\u2019']ll\b", re.IGNORECASE), "I will"),
    (re.compile(r"\bI[\u2019']d\b", re.IGNORECASE), "I would"),
    (re.compile(r"\bwe[\u2019']re\b", re.IGNORECASE), "we are"),
    (re.compile(r"\bwe[\u2019']ve\b", re.IGNORECASE), "we have"),
    (re.compile(r"\bwe[\u2019']ll\b", re.IGNORECASE), "we will"),
    (re.compile(r"\bthey[\u2019']re\b", re.IGNORECASE), "they are"),
    (re.compile(r"\bthey[\u2019']ve\b", re.IGNORECASE), "they have"),
    (re.compile(r"\bthey[\u2019']ll\b", re.IGNORECASE), "they will"),
    (re.compile(r"\byou[\u2019']re\b", re.IGNORECASE), "you are"),
    (re.compile(r"\byou[\u2019']ve\b", re.IGNORECASE), "you have"),
    (re.compile(r"\byou[\u2019']ll\b", re.IGNORECASE), "you will"),
    (re.compile(r"\bit[\u2019']s\b", re.IGNORECASE), "it is"),
    (re.compile(r"\bthat[\u2019']s\b", re.IGNORECASE), "that is"),
    (re.compile(r"\bwho[\u2019']s\b", re.IGNORECASE), "who is"),
    (re.compile(r"\bwhat[\u2019']s\b", re.IGNORECASE), "what is"),
    (re.compile(r"\bthere[\u2019']s\b", re.IGNORECASE), "there is"),
    (re.compile(r"\bhere[\u2019']s\b", re.IGNORECASE), "here is"),
    (re.compile(r"\blet[\u2019']s\b", re.IGNORECASE), "let us"),
]

CASUAL_INTERJECTIONS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bokay so\b", re.IGNORECASE), ""),
    (re.compile(r"\balright\b", re.IGNORECASE), ""),
    (re.compile(r"\bhey\b", re.IGNORECASE), ""),
    (re.compile(r"\byeah\b", re.IGNORECASE), "yes"),
    (re.compile(r"\bnope\b", re.IGNORECASE), "no"),
]
