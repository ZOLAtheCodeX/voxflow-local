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


class TestGuardrailDigitPreservation:
    """Digit runs in the input must survive polish VERBATIM. The e2b
    default model converts digits to words under tone=formal ("client 42"
    -> "client forty-two") and no prompt wording reliably stops it
    (2026-06-12: three attempts, failures moved between golden runs).
    Hard invariants live in the guardrail, not the prompt: digit loss
    falls to the regex floor, which preserves the original text.
    """

    def test_digit_loss_trips_guardrail(self):
        original = "please send 3 follow ups to client 42 before 10 30 am tomorrow"
        candidate = "Please send three follow-ups to client forty-two before ten thirty ante meridiem tomorrow."
        assert PolishEngine._guardrail_triggered(original, candidate, "formal") == "guardrail_digits"

    def test_digits_reformatted_as_time_do_not_trip(self):
        # "10 30" -> "10:30" keeps both runs as substrings; punctuation
        # between digits is a legitimate polish, not a loss.
        assert PolishEngine._guardrail_triggered(
            "meet at 10 30 am", "Meet at 10:30 AM.", "neutral"
        ) is None

    def test_short_input_digit_loss_still_trips(self):
        # The <=5-word early exit must not bypass digit preservation.
        assert PolishEngine._guardrail_triggered(
            "call client 42", "Call client forty-two.", "neutral"
        ) == "guardrail_digits"

    def test_words_to_digits_does_not_trip(self):
        # The model adding digits where the input had words loses nothing.
        assert PolishEngine._guardrail_triggered(
            "the budget is five hundred dollars and that is final",
            "The budget is 500 dollars, and that is final.",
            "formal",
        ) is None

    def test_polish_falls_to_regex_floor_with_digits_intact(self):
        engine = PolishEngine(
            backend=_StubBackend("Please send three follow-ups to client forty-two.")
        )
        output, guardrail, _reason = engine.polish(
            "please send 3 follow ups to client 42", "formal"
        )
        assert guardrail is True
        assert "3" in output and "42" in output


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


# ── Chain execution (R3.3/R3.4) ──────────────────────────────────────

class _ChainBackend:
    """Scripted backend for chain tests; records what it was asked."""

    def __init__(self, name: str, response: str) -> None:
        self.name = name
        self.response = response
        self.received: list[str] = []

    def polish(self, text, tone, system_prompt=None, model=None, timeout=None):
        self.received.append(text)
        return self.response


def _spec(provider_id: str, *, cloud: bool = False, model: str | None = None):
    from engines.provider_registry import ProviderSpec

    return ProviderSpec(
        id=provider_id,
        kind="anthropic" if cloud else "ollama",
        base_url=None if cloud else "http://localhost:11434",
        model=model,
    )


class TestPolishEngineChains:
    def test_first_available_provider_serves_with_provenance(self):
        first = _ChainBackend("openai_compat", "This is the polished sentence we expected to receive.")
        second = _ChainBackend("ollama", "should not be reached")
        engine = PolishEngine(chain=[
            (_spec("lmstudio", model="qwen3:8b"), first),
            (_spec("ollama"), second),
        ])
        out = engine.run("uh this is the polished sentence we expected to receive", "neutral")
        assert out.text == "This is the polished sentence we expected to receive."
        assert out.served_by == "lmstudio"
        assert out.model_id == "qwen3:8b"
        assert out.fallback_depth == 0
        assert out.degraded_reason is None
        assert second.received == []

    def test_unavailable_provider_falls_to_next_in_chain(self):
        dead = _ChainBackend("anthropic", "")
        alive = _ChainBackend("ollama", "The meeting moved to Thursday afternoon for everyone.")
        engine = PolishEngine(chain=[
            (_spec("claude", cloud=True), dead),
            (_spec("ollama"), alive),
        ])
        out = engine.run("uh the meeting moved to thursday afternoon for everyone", "neutral")
        assert out.served_by == "ollama"
        assert out.fallback_depth == 1
        assert out.degraded_reason is None

    def test_exhausted_chain_hits_regex_floor(self):
        engine = PolishEngine(chain=[
            (_spec("a"), _ChainBackend("ollama", "")),
            (_spec("b"), _ChainBackend("ollama", "")),
        ])
        out = engine.run("send the report to the team", "neutral")
        assert out.text  # regex floor always produces usable text
        assert out.served_by == "regex"
        assert out.degraded_reason == "backend_unavailable"
        assert out.fallback_depth == 2

    def test_cloud_provider_receives_redacted_text(self):
        """R3.3 privacy posture: payloads leaving localhost pass through
        redact_sensitive_text unconditionally."""
        cloud = _ChainBackend("anthropic", "Call me back regarding the account, thanks a lot.")
        engine = PolishEngine(chain=[(_spec("claude", cloud=True), cloud)])
        engine.run("call me back at 555-867-5309 about the account thanks a lot", "neutral")
        assert len(cloud.received) == 1
        assert "555-867-5309" not in cloud.received[0]

    def test_local_provider_receives_raw_text(self):
        local = _ChainBackend("ollama", "Call me back at 555-867-5309 about the account, thanks.")
        engine = PolishEngine(chain=[(_spec("ollama"), local)])
        engine.run("call me back at 555-867-5309 about the account thanks", "neutral")
        assert "555-867-5309" in local.received[0]

    def test_guardrail_trip_goes_to_regex_floor_not_next_provider(self):
        """Chains handle AVAILABILITY; the guardrail handles QUALITY. A
        rejected candidate falls to the regex floor — retrying a different
        model on a quality failure would double latency unpredictably."""
        bad = _ChainBackend("ollama", "completely unrelated text about kayaking and the weather today")
        never = _ChainBackend("ollama", "should not be reached")
        engine = PolishEngine(chain=[
            (_spec("a"), bad),
            (_spec("b"), never),
        ])
        out = engine.run("send the quarterly report to the finance team by friday morning", "neutral")
        assert out.served_by == "regex"
        assert out.guardrail_triggered is True
        assert out.degraded_reason == "guardrail_similarity"
        assert never.received == []

    def test_single_backend_compat_construction_still_works(self):
        backend = _ChainBackend("ollama", "Hello there, this is a polished test sentence.")
        engine = PolishEngine(backend=backend)
        out = engine.run("uh hello there this is a polished test sentence", "neutral")
        assert out.served_by == "ollama"
        assert out.fallback_depth == 0

