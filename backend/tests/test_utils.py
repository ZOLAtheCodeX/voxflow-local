"""Unit tests for pure utility functions in server.py."""

from __future__ import annotations

import sys
from pathlib import Path

# Insert the app package so we can import server functions directly.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import (
    apply_tone,
    coerce_string_list,
    extract_json_object,
    is_placeholder_text,
    is_whisper_hallucination,
    light_cleanup,
    normalize_provider_mode,
    normalize_stt_backend,
    normalize_whitespace,
    redact_sensitive_text,
    split_sentences,
)


# ── normalize_whitespace ─────────────────────────────────────────────

class TestNormalizeWhitespace:
    def test_collapses_multiple_spaces(self):
        assert normalize_whitespace("hello   world") == "hello world"

    def test_strips_leading_trailing(self):
        assert normalize_whitespace("  hi there  ") == "hi there"

    def test_empty_string(self):
        assert normalize_whitespace("") == ""

    def test_tabs_and_newlines(self):
        assert normalize_whitespace("hello\t\nworld") == "hello world"


# ── redact_sensitive_text ─────────────────────────────────────────────

class TestRedactSensitiveText:
    def test_redacts_email(self):
        result = redact_sensitive_text("Contact alice@example.com for info")
        assert "[EMAIL]" in result
        assert "alice@example.com" not in result

    def test_redacts_url(self):
        result = redact_sensitive_text("Visit https://example.com/path")
        assert "[URL]" in result
        assert "https://example.com" not in result

    def test_redacts_phone(self):
        result = redact_sensitive_text("Call 206-555-1234 today")
        assert "[PHONE]" in result
        assert "206-555-1234" not in result

    def test_redacts_ssn(self):
        result = redact_sensitive_text("SSN is 123-45-6789")
        assert "[SSN]" in result
        assert "123-45-6789" not in result

    def test_redacts_long_id(self):
        result = redact_sensitive_text("ID number 123456789")
        assert "[ID]" in result

    def test_preserves_normal_text(self):
        text = "Just a normal sentence with no PII"
        result = redact_sensitive_text(text)
        assert result == text


# ── apply_tone ────────────────────────────────────────────────────────

class TestApplyTone:
    def test_neutral_returns_normalized(self):
        assert apply_tone("  hello  world  ", "neutral") == "hello world"

    def test_concise_removes_filler_words(self):
        result = apply_tone("please just do this really quickly", "concise")
        assert "just" not in result.lower().split()
        assert "really" not in result.lower().split()

    def test_concise_removes_hedging(self):
        result = apply_tone("I think maybe we should proceed.", "concise")
        assert "I think maybe" not in result

    def test_concise_removes_quite(self):
        result = apply_tone("It was quite good.", "concise")
        assert "quite" not in result.lower().split()

    def test_formal_adds_period(self):
        result = apply_tone("hello world", "formal")
        assert result.endswith(".")

    def test_formal_expands_contractions(self):
        result = apply_tone("I don't think so.", "formal")
        assert "do not" in result

    def test_formal_removes_casual_interjections(self):
        result = apply_tone("Okay so the plan works.", "formal")
        assert "okay so" not in result.lower()

    def test_formal_yeah_to_yes(self):
        result = apply_tone("Yeah that works.", "formal")
        assert "yeah" not in result.lower()
        assert "yes" in result.lower()

    def test_formal_preserves_existing_punctuation(self):
        result = apply_tone("Hello world!", "formal")
        assert result.endswith("!")
        assert not result.endswith(".!")

    def test_friendly_adds_exclamation(self):
        result = apply_tone("great job", "friendly")
        assert result.endswith("!")

    def test_unknown_tone_returns_normalized(self):
        assert apply_tone("  test  input  ", "unknown") == "test input"


# ── light_cleanup ─────────────────────────────────────────────────────

class TestLightCleanup:
    def test_removes_fillers(self):
        result = light_cleanup("um I think uh it works")
        assert "um" not in result.lower().split()
        assert "uh" not in result.lower().split()

    def test_capitalizes_first_letter(self):
        result = light_cleanup("hello world")
        assert result[0] == "H"

    def test_adds_period_if_missing(self):
        result = light_cleanup("hello world")
        assert result.endswith(".")

    def test_preserves_existing_punctuation(self):
        result = light_cleanup("Hello world!")
        assert result.endswith("!")

    def test_spoken_punctuation(self):
        result = light_cleanup("hello world period")
        assert result == "Hello world."

    def test_repeated_words(self):
        result = light_cleanup("I want to to go")
        assert "to to" not in result
        assert "want to go" in result

    def test_phrase_fillers(self):
        result = light_cleanup("it was you know really good")
        assert "you know" not in result

    def test_hmm_removal(self):
        result = light_cleanup("hmm let me think")
        assert "hmm" not in result.lower().split()


# ── normalize_provider_mode ───────────────────────────────────────────

class TestNormalizeProviderMode:
    def test_private_api_variants(self):
        assert normalize_provider_mode("privateapi") == "private_api"
        assert normalize_provider_mode("private_api") == "private_api"
        assert normalize_provider_mode("private-api") == "private_api"
        assert normalize_provider_mode("  PrivateAPI  ") == "private_api"

    def test_default_to_local_only(self):
        assert normalize_provider_mode("localOnly") == "local_only"
        assert normalize_provider_mode("anything") == "local_only"
        assert normalize_provider_mode("") == "local_only"


