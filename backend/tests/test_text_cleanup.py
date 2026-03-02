"""Comprehensive text cleanup tests — ported from TextCleanupServiceTests.swift.

Tests cover the full cleanup pipeline brought to parity with the Swift
TextCleanupService. POS-aware tests (ambiguous fillers) are skipped since
the Python backend intentionally omits the NLTagger dependency.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

from server import (
    apply_tone,
    light_cleanup,
    remove_fillers,
    remove_repeated_words,
    replace_spoken_punctuation,
    split_and_recase,
)


# ── Spoken punctuation ──────────────────────────────────────────────


class TestSpokenPunctuation:
    def test_period(self):
        assert replace_spoken_punctuation("hello world period") == "hello world."

    def test_comma(self):
        assert replace_spoken_punctuation("first comma second") == "first, second"

    def test_question_mark(self):
        assert replace_spoken_punctuation("how are you question mark") == "how are you?"

    def test_exclamation_point(self):
        assert replace_spoken_punctuation("wow exclamation point") == "wow!"

    def test_exclamation_mark(self):
        assert replace_spoken_punctuation("wow exclamation mark") == "wow!"

    def test_new_line(self):
        assert replace_spoken_punctuation("line one new line line two") == "line one\nline two"

    def test_new_paragraph(self):
        assert replace_spoken_punctuation("para one new paragraph para two") == "para one\n\npara two"

    def test_colon(self):
        assert replace_spoken_punctuation("note colon important") == "note: important"

    def test_semicolon(self):
        assert replace_spoken_punctuation("first semicolon second") == "first; second"

    def test_open_close_quote(self):
        assert replace_spoken_punctuation("he said open quote hello close quote") == 'he said "hello"'

    def test_dash(self):
        result = replace_spoken_punctuation("word dash another")
        assert "\u2014" in result

    def test_hyphen(self):
        # Regex consumes leading space but not trailing — same as Swift
        result = replace_spoken_punctuation("well hyphen known")
        assert "-" in result
        assert "hyphen" not in result

    def test_full_stop(self):
        assert replace_spoken_punctuation("hello full stop") == "hello."

    def test_case_insensitive(self):
        assert replace_spoken_punctuation("hello PERIOD") == "hello."
        assert replace_spoken_punctuation("yes COMMA no") == "yes, no"

    def test_no_spoken_punctuation(self):
        assert replace_spoken_punctuation("no punctuation here") == "no punctuation here"


# ── Repeated word removal ───────────────────────────────────────────


class TestRemoveRepeatedWords:
    def test_adjacent_duplicate(self):
        assert remove_repeated_words("I want to to go") == "I want to go"

    def test_triple_duplicate(self):
        assert remove_repeated_words("the the the cat") == "the cat"

    def test_non_adjacent_not_removed(self):
        # "the" appears twice but non-adjacently — both kept
        assert remove_repeated_words("the cat saw the dog") == "the cat saw the dog"

    def test_no_repeats(self):
        assert remove_repeated_words("all words are unique") == "all words are unique"

    def test_case_insensitive(self):
        assert remove_repeated_words("The the cat") == "The cat"

    def test_single_word(self):
        assert remove_repeated_words("hello") == "hello"

    def test_empty_string(self):
        assert remove_repeated_words("") == ""


# ── Sentence split + recase ─────────────────────────────────────────


class TestSplitAndRecase:
    def test_single_sentence(self):
        assert split_and_recase("hello world") == "Hello world"

    def test_multiple_sentences(self):
        assert split_and_recase("hello world. how are you. good thanks") == "Hello world. How are you. Good thanks"

    def test_preserves_acronyms(self):
        assert split_and_recase("the API is down") == "The API is down"

    def test_empty_string(self):
        assert split_and_recase("") == ""


# ── Filler removal ──────────────────────────────────────────────────


class TestRemoveFillers:
    def test_obvious_fillers(self):
        result = remove_fillers("um I want to uh go there")
        assert "um" not in result.lower().split()
        assert "uh" not in result.lower().split()
        assert "want" in result
        assert "go there" in result

    def test_hmm(self):
        result = remove_fillers("hmm let me think")
        assert "hmm" not in result.lower().split()
        assert "let me think" in result

    def test_you_know(self):
        result = remove_fillers("it was you know really good")
        assert "you know" not in result.lower()
        assert "really good" in result

    def test_i_mean(self):
        result = remove_fillers("I mean the project is done")
        assert "I mean" not in result
        assert "project is done" in result

    def test_kind_of(self):
        result = remove_fillers("it was kind of nice")
        assert "kind of" not in result.lower()

    def test_sort_of(self):
        result = remove_fillers("that is sort of correct")
        assert "sort of" not in result.lower()

    def test_all_always_fillers(self):
        """Every always-filler should be removed."""
        for filler in ["um", "umm", "uh", "uhh", "er", "err", "ah", "ahh",
                        "hmm", "hm", "mm", "mmm", "mhm"]:
            result = remove_fillers(f"{filler} hello")
            assert filler not in result.lower().split(), f"Failed to remove '{filler}'"

    def test_empty_after_removal(self):
        result = remove_fillers("um uh er")
        assert result.strip() == ""


# ── Tone: concise ───────────────────────────────────────────────────


class TestApplyToneConcise:
    def test_removes_hedging(self):
        result = apply_tone("I think maybe we should do it.", "concise")
        assert "I think maybe" not in result
        assert "should do it" in result

    def test_removes_softeners(self):
        result = apply_tone("It is just really very important.", "concise")
        assert "just" not in result.lower().split()
        assert "really" not in result.lower().split()
        assert "very" not in result.lower().split()
        assert "important" in result

    def test_removes_quite(self):
        result = apply_tone("It was quite good.", "concise")
        assert "quite" not in result.lower().split()

    def test_removes_a_bit(self):
        result = apply_tone("I am a bit tired.", "concise")
        assert "a bit" not in result.lower()

    def test_removes_to_be_honest(self):
        result = apply_tone("To be honest I disagree.", "concise")
        assert "to be honest" not in result.lower()
        assert "disagree" in result


# ── Tone: formal ────────────────────────────────────────────────────


class TestApplyToneFormal:
    def test_dont(self):
        assert "do not" in apply_tone("I don't agree.", "formal")

    def test_cant(self):
        assert "cannot" in apply_tone("I can't do it.", "formal")

    def test_wont(self):
        assert "will not" in apply_tone("I won't go.", "formal")

    def test_multiple_contractions(self):
        result = apply_tone("I don't think we can't do it.", "formal")
        assert result == "I do not think we cannot do it."

    def test_casual_interjections_removed(self):
        result = apply_tone("Okay so the project is done.", "formal")
        assert "okay so" not in result.lower()
        assert "project is done" in result

    def test_yeah_to_yes(self):
        result = apply_tone("Yeah I agree.", "formal")
        assert "yeah" not in result.lower()
        assert "yes" in result.lower()

    def test_nope_to_no(self):
        result = apply_tone("Nope that is wrong.", "formal")
        assert "nope" not in result.lower()
        assert "no" in result.lower()

    def test_trailing_period(self):
        result = apply_tone("The report is ready", "formal")
        assert result.endswith(".")

    def test_preserves_existing_punctuation(self):
        result = apply_tone("Is that right?", "formal")
        assert result.endswith("?")
        assert not result.endswith(".?")

    def test_unicode_apostrophe(self):
        result = apply_tone("I don\u2019t know.", "formal")
        assert "do not" in result

    def test_im(self):
        result = apply_tone("I'm going.", "formal")
        assert "I am" in result

    def test_ive(self):
        result = apply_tone("I've seen it.", "formal")
        assert "I have" in result

    def test_theyre(self):
        result = apply_tone("They're coming.", "formal")
        assert "they are" in result

    def test_its(self):
        result = apply_tone("It's fine.", "formal")
        assert "it is" in result

    def test_lets(self):
        result = apply_tone("Let's go.", "formal")
        assert "let us" in result

    # ── Lowercase I-contraction regression (audit finding §1) ──────

    def test_lowercase_im(self):
        result = apply_tone("i'm going.", "formal")
        assert "I am" in result

    def test_lowercase_ive(self):
        result = apply_tone("i've seen it.", "formal")
        assert "I have" in result

    def test_lowercase_ill(self):
        result = apply_tone("i'll be there.", "formal")
        assert "I will" in result

    def test_lowercase_id(self):
        result = apply_tone("i'd rather not.", "formal")
        assert "I would" in result


# ── Tone: friendly ──────────────────────────────────────────────────


class TestApplyToneFriendly:
    def test_adds_exclamation(self):
        result = apply_tone("great job", "friendly")
        assert result.endswith("!")

    def test_preserves_existing_terminal(self):
        result = apply_tone("I don't think so.", "friendly")
        assert result.endswith(".")

    def test_no_imperative_softening(self):
        """Python intentionally skips Swift's POS-based 'Let's' prepend."""
        result = apply_tone("Send the report", "friendly")
        assert "Let's" not in result
        assert result.endswith("!")


# ── Full light_cleanup pipeline ─────────────────────────────────────


class TestLightCleanupFull:
    def test_full_pipeline(self):
        result = light_cleanup("um I want to to go to the store period")
        assert "um" not in result.lower().split()
        assert "want to go" in result
        assert result.endswith(".")
        assert result[0].isupper()

    def test_spoken_punctuation(self):
        result = light_cleanup("hello world period")
        assert result == "Hello world."

    def test_repeated_words(self):
        result = light_cleanup("the the cat sat")
        assert "the the" not in result
        assert "cat sat" in result

    def test_empty_string(self):
        assert light_cleanup("") == ""

    def test_whitespace_only(self):
        assert light_cleanup("   ") == ""

    def test_preserves_terminal_punctuation(self):
        result = light_cleanup("Hello world!")
        assert result.endswith("!")

    def test_capitalizes_first(self):
        result = light_cleanup("hello world")
        assert result[0] == "H"


# ── Neutral / unknown tone ──────────────────────────────────────────


class TestApplyToneNeutral:
    def test_neutral_no_change(self):
        assert apply_tone("Hello world.", "neutral") == "Hello world."

    def test_unknown_returns_normalized(self):
        assert apply_tone("  test  input  ", "unknown") == "test input"


# ── Tone case normalization (audit finding §3) ─────────────────────


class TestApplyToneCaseNormalization:
    def test_formal_capitalized(self):
        result = apply_tone("I don't agree.", "Formal")
        assert "do not" in result

    def test_concise_uppercase(self):
        result = apply_tone("I think maybe we should.", "CONCISE")
        assert "I think maybe" not in result

    def test_friendly_mixed_case(self):
        result = apply_tone("great job", "Friendly")
        assert result.endswith("!")

    def test_tone_with_whitespace(self):
        result = apply_tone("I don't agree.", "  formal  ")
        assert "do not" in result
