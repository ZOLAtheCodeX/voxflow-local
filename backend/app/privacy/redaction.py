"""Regex-based PII redaction for privacy preview.

Phase 5.2 tightens the credit-card pattern with a Luhn checksum so legitimate
13-19 digit runs (long phone numbers with country code, legal case numbers,
medical record IDs) no longer get falsely tagged as [ACCOUNT_NUMBER].

Other patterns remain intentionally conservative — the redacted text is
shown to the user for review before any cloud round-trip; nothing leaves
the device redacted-wrong-silently.
"""

from __future__ import annotations

import re

from nlp import normalize_whitespace

# Card number candidates: 13-19 digits possibly separated by spaces or dashes.
# Compiled once at module load.
_CARD_CANDIDATE_RE = re.compile(r"\b(?:\d[ -]*?){13,19}\b")


def _luhn_valid(digits: str) -> bool:
    """Luhn (mod 10) checksum used to validate credit-card numbers.

    Takes a string of ASCII digits (caller must strip separators). Returns
    True when the digits form a Luhn-valid number, False otherwise. Empty
    or sub-13-digit input also returns False.
    """
    if not digits or not digits.isdigit() or not 13 <= len(digits) <= 19:
        return False
    total = 0
    # Iterate right-to-left, doubling every second digit. Sum digits of
    # any product greater than 9 (e.g., 14 -> 1 + 4 = 5).
    for i, ch in enumerate(reversed(digits)):
        d = ord(ch) - 48
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def _redact_cards(text: str) -> str:
    """Replace Luhn-valid 13-19 digit runs with [ACCOUNT_NUMBER].

    Runs that match the digit-length window but fail Luhn (long phone
    numbers, case numbers, etc.) are left unchanged so downstream patterns
    like [PHONE] or [ID] can still catch them.
    """

    def _maybe_redact(match: re.Match[str]) -> str:
        raw = match.group(0)
        digits = re.sub(r"[ -]", "", raw)
        return "[ACCOUNT_NUMBER]" if _luhn_valid(digits) else raw

    return _CARD_CANDIDATE_RE.sub(_maybe_redact, text)


def redact_sensitive_text(text: str) -> str:
    """Replace common PII patterns with bracketed placeholders.

    Order matters — credit-card detection runs first (with Luhn validation)
    so a valid card number is not double-replaced by the catch-all 9+ digit
    [ID] pattern. Other patterns are independent and case-insensitive.
    """
    redacted = _redact_cards(text)

    other_patterns: list[tuple[str, str]] = [
        (r"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b", "[EMAIL]"),
        (r"https?://[^\s,)>\"']+", "[URL]"),
        (r"\b(?:\+?\d{1,3}[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b", "[PHONE]"),
        (r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)", "[SSN]"),
        (r"\b\d{9,}\b", "[ID]"),
    ]
    for pattern, replacement in other_patterns:
        redacted = re.sub(pattern, replacement, redacted, flags=re.IGNORECASE)
    return normalize_whitespace(redacted)
