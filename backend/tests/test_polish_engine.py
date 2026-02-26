"""Unit tests for PolishEngine."""

from __future__ import annotations

import sys
from pathlib import Path

# Insert the app package so we can import server functions directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import PolishEngine


class TestPolishEngineGuardrail:
    def test_empty_candidate_triggers_guardrail(self):
        """Should return True if candidate is empty or whitespace."""
        assert PolishEngine._guardrail_triggered("original text", "") is True
        assert PolishEngine._guardrail_triggered("original text", "   ") is True

    def test_valid_polish_passes(self):
        """Should return False for similar text with minor changes."""
        original = "Hello world this is a test"
        candidate = "Hello world, this is a test."
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_low_similarity_triggers_guardrail(self):
        """Should return True if text is completely different."""
        original = "The quick brown fox jumps over the lazy dog"
        candidate = "Lorem ipsum dolor sit amet consectetur adipiscing elit"
        assert PolishEngine._guardrail_triggered(original, candidate) is True

    def test_short_length_ratio_triggers_guardrail(self):
        """Should return True if candidate is much shorter (< 0.6 ratio)."""
        original = "one two three four five six seven eight nine ten"
        candidate = "one two"
        # Length ratio: 2/10 = 0.2 < 0.6
        assert PolishEngine._guardrail_triggered(original, candidate) is True

    def test_long_length_ratio_triggers_guardrail(self):
        """Should return True if candidate is much longer (> 1.8 ratio)."""
        original = "one two"
        candidate = "one two three four five six seven eight nine ten"
        # Length ratio: 10/2 = 5.0 > 1.8
        assert PolishEngine._guardrail_triggered(original, candidate) is True

    def test_boundary_length_ratio_passes(self):
        """Test just within bounds to ensure exact boundary handling."""
        # Ratio 0.6 should pass (logic is < 0.6)
        original = "one two three four five"
        candidate = "one two three"
        # Length ratio: 3/5 = 0.6. Not < 0.6.
        # Similarity should be high enough (~0.72 > 0.55)
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_minor_typo_fix_passes(self):
        """Should return False (not triggered) for typo fixes."""
        original = "Thsi is a tst"
        candidate = "This is a test"
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_empty_original_handled(self):
        """Should handle empty original string gracefully."""
        # If original is empty, length is max(1, 0) = 1.
        original = ""
        candidate = "some text"
        # Length ratio: 2/1 = 2.0 > 1.8 -> True
        assert PolishEngine._guardrail_triggered(original, candidate) is True

        # Both empty -> Candidate empty check triggers first
        assert PolishEngine._guardrail_triggered("", "") is True
