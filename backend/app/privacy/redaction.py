"""Regex-based PII redaction for privacy preview.

Conservative over-redaction is intentional — false positives on long digit
runs (phone numbers, case numbers) get tagged as [ACCOUNT_NUMBER]. This is
acceptable because the redacted text is shown to the user for review before
any cloud round-trip; nothing leaves the device redacted-wrong-silently.
"""

from __future__ import annotations

import re

from nlp import normalize_whitespace


def redact_sensitive_text(text: str) -> str:
    redacted = text
    patterns: list[tuple[str, str]] = [
        (r"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b", "[EMAIL]"),
        (r"https?://[^\s,)>\"']+", "[URL]"),
        (r"\b(?:\+?\d{1,3}[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}\b", "[PHONE]"),
        (r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)", "[SSN]"),
        (r"\b(?:\d[ -]*?){13,19}\b", "[ACCOUNT_NUMBER]"),
        (r"\b\d{9,}\b", "[ID]"),
    ]
    for pattern, replacement in patterns:
        redacted = re.sub(pattern, replacement, redacted, flags=re.IGNORECASE)
    return normalize_whitespace(redacted)