# ── normalize_stt_backend ────────────────────────────────────────────

class TestNormalizeSttBackend:
    def test_valid_backends(self):
        assert normalize_stt_backend("whisper") == "whisper"
        assert normalize_stt_backend("openai") == "openai"

    def test_default_to_whisper(self):
        assert normalize_stt_backend("unknown") == "whisper"
        assert normalize_stt_backend("") == "whisper"


# ── extract_json_object ──────────────────────────────────────────────

class TestExtractJsonObject:
    def test_plain_json(self):
        result = extract_json_object('{"key": "value"}')
        assert result == {"key": "value"}

    def test_markdown_wrapped(self):
        result = extract_json_object('```json\n{"key": "value"}\n```')
        assert result == {"key": "value"}

    def test_invalid_json(self):
        result = extract_json_object("not json at all")
        assert result == {}

    def test_array_returns_empty(self):
        result = extract_json_object('[1, 2, 3]')
        assert result == {}

    def test_empty_string(self):
        result = extract_json_object("")
        assert result == {}

    def test_json_with_surrounding_text(self):
        result = extract_json_object('Here is the result: {"a": 1} done.')
        assert result == {"a": 1}

    def test_unbalanced_braces(self):
        # Case from rationale: missing closing brace
        result = extract_json_object('{"a": 1')
        assert result == {}

    def test_malformed_json_triggers_except(self):
        # Balanced braces but invalid content (e.g. trailing comma)
        # This should trigger the try-except block in extract_json_object
        result = extract_json_object('{"a": 1,}')
        assert result == {}


# ── coerce_string_list ───────────────────────────────────────────────

class TestCoerceStringList:
    def test_list_input(self):
        result = coerce_string_list(["a", "b", "c"], 10)
        assert result == ["a", "b", "c"]

    def test_single_value(self):
        result = coerce_string_list("hello", 10)
        assert result == ["hello"]

    def test_none_input(self):
        result = coerce_string_list(None, 10)
        assert result == []

    def test_limit_enforced(self):
        result = coerce_string_list(["a", "b", "c", "d"], 2)
        assert len(result) == 2

    def test_empty_strings_removed(self):
        result = coerce_string_list(["a", "", "  ", "b"], 10)
        assert result == ["a", "b"]


# ── is_placeholder_text ──────────────────────────────────────────────

class TestIsPlaceholderText:
    def test_transcription_placeholder(self):
        assert is_placeholder_text("[transcription unavailable due to error]") is True

    def test_translation_placeholder(self):
        assert is_placeholder_text("[Translation unavailable for this segment]") is True

    def test_normal_text(self):
        assert is_placeholder_text("Hello, this is normal text") is False

    def test_bracket_but_not_placeholder(self):
        assert is_placeholder_text("[Note] This is fine") is False


# ── is_whisper_hallucination ─────────────────────────────────────────

class TestIsWhisperHallucination:
    # --- always-filter phrases (any duration) ---
    def test_thank_you_for_watching(self):
        assert is_whisper_hallucination("Thank you for watching.") is True

    def test_subscribe(self):
        assert is_whisper_hallucination("Subscribe to my channel.") is True

    def test_subscribe_for_more(self):
        assert is_whisper_hallucination("Subscribe for more.") is True

    def test_music_symbol(self):
        assert is_whisper_hallucination("♪") is True

    def test_empty_string(self):
        assert is_whisper_hallucination("") is True

    def test_whitespace_only(self):
        assert is_whisper_hallucination("   ") is True

    # --- always-filter phrases work even with short_audio=False ---
    def test_always_filter_on_long_audio(self):
        assert is_whisper_hallucination("Thank you for watching.", short_audio=False) is True
        assert is_whisper_hallucination("Subscribe for more.", short_audio=False) is True

    # --- short-audio-only filters ---
    def test_repeated_word(self):
        assert is_whisper_hallucination("you you you") is True

    def test_repeated_word_not_filtered_on_long_audio(self):
        assert is_whisper_hallucination("you you you", short_audio=False) is False

    def test_single_you_short_audio(self):
        assert is_whisper_hallucination("you", short_audio=True) is True

    def test_single_you_long_audio(self):
        assert is_whisper_hallucination("you", short_audio=False) is False

    # --- real speech never filtered ---
    def test_normal_speech(self):
        assert is_whisper_hallucination("I need to schedule a meeting for tomorrow") is False

    def test_short_real_word(self):
        assert is_whisper_hallucination("hello") is False

    def test_real_sentence_with_thank_you(self):
        assert is_whisper_hallucination("Thank you for helping me with this project") is False


# ── split_sentences ──────────────────────────────────────────────────

class TestSplitSentences:
    def test_basic_split(self):
        result = split_sentences("Hello world. How are you? Fine!")
        assert len(result) == 3

    def test_no_punctuation_returns_whole(self):
        result = split_sentences("hello world without punctuation")
        assert result == ["hello world without punctuation"]

    def test_empty_string(self):
        result = split_sentences("")
        assert result == []

    def test_single_sentence(self):
        result = split_sentences("Just one sentence.")
        assert result == ["Just one sentence."]
