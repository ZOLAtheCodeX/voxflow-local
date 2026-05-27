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

    def test_long_length_ratio_triggers_guardrail_for_long_input(self):
        """Should return True if candidate is much longer for inputs > 10 words."""
        original = "one two three four five six seven eight nine ten eleven"
        candidate = (
            "one two three four five six seven eight nine ten eleven "
            "twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one"
        )
        # 11 words -> 21 words = ratio 1.9 > 1.8
        assert PolishEngine._guardrail_triggered(original, candidate) is True

    def test_short_input_skips_length_ratio(self):
        """Short inputs (<= 5 words) should skip length ratio check entirely."""
        # 3-word input expanding to 6 words — ratio 2.0 would trigger old guardrail,
        # but short inputs are exempt from length ratio
        original = "send the report"
        candidate = "Please send the report today."
        assert PolishEngine._guardrail_triggered(original, candidate) is False

        # Short input but completely different content — similarity still catches it
        original = "fix bug"
        candidate = "The weather is nice today and I like it."
        assert PolishEngine._guardrail_triggered(original, candidate) is True

    def test_medium_input_wider_length_tolerance(self):
        """Inputs 6-10 words get wider tolerance (max ratio 2.5 instead of 1.8)."""
        original = "send the report to the team"
        candidate = "Please send the report to the team by end of day today."
        # 6 words -> 12 words = ratio 2.0. Under old rules: > 1.8 = triggered.
        # Under new rules: <= 10 words, max ratio 2.5, so 2.0 passes.
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_boundary_length_ratio_passes(self):
        """Test just within bounds to ensure exact boundary handling."""
        # Ratio 0.6 should pass (logic is < 0.6)
        original = "one two three four five six"
        candidate = "one two three four"
        # Length ratio: 4/6 = 0.67. Not < 0.6.
        # Similarity should be high enough
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_minor_typo_fix_passes(self):
        """Should return False (not triggered) for typo fixes."""
        original = "Thsi is a tst"
        candidate = "This is a test"
        assert PolishEngine._guardrail_triggered(original, candidate) is False

    def test_empty_original_handled(self):
        """Should handle empty original string gracefully."""
        # Empty original = 1 word (max(1,0)), so <= 5 words — length ratio skipped.
        # But similarity check still catches completely different content.
        original = ""
        candidate = "some text"
        # similarity between "" and "some text" is 0.0 < 0.55 -> True
        assert PolishEngine._guardrail_triggered(original, candidate) is True

        # Both empty -> Candidate empty check triggers first
        assert PolishEngine._guardrail_triggered("", "") is True


class TestPolishEngineEchoDetection:
    def test_exact_echo(self):
        assert PolishEngine._is_echo("hello world", "hello world") is True

    def test_echo_with_punctuation_diff(self):
        assert PolishEngine._is_echo("hello world", "Hello world.") is True

    def test_echo_with_case_diff(self):
        assert PolishEngine._is_echo("HELLO WORLD", "hello world") is True

    def test_not_echo(self):
        assert PolishEngine._is_echo("hello world", "greetings everyone") is False

    def test_minor_edit_not_echo(self):
        assert PolishEngine._is_echo("send the report", "Please send the report.") is False


class _StubBackend:
    """Minimal backend that returns whatever its constructor was given."""
    name = "stub"

    def __init__(self, response: str = ""):
        self._response = response

    def polish(self, text: str, tone: str, system_prompt: str | None = None) -> str:
        return self._response


class TestPolishEngineSmartActionBypass:
    """Smart-action calls (system_prompt supplied) bypass the polish
    guardrail + echo checks. Structural transformations (memo, MECE,
    steel-man, Pyramid) intentionally diverge from input — the polish
    guardrail's similarity + length-ratio thresholds would otherwise
    silently substitute regex output for legitimate LLM transformations.
    """

    _ORIGINAL = "we have a question and need to decide a path."

    def test_smart_action_low_similarity_output_is_returned_verbatim(self):
        memo_output = (
            "# Issue\nWhich path forward?\n\n"
            "# Analysis\nTwo options have been raised.\n\n"
            "# Recommendation\nProceed with option A."
        )
        engine = PolishEngine(backend=_StubBackend(memo_output))
        output, guardrail = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Restructure as memo with Issue/Analysis/Recommendation.",
        )
        assert output == memo_output
        assert guardrail is False

    def test_smart_action_echo_is_returned_verbatim_not_regex_fallback(self):
        engine = PolishEngine(backend=_StubBackend(self._ORIGINAL))
        output, guardrail = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Restructure as MECE bullet groups.",
        )
        assert output == self._ORIGINAL
        assert guardrail is False

    def test_smart_action_empty_candidate_still_falls_back_to_regex(self):
        engine = PolishEngine(backend=_StubBackend(""))
        output, guardrail = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Extract action items.",
        )
        assert output != ""
        assert guardrail is False

    def test_polish_path_still_applies_guardrail_when_no_system_prompt(self):
        divergent = "completely unrelated text about kayaking and weather."
        engine = PolishEngine(backend=_StubBackend(divergent))
        output, guardrail = engine.polish(text=self._ORIGINAL, tone="neutral")
        assert guardrail is True
        assert "kayaking" not in output
