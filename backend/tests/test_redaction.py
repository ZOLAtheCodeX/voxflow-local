"""Tests for privacy.redaction — credit-card Luhn validation + PII redaction."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from privacy.redaction import _luhn_valid, redact_sensitive_text


class TestLuhnValid:
    """Phase 5.2: Luhn checksum guards the credit-card redaction."""

    def test_known_valid_visa(self) -> None:
        # 4111 1111 1111 1111 is the canonical Visa test card; valid Luhn.
        assert _luhn_valid("4111111111111111") is True

    def test_known_valid_mastercard(self) -> None:
        # 5555 5555 5555 4444 — canonical MC test card.
        assert _luhn_valid("5555555555554444") is True

    def test_known_valid_amex_15_digits(self) -> None:
        # 3782 822463 10005 — canonical Amex test card (15 digits).
        assert _luhn_valid("378282246310005") is True

    def test_invalid_card_returns_false(self) -> None:
        # Same digits as Visa test card but last digit incremented.
        assert _luhn_valid("4111111111111112") is False

    def test_phone_number_length_invalid_luhn(self) -> None:
        # A real-looking 13-digit phone with country code that happens to
        # be in the length window but fails Luhn.
        assert _luhn_valid("1234567890123") is False

    def test_below_min_length_returns_false(self) -> None:
        assert _luhn_valid("4111") is False
        assert _luhn_valid("411111111111") is False  # 12 digits

    def test_above_max_length_returns_false(self) -> None:
        assert _luhn_valid("12345678901234567890") is False  # 20 digits

    def test_non_digit_input_returns_false(self) -> None:
        assert _luhn_valid("4111-1111-1111-1111") is False
        assert _luhn_valid("") is False


class TestRedactSensitiveText:
    """Phase 5.2: credit cards now require Luhn; phones/IDs still caught."""

    def test_valid_card_is_redacted(self) -> None:
        out = redact_sensitive_text("Charge 4111-1111-1111-1111 today.")
        assert "[ACCOUNT_NUMBER]" in out
        assert "4111" not in out

    def test_invalid_card_length_run_is_not_card_redacted(self) -> None:
        # 13-19 digit run that fails Luhn — the [ACCOUNT_NUMBER] pattern
        # must skip. Downstream patterns ([PHONE] catches phone-shaped
        # runs first, then [ID] for the catch-all >=9 digit case) still
        # redact the value; the key invariant is that the value doesn't
        # leak through and isn't mis-tagged as [ACCOUNT_NUMBER].
        out = redact_sensitive_text("ID 1234567890123 in record.")
        assert "[ACCOUNT_NUMBER]" not in out
        assert "1234567890123" not in out
        assert "[PHONE]" in out or "[ID]" in out

    def test_phone_number_not_account_number(self) -> None:
        out = redact_sensitive_text("Call me at +1 (415) 555-2671 anytime.")
        # [PHONE] pattern catches this; Luhn-failing card pattern doesn't.
        assert "[PHONE]" in out
        assert "[ACCOUNT_NUMBER]" not in out

    def test_email_redaction(self) -> None:
        out = redact_sensitive_text("Reply to bob@example.com please.")
        assert "[EMAIL]" in out
        assert "bob@example.com" not in out

    def test_ssn_redaction(self) -> None:
        out = redact_sensitive_text("SSN: 123-45-6789 verified.")
        assert "[SSN]" in out

    def test_url_redaction(self) -> None:
        out = redact_sensitive_text("See https://example.com/docs for details.")
        assert "[URL]" in out

    def test_card_and_email_together(self) -> None:
        out = redact_sensitive_text(
            "Send receipt to bob@example.com for card 4111111111111111."
        )
        assert "[EMAIL]" in out
        assert "[ACCOUNT_NUMBER]" in out
