"""Unit tests for PolishEngine."""

from __future__ import annotations

import sys
from pathlib import Path

# Insert the app package so we can import server functions directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import PolishEngine


class TestPolishEngineGuardrail:
    """R2.2 contract: _guardrail_triggered returns a reason string (truthy)
    or None (pass). Similarity is word-level (character-level punished
    legitimate restructuring); the length floor is 0.3 for >10-word inputs
    (0.4 for 6-10) because correct filler-removal routinely lands there; the
    concise tone is exempted down to 0.15 (shortening is its purpose)."""

    def test_empty_candidate_triggers_guardrail(self):
        assert PolishEngine._guardrail_triggered("original text", "") == "guardrail_empty"
        assert PolishEngine._guardrail_triggered("original text", "   ") == "guardrail_empty"

    def test_valid_polish_passes(self):
        original = "Hello world this is a test"
        candidate = "Hello world, this is a test."
        assert PolishEngine._guardrail_triggered(original, candidate) is None

    def test_low_similarity_triggers_guardrail(self):
        original = "The quick brown fox jumps over the lazy dog"
        candidate = "Lorem ipsum dolor sit amet consectetur adipiscing elit"
        assert PolishEngine._guardrail_triggered(original, candidate) == "guardrail_similarity"

    def test_short_length_ratio_triggers_guardrail(self):
        original = "one two three four five six seven eight nine ten"
        candidate = "one two"
        # 2/10 = 0.2 < 0.4 floor for 6-10 word inputs
        assert PolishEngine._guardrail_triggered(original, candidate) == "guardrail_length"

    def test_long_length_ratio_triggers_guardrail_for_long_input(self):
        original = "one two three four five six seven eight nine ten eleven"
        candidate = (
            "one two three four five six seven eight nine ten eleven "
            "twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one"
        )
        # 11 -> 21 words = ratio 1.9 > 1.8
        assert PolishEngine._guardrail_triggered(original, candidate) == "guardrail_length"

    def test_filler_heavy_condensation_passes(self):
        """The R2 headline false positive: correct filler removal produced
        ratios of 0.3-0.4 and char-similarity ~0.5, tripping the old 0.6
        floor / 0.55 char threshold on every filler-heavy dictation."""
        original = "um so basically i think we should kind of you know maybe consider rescheduling the meeting"
        candidate = "We should consider rescheduling the meeting."
        assert PolishEngine._guardrail_triggered(original, candidate) is None

    def test_concise_tone_exempts_aggressive_shortening(self):
        original = "um so basically i think we should kind of you know maybe just consider rescheduling the whole meeting"
        candidate = "Reschedule the meeting."
        # Trips for neutral (whichever floor catches it first); passes for
        # concise — both the similarity and length floors relax together.
        assert PolishEngine._guardrail_triggered(original, candidate) is not None
        assert PolishEngine._guardrail_triggered(original, candidate, tone="concise") is None

    def test_word_level_similarity_tolerates_restructuring(self):
        """Character-level SequenceMatcher punished word substitutions;
        word-level matching keeps shared vocabulary credit."""
        original = "i think we should send the quarterly report to the finance team tomorrow morning"
        candidate = "We should send the quarterly report to the finance team tomorrow morning."
        assert PolishEngine._guardrail_triggered(original, candidate) is None

    def test_short_input_skips_length_ratio(self):
        original = "send the report"
        candidate = "Please send the report today."
        assert PolishEngine._guardrail_triggered(original, candidate) is None

        original = "fix bug"
        candidate = "The weather is nice today and I like it."
        assert PolishEngine._guardrail_triggered(original, candidate) == "guardrail_similarity"

    def test_medium_input_wider_length_tolerance(self):
        original = "send the report to the team"
        candidate = "Please send the report to the team by end of day today."
        # 6 -> 12 words = ratio 2.0; <= 10 words allows up to 2.5
        assert PolishEngine._guardrail_triggered(original, candidate) is None

    def test_minor_typo_fix_passes(self):
        original = "Thsi is a tst"
        candidate = "This is a test"
        assert PolishEngine._guardrail_triggered(original, candidate) is None

    def test_empty_original_handled(self):
        assert PolishEngine._guardrail_triggered("", "some text") == "guardrail_similarity"
        assert PolishEngine._guardrail_triggered("", "") == "guardrail_empty"


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
        output, guardrail, _reason = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Restructure as memo with Issue/Analysis/Recommendation.",
        )
        assert output == memo_output
        assert guardrail is False

    def test_smart_action_echo_is_returned_verbatim_not_regex_fallback(self):
        engine = PolishEngine(backend=_StubBackend(self._ORIGINAL))
        output, guardrail, _reason = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Restructure as MECE bullet groups.",
        )
        assert output == self._ORIGINAL
        assert guardrail is False

    def test_smart_action_empty_candidate_still_falls_back_to_regex(self):
        engine = PolishEngine(backend=_StubBackend(""))
        output, guardrail, _reason = engine.polish(
            text=self._ORIGINAL,
            tone="neutral",
            system_prompt="Extract action items.",
        )
        assert output != ""
        assert guardrail is False

    def test_polish_path_still_applies_guardrail_when_no_system_prompt(self):
        divergent = "completely unrelated text about kayaking and weather."
        engine = PolishEngine(backend=_StubBackend(divergent))
        output, guardrail, _reason = engine.polish(text=self._ORIGINAL, tone="neutral")
        assert guardrail is True
        assert "kayaking" not in output
