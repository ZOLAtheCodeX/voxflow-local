# Rules-First Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (a) A "Local rules only" polish setting (reserved `"rules"` chain id) so dictation polish can never silently load a local LLM; (b) four corpus-backed cleanup rules mirrored in Python and Swift with a shared parity fixture.

**Architecture:** Part (a) threads one reserved chain id through both providers.json readers (Swift `ProviderConfigStore`, Python `provider_registry`), short-circuits `PolishEngine` to the regex floor with `served_by="rules"`, and adds one picker row plus neutral indicator states. Part (b) adds shared rule constants (`PUNCT_ORPHAN_REPAIRS`, stutter regex), a punctuation-orphan repair step, punctuation-aware filler matching, and an ellipsis recase exclusion to BOTH cleanup pipelines, pinned by a shared JSON fixture consumed by both test suites.

**Tech Stack:** Swift 6.2 (strict concurrency, SwiftUI, XCTest), Python 3.11 (FastAPI backend, pytest).

**Spec:** `docs/superpowers/specs/2026-07-13-rules-first-hardening-design.md` (approved).

## Global Constraints

- The reserved chain id is exactly the string `rules` (constant on both sides; a provider may never use it — reject with a logged warning).
- `served_by="rules"` means CHOSEN rules-only (degraded_reason stays `None`); `served_by="regex"` keeps meaning DEGRADED (providers configured but all failed). Never conflate them.
- Smart actions are untouched: the smart-action picker gets NO rules-only row; the smart-action chain and engine behavior do not change.
- Part (b) rule data lives in `backend/app/text_cleanup_rules.py` and `Sources/VoxFlowApp/Models/TextCleanupRules.swift` (pure data modules); pipeline changes go in `backend/app/nlp/cleanup.py` and `Sources/VoxFlowApp/Services/TextCleanupService.swift`. Keep the two sides mirror-identical in behavior.
- Orphan-repair patterns match spaces/tabs only (`[ \t]`, never `\s`) so the `\n\n` written by "new paragraph" survives; ellipsis `...` must never collapse to `.`.
- ALL parity-fixture cases are SYNTHETIC. None of the user's verbatim dictations may enter the repository (it is public).
- Fixture cases must avoid the documented cross-side divergence zones: no ambiguous fillers (`like` — Swift removes it POS-aware, Python does not), no abbreviations (`Dr.`, `etc.`) that the splitters treat differently.
- All view styling through `VF.*` tokens (repo rule). Python logging via `logging.getLogger("voxflow")`, never bare print.
- Commits: imperative subject, detailed body, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Branch: `feature/rules-first-hardening` (already created; spec committed as `51a2820`).
- Suite baseline: 671 Swift / 519 Python green.
- Test commands: `swift test` and `./.venv/bin/python -m pytest backend/tests` from the repo root. Run pytest ONLY via that venv path.

---

### Task 1: Python cleanup rules (constants + pipeline)

**Files:**
- Modify: `backend/app/text_cleanup_rules.py` (append two constant blocks)
- Modify: `backend/app/nlp/cleanup.py` (new step + two step changes)
- Modify: `backend/app/nlp/__init__.py` ONLY IF it re-exports cleanup names (check first; add `repair_punctuation_orphans` to the re-export list if the module uses one)
- Test: `backend/tests/test_text_cleanup.py` (append tests)

**Interfaces:**
- Consumes: existing `ALWAYS_FILLERS`, `PHRASE_FILLERS` constants; existing `light_cleanup`, `remove_fillers`, `remove_repeated_words`, `split_and_recase` functions.
- Produces (Tasks 2-3 mirror these):
  - `PUNCT_ORPHAN_REPAIRS: list[tuple[re.Pattern[str], str]]` in `text_cleanup_rules.py`
  - `STUTTER_PREFIX: re.Pattern[str]` in `text_cleanup_rules.py`
  - `repair_punctuation_orphans(text: str) -> str` in `nlp/cleanup.py`
  - Behavior changes inside `remove_fillers` (punct-aware), `remove_repeated_words` (stutter), `split_and_recase` (ellipsis exclusion), `light_cleanup` (repair step wired in).

- [ ] **Step 1: Write the failing tests**

Append to `backend/tests/test_text_cleanup.py` (match the file's existing import style — it imports the functions under test from `nlp`/`nlp.cleanup`; read the top of the file first and mirror it):

```python
class TestPunctuationOrphanRepair:
    """Corpus-backed (2026-07-13 mining): orphaned punctuation left by
    filler/phrase removal was the dominant residual artifact (~3% of inserts)."""

    def test_orphan_comma_pair_collapses(self):
        assert repair_punctuation_orphans("pretty, , in your face") == "pretty, in your face"

    def test_double_comma_collapses(self):
        assert repair_punctuation_orphans("a,, b") == "a, b"

    def test_comma_dot_resolves_to_dot(self):
        assert repair_punctuation_orphans("the model,. sometimes") == "the model. sometimes"

    def test_comma_space_dot_resolves_to_dot(self):
        assert repair_punctuation_orphans("review, .") == "review."

    def test_question_mark_absorbs_trailing_dot(self):
        assert repair_punctuation_orphans("why?. next") == "why? next"

    def test_space_before_period_removed(self):
        assert repair_punctuation_orphans("what it looks .") == "what it looks."

    def test_space_before_comma_removed(self):
        assert repair_punctuation_orphans("first , second") == "first, second"

    def test_ellipsis_never_collapses(self):
        assert repair_punctuation_orphans("wait... what") == "wait... what"
        assert repair_punctuation_orphans("wait ...") == "wait ..."

    def test_newlines_preserved(self):
        assert repair_punctuation_orphans("one.\n\ntwo .") == "one.\n\ntwo."


class TestPunctuationAwareFillers:
    def test_filler_with_trailing_ellipsis_removed(self):
        assert remove_fillers("uh... testing the mic") == "testing the mic"

    def test_filler_with_trailing_comma_removed(self):
        # The whole token drops, punctuation included — "uh," carries its own
        # comma away, so no seam remains on this path. (The ", ," seam that
        # repair_punctuation_orphans heals comes from PHRASE-filler regex
        # removal, which leaves the surrounding punctuation behind.)
        assert remove_fillers("I was, uh, thinking") == "I was, thinking"

    def test_uh_huh_is_not_a_filler(self):
        assert remove_fillers("uh-huh sounds right") == "uh-huh sounds right"


class TestStutterDedup:
    def test_double_stutter_collapses(self):
        assert remove_repeated_words("the G-G-Gamma model") == "the Gamma model"

    def test_case_insensitive_stutter(self):
        assert remove_repeated_words("g-G-gamma") == "gamma"

    def test_d_day_untouched(self):
        assert remove_repeated_words("on D-Day we landed") == "on D-Day we landed"

    def test_t_shirt_untouched(self):
        assert remove_repeated_words("a T-shirt design") == "a T-shirt design"


class TestEllipsisRecase:
    def test_midtext_ellipsis_is_not_a_sentence_boundary(self):
        assert split_and_recase("ok. was pretty... good today") == "Ok. Was pretty... good today"

    def test_real_boundaries_still_recase(self):
        assert split_and_recase("done. next item") == "Done. Next item"


class TestLightCleanupEndToEnd:
    def test_phrase_filler_orphan_heals(self):
        assert light_cleanup("it's pretty, you know, in your face") == "It's pretty, in your face."

    def test_filler_comma_seam_heals(self):
        assert light_cleanup("I was, uh, thinking about it") == "I was, thinking about it."

    def test_stutter_and_filler_combo(self):
        assert light_cleanup("um so the G-G-Gamma model works") == "So the Gamma model works."

    def test_hesitation_ellipsis_stays_lowercase(self):
        assert light_cleanup("that was pretty... good I think") == "That was pretty... good I think."
```

Add the needed names to the file's existing import from the cleanup module: `repair_punctuation_orphans, remove_fillers, remove_repeated_words, split_and_recase, light_cleanup`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_text_cleanup.py -q 2>&1 | tail -5`
Expected: FAIL — `ImportError: cannot import name 'repair_punctuation_orphans'`.

- [ ] **Step 3: Implement**

Append to `backend/app/text_cleanup_rules.py` (after `PHRASE_FILLERS`, before the tone sections):

```python
# ── Punctuation-orphan repair (corpus-backed, 2026-07-13) ───────────
# Filler/phrase removal strands the punctuation that surrounded the removed
# words ("pretty, you know, in" -> "pretty, , in"). Order matters: comma
# runs collapse first, then double marks resolve to the terminal mark, then
# space-before-punctuation. [ \t] only (never \s) so the \n\n written by
# "new paragraph" survives; the (?!\.) guards keep "..." from collapsing.

PUNCT_ORPHAN_REPAIRS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r",[ \t]*(?:,[ \t]*)+"), ", "),          # ", ," / ",,"  -> ", "
    (re.compile(r",[ \t]*\.(?!\.)"), "."),               # ",." / ", ."  -> "."
    (re.compile(r"(?<!\.)\.[ \t]*,"), "."),              # ".,"          -> "."
    (re.compile(r"\?[ \t]*[.,](?!\.)"), "?"),            # "?." / "?,"   -> "?"
    (re.compile(r"![ \t]*[.,](?!\.)"), "!"),             # "!." / "!,"   -> "!"
    (re.compile(r"[ \t]+(?=[,.;:!?](?:[ \t]|$))"), ""),  # "word ."      -> "word."
]

# ── Stutter prefixes (corpus-backed, 2026-07-13) ────────────────────
# "G-G-Gamma" -> "Gamma". Requires >= 2 stutter letters before the word so
# legitimate single-letter hyphenations (D-Day, T-shirt, X-ray) never match:
# their second segment does not repeat the prefix letter, and even D-Day has
# only ONE "D-" before the word.

STUTTER_PREFIX: re.Pattern[str] = re.compile(r"\b(\w)-(?:\1-)+(\1\w*)", re.IGNORECASE)
```

Note the first pattern replaces with `", "` (comma + space) so `"a,, b"` heals to `"a, b"`; the final space-before-punct pattern then never sees a stranded comma. Trailing-space edge (`"a, "` at end) is cleaned by the pipeline's final `normalize_whitespace`/strip.

In `backend/app/nlp/cleanup.py`:

1. Extend the import: `from text_cleanup_rules import (ALWAYS_FILLERS, PHRASE_FILLERS, PUNCT_ORPHAN_REPAIRS, SPOKEN_PUNCTUATION, STUTTER_PREFIX)`.
2. Add after `remove_repeated_words`:

```python
def repair_punctuation_orphans(text: str) -> str:
    """Collapse punctuation stranded by filler/phrase removal (corpus-backed).

    Runs after filler removal in light_cleanup; ellipsis and newlines are
    protected by the patterns themselves (see text_cleanup_rules).
    """
    result = text
    for pattern, replacement in PUNCT_ORPHAN_REPAIRS:
        result = pattern.sub(replacement, result)
    return result
```

3. In `remove_repeated_words`, add stutter collapse as the first line:

```python
def remove_repeated_words(text: str) -> str:
    """Remove adjacent duplicate words (case-insensitive) and stutter prefixes."""
    text = STUTTER_PREFIX.sub(r"\2", text)
    words = text.split()
    ...  # rest unchanged
```

4. In `remove_fillers`, replace the Phase 1 membership filter with a punctuation-aware check:

```python
    # Phase 1: single-word always-fillers. Tokens are checked with their
    # leading/trailing punctuation stripped so "Uh..." / "um," match too
    # (exact-token matching let them survive — corpus finding 2026-07-13).
    # The whole token goes, punctuation included; repair_punctuation_orphans
    # heals the seam afterwards. "uh-huh" keeps its hyphen core and stays.
    words = result.split()
    words = [w for w in words if w.strip(_FILLER_PUNCT).lower() not in ALWAYS_FILLERS]
    return " ".join(words)
```

with a module constant near the top of `cleanup.py`:

```python
_FILLER_PUNCT = ".,;:!?…\"'()[]"
```

Note: `"".strip(...)` of a pure-punctuation token yields `""`, which is not in `ALWAYS_FILLERS`, so free-standing punctuation tokens survive — that is correct.

5. In `split_and_recase`, exclude ellipsis from the boundary:

```python
    segments = re.split(r"(?<=[.!?])(?<!\.\.\.)\s+", text)
```

(fixed-width 3-char negative lookbehind: a split point preceded by `...` is a hesitation, not a sentence end). Update the docstring's first line to mention the ellipsis exclusion.

6. In `light_cleanup`, wire the repair step between filler removal and the final normalization:

```python
    cleaned = remove_fillers(cleaned)
    cleaned = repair_punctuation_orphans(cleaned)
    cleaned = normalize_whitespace(cleaned)
```

Also update the module docstring's pipeline summary line to: `normalize whitespace → spoken punctuation → stutter+repeated-word dedup → sentence split + recase → filler removal → punctuation-orphan repair → final normalization`.

Check `backend/app/nlp/__init__.py`: if it re-exports cleanup functions by name, add `repair_punctuation_orphans`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.venv/bin/python -m pytest backend/tests/test_text_cleanup.py -q 2>&1 | tail -3`
Expected: all pass (existing tests + 20 new).

Run the full backend suite to catch regressions in polish-floor behavior:
`./.venv/bin/python -m pytest backend/tests -q 2>&1 | tail -2`
Expected: ~541 passed (519 baseline + 22 new; exact count may differ; requirement is 0 failures). If an EXISTING test fails because its expected output legitimately improves under the new rules (e.g. a golden light-cleanup string that contained an orphan), update that expectation and say so in the commit body — but scrutinize each one first; an unexpected regression is a bug, not an expectation update.

- [ ] **Step 5: Commit**

```bash
git add backend/app/text_cleanup_rules.py backend/app/nlp/cleanup.py backend/app/nlp/__init__.py backend/tests/test_text_cleanup.py
git commit -m "feat: corpus-backed cleanup rules (python side)

Punctuation-orphan repair step (heals ', ,' / ',.' / 'word .' seams left
by filler removal), punctuation-aware filler matching ('Uh...' now
matches), stutter-prefix dedup (G-G-Gamma -> Gamma), and ellipsis
excluded from sentence-recase boundaries. Backed by the 2026-07-13
mining pass over 1,003 real receipts (~3% orphan rate was the dominant
residual artifact class).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Swift cleanup rules mirror

**Files:**
- Modify: `Sources/VoxFlowApp/Models/TextCleanupRules.swift` (two constant blocks)
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift` (new step + three changes)
- Test: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift` (append tests)

**Interfaces:**
- Consumes: Task 1's rule semantics (mirror them exactly).
- Produces: `TextCleanupRules.punctOrphanRepairs: [(String, String)]`, `TextCleanupRules.stutterPrefixPattern: String`, `TextCleanupService.repairPunctuationOrphans(_:) -> String`, and the three behavior changes mirrored from Task 1.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift` (read the file's existing test style first and match it):

```swift
    // MARK: - Punctuation-orphan repair (corpus-backed 2026-07-13)

    func testOrphanCommaPairCollapses() {
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("pretty, , in your face"),
                       "pretty, in your face")
    }

    func testCommaDotResolvesToDot() {
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("the model,. sometimes"),
                       "the model. sometimes")
    }

    func testSpaceBeforePeriodRemoved() {
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("what it looks ."),
                       "what it looks.")
    }

    func testEllipsisNeverCollapses() {
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("wait... what"), "wait... what")
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("wait ..."), "wait ...")
    }

    func testNewlinesPreservedByRepair() {
        XCTAssertEqual(TextCleanupService.repairPunctuationOrphans("one.\n\ntwo ."), "one.\n\ntwo.")
    }

    // MARK: - Punctuation-aware fillers

    func testFillerWithTrailingEllipsisRemoved() {
        XCTAssertEqual(TextCleanupService.removeFillers("uh... testing the mic"), "testing the mic")
    }

    func testUhHuhIsNotAFiller() {
        XCTAssertEqual(TextCleanupService.removeFillers("uh-huh sounds right"), "uh-huh sounds right")
    }

    // MARK: - Stutter dedup

    func testDoubleStutterCollapses() {
        XCTAssertEqual(TextCleanupService.removeRepeatedWords("the G-G-Gamma model"), "the Gamma model")
    }

    func testDDayUntouched() {
        XCTAssertEqual(TextCleanupService.removeRepeatedWords("on D-Day we landed"), "on D-Day we landed")
    }

    // MARK: - Ellipsis recase

    func testMidtextEllipsisIsNotASentenceBoundary() {
        XCTAssertEqual(TextCleanupService.splitAndRecase("ok. was pretty... good today"),
                       "Ok. Was pretty... good today")
    }

    // MARK: - Light pipeline end to end

    func testPhraseFillerOrphanHeals() {
        XCTAssertEqual(TextCleanupService.cleanup("it's pretty, you know, in your face", mode: .light, tone: .neutral),
                       "It's pretty, in your face.")
    }

    func testHesitationEllipsisStaysLowercase() {
        XCTAssertEqual(TextCleanupService.cleanup("that was pretty... good I think", mode: .light, tone: .neutral),
                       "That was pretty... good I think.")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -5`
Expected: compile FAILURE — `type 'TextCleanupService' has no member 'repairPunctuationOrphans'`.

- [ ] **Step 3: Implement**

In `Sources/VoxFlowApp/Models/TextCleanupRules.swift`, add (near `phraseFillers`; match the file's existing `[(String, String)]` pattern-array style — read it first):

```swift
    // ── Punctuation-orphan repair (corpus-backed, 2026-07-13) ────────
    // Mirror of PUNCT_ORPHAN_REPAIRS in backend/app/text_cleanup_rules.py —
    // keep the two lists in lockstep (cleanup_rules_parity.json pins them).
    // [ \t] only (never \s) so "new paragraph" newlines survive; (?!\.)
    // guards keep "..." from collapsing.
    static let punctOrphanRepairs: [(String, String)] = [
        (#",[ \t]*(?:,[ \t]*)+"#, ", "),
        (#",[ \t]*\.(?!\.)"#, "."),
        (#"(?<!\.)\.[ \t]*,"#, "."),
        (#"\?[ \t]*[.,](?!\.)"#, "?"),
        (#"![ \t]*[.,](?!\.)"#, "!"),
        (#"[ \t]+(?=[,.;:!?](?:[ \t]|$))"#, ""),
    ]

    // ── Stutter prefixes (corpus-backed, 2026-07-13) ─────────────────
    // "G-G-Gamma" -> "Gamma"; >= 2 stutter letters required so D-Day /
    // T-shirt / X-ray never match. Mirror of STUTTER_PREFIX (python).
    static let stutterPrefixPattern = #"\b(\w)-(?:\1-)+(\1\w*)"#
```

In `Sources/VoxFlowApp/Services/TextCleanupService.swift`:

1. Add after `removeRepeatedWords`:

```swift
    /// Collapse punctuation stranded by filler/phrase removal (corpus-backed).
    /// Ellipsis and newlines are protected by the patterns themselves.
    static func repairPunctuationOrphans(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in TextCleanupRules.punctOrphanRepairs {
            result = result.replacingOccurrences(
                of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }
```

(No `.caseInsensitive` — the patterns are punctuation-only.)

2. In `removeRepeatedWords`, collapse stutters first:

```swift
    static func removeRepeatedWords(_ text: String) -> String {
        let destuttered = text.replacingOccurrences(
            of: TextCleanupRules.stutterPrefixPattern,
            with: "$2",
            options: [.regularExpression, .caseInsensitive]
        )
        let words = destuttered.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count > 1 else { return destuttered }
        ...  // rest unchanged (note: the guard now returns destuttered, not text)
    }
```

3. In `removeFillers`, make Pass 1 punctuation-aware:

```swift
        // Pass 1: Remove always-fillers. Tokens are checked with their
        // leading/trailing punctuation stripped so "Uh..." / "um," match too
        // (exact-token matching let them survive — corpus finding 2026-07-13).
        let fillerPunct = CharacterSet(charactersIn: ".,;:!?…\"'()[]")
        let words = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let afterAlways = words.filter { word in
            let core = word.trimmingCharacters(in: fillerPunct).lowercased()
            return core.isEmpty || !TextCleanupRules.alwaysFillers.contains(core)
        }
        result = afterAlways.joined(separator: " ")
```

4. In `splitAndRecase`, two changes. First, merge NLTokenizer fragments that split at a hesitation ellipsis:

```swift
        var nlSentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespaces)
            // A fragment boundary at "..." is a hesitation, not a sentence
            // end — merge it back so the next word is not recapitalized.
            if let last = nlSentences.last, last.hasSuffix("...") {
                nlSentences[nlSentences.count - 1] = last + " " + sentence
            } else {
                nlSentences.append(sentence)
            }
            return true
        }
```

Second, exclude ellipsis in the regex sub-split (the marked-sentinel pattern):

```swift
            let marked = chunk.replacingOccurrences(
                of: #"(?<!\.\.)([.!?])\s+"#,
                with: "$1\u{001E}",
                options: .regularExpression
            )
```

(the `(?<!\.\.)` lookbehind sees the two characters before the matched mark: for the final dot of `...` they are `..`, so no split.)

5. In `cleanup(_:mode:tone:)`, wire the repair step after filler removal:

```swift
        // Step 5: Filler removal
        result = removeFillers(result)

        // Step 5.5: Punctuation-orphan repair (corpus-backed 2026-07-13)
        result = repairPunctuationOrphans(result)

        // Re-normalize after removals
        result = normalizeWhitespace(result)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -3`
Expected: all pass (existing + 12 new). If `testMidtextEllipsisIsNotASentenceBoundary` fails because NLTokenizer splits differently than expected, debug with the merge logic in change 4 — the merged-fragment path plus the lookbehind must together keep `good` lowercase.

Run the full Swift suite: `swift test 2>&1 | tail -3`
Expected: 0 failures (671 baseline + 12; if an existing cleanup expectation legitimately improves under the new rules, update it and say so in the commit body — scrutinize each first).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Models/TextCleanupRules.swift Sources/VoxFlowApp/Services/TextCleanupService.swift Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: corpus-backed cleanup rules (swift mirror)

Mirrors the python side: punctuation-orphan repair step, punctuation-
aware filler matching, stutter-prefix dedup, ellipsis excluded from
recase boundaries (both the NLTokenizer fragment merge and the regex
sub-split lookbehind).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: shared parity fixture

**Files:**
- Create: `Tests/Fixtures/cleanup_rules_parity.json`
- Create: `backend/tests/test_cleanup_parity.py`
- Test: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift` (append ONE parity test)

**Interfaces:**
- Consumes: Task 1's `light_cleanup`, Task 2's `cleanup(_:mode:tone:)`.
- Produces: the fixture file both suites pin against; pattern mirrors `Tests/Fixtures/hallucination_parity.json` (see `Tests/VoxFlowAppTests/HallucinationFilterTests.swift:158` for the Swift `#filePath` mechanism and `backend/tests/test_utils.py:484-498` for the Python project-root mechanism — read both before writing).

- [ ] **Step 1: Write the fixture**

Create `Tests/Fixtures/cleanup_rules_parity.json`. ALL cases synthetic; every case runs the FULL light pipeline on both sides and must produce byte-identical output:

```json
{
  "comment": "Light-cleanup parity cases for the 2026-07-13 corpus-backed rules. Synthetic only — never real dictations (public repo). Cases avoid the documented divergence zones: no ambiguous fillers (like), no abbreviations.",
  "cases": [
    {"input": "it's pretty, you know, in your face", "expected": "It's pretty, in your face.", "note": "phrase-filler orphan heals"},
    {"input": "I was, uh, thinking about it", "expected": "I was, thinking about it.", "note": "filler-with-comma seam heals"},
    {"input": "uh... testing the mic", "expected": "Testing the mic.", "note": "filler with attached ellipsis"},
    {"input": "um so the G-G-Gamma model works", "expected": "So the Gamma model works.", "note": "stutter + leading filler"},
    {"input": "that was pretty... good I think", "expected": "That was pretty... good I think.", "note": "hesitation ellipsis not recased"},
    {"input": "what it looks sort of.", "expected": "What it looks.", "note": "phrase filler leaves space-dot orphan"},
    {"input": "on D-Day we landed", "expected": "On D-Day we landed.", "note": "single-letter hyphenation untouched"},
    {"input": "uh-huh sounds right", "expected": "Uh-huh sounds right.", "note": "hyphenated non-filler kept"},
    {"input": "hello hello world", "expected": "Hello world.", "note": "baseline: adjacent dedup"},
    {"input": "send it period", "expected": "Send it.", "note": "baseline: spoken punctuation"}
  ]
}
```

- [ ] **Step 2: Write both parity tests (failing until fixture behavior verified)**

Create `backend/tests/test_cleanup_parity.py`:

```python
"""Behavioral parity with Sources/VoxFlowApp/Services/TextCleanupService.swift.

Both implementations consume Tests/Fixtures/cleanup_rules_parity.json.
Mirror the project-root mechanism used by the hallucination parity test in
test_utils.py — verify against that file and reuse its exact approach.
"""

import json
from pathlib import Path

from nlp import light_cleanup


def test_cleanup_rules_parity_fixture():
    project_root = Path(__file__).resolve().parents[2]
    fixture = project_root / "Tests" / "Fixtures" / "cleanup_rules_parity.json"
    cases = json.loads(fixture.read_text(encoding="utf-8"))["cases"]
    assert len(cases) >= 10, "fixture unexpectedly small — wrong file?"

    failures = []
    for c in cases:
        got = light_cleanup(c["input"])
        if got != c["expected"]:
            failures.append(f"{c['input']!r}: expected {c['expected']!r}, got {got!r} — {c.get('note', '')}")
    assert not failures, "\n".join(failures)
```

(If `nlp` does not re-export `light_cleanup`, import from `nlp.cleanup` — match how `test_text_cleanup.py` imports it.)

Append to `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`:

```swift
    /// Behavioral parity with backend/app/nlp/cleanup.py — both sides consume
    /// Tests/Fixtures/cleanup_rules_parity.json (same mechanism as the
    /// hallucination parity test).
    func testCleanupRulesParityFixture() throws {
        struct ParityCase: Decodable {
            let input: String
            let expected: String
            let note: String?
        }
        struct ParityFixture: Decodable {
            let cases: [ParityCase]
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/VoxFlowAppTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/cleanup_rules_parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: data)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10, "Fixture unexpectedly small — wrong file?")

        var failures: [String] = []
        for c in fixture.cases {
            let got = TextCleanupService.cleanup(c.input, mode: .light, tone: .neutral)
            if got != c.expected {
                failures.append("'\(c.input)': expected '\(c.expected)', got '\(got)' — \(c.note ?? "")")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
```

- [ ] **Step 3: Run both sides**

Run: `./.venv/bin/python -m pytest backend/tests/test_cleanup_parity.py -q 2>&1 | tail -3`
Run: `swift test --filter testCleanupRulesParityFixture 2>&1 | tail -3`
Expected: both pass. If a case diverges because of the DOCUMENTED splitter divergence (NLTokenizer vs regex) rather than a rules bug, REPLACE that case with a safer synthetic equivalent — do not force-fit pipeline code to make a divergence-zone case pass. Any replaced case gets a note in the commit body.

- [ ] **Step 4: Commit**

```bash
git add Tests/Fixtures/cleanup_rules_parity.json backend/tests/test_cleanup_parity.py Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "test: shared cleanup-rules parity fixture (swift + python)

Ten synthetic light-pipeline cases pinning the 2026-07-13 corpus rules
on both sides, same mechanism as hallucination_parity.json. Cases avoid
the documented splitter divergence zones.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: backend rules-only sentinel

**Files:**
- Modify: `backend/app/engines/provider_registry.py` (sentinel constant, loader skip + pruning, `chain()` truncation, `rules_only()` helper)
- Modify: `backend/app/engines/polish.py` (`rules_only` init param + short-circuit)
- Modify: `backend/app/context.py` (engine construction + readiness branch)
- Test: `backend/tests/test_provider_registry.py`, `backend/tests/test_polish_engine.py` (append tests)

**Interfaces:**
- Consumes: existing `load_provider_config`, `ProviderRegistry.chain`, `PolishEngine.run`, `PolishOutcome`.
- Produces (Task 5's Swift side mirrors the semantics):
  - `RULES_SENTINEL = "rules"` module constant in `provider_registry.py`
  - `ProviderRegistry.rules_only(task: str) -> bool`
  - `PolishEngine(..., rules_only: bool = False)`; when true and `system_prompt is None`, `run()` returns the floor with `served_by="rules"`, `degraded_reason=None`, `fallback_depth=0`
  - `/v1/ready` reports `active_polish_provider: "rules"`, `active_polish_model: ""` when the polish chain starts with the sentinel.

- [ ] **Step 1: Write the failing tests**

Append to `backend/tests/test_provider_registry.py` (read the file's existing fixtures first — it writes config JSON to tmp paths; match that pattern):

```python
class TestRulesSentinel:
    def _write(self, tmp_path, config):
        p = tmp_path / "providers.json"
        p.write_text(json.dumps(config), encoding="utf-8")
        return p

    def test_sentinel_survives_chain_pruning(self, tmp_path):
        cfg = load_provider_config(self._write(tmp_path, {
            "version": 1,
            "providers": [{"id": "ollama", "kind": "ollama"}],
            "chains": {"polish": ["rules"], "smart_action": ["ollama"]},
        }))
        assert cfg.chains["polish"] == ["rules"]

    def test_entries_after_sentinel_are_truncated(self, tmp_path):
        cfg = load_provider_config(self._write(tmp_path, {
            "version": 1,
            "providers": [{"id": "ollama", "kind": "ollama"}],
            "chains": {"polish": ["rules", "ollama"], "smart_action": ["ollama"]},
        }))
        assert cfg.chains["polish"] == ["rules"]

    def test_reserved_provider_id_is_skipped(self, tmp_path, caplog):
        cfg = load_provider_config(self._write(tmp_path, {
            "version": 1,
            "providers": [{"id": "rules", "kind": "ollama"}, {"id": "ollama", "kind": "ollama"}],
            "chains": {"polish": ["ollama"], "smart_action": ["ollama"]},
        }))
        assert [s.id for s in cfg.providers] == ["ollama"]

    def test_chain_resolution_skips_sentinel_and_does_not_refill(self, tmp_path):
        cfg = load_provider_config(self._write(tmp_path, {
            "version": 1,
            "providers": [{"id": "ollama", "kind": "ollama"}],
            "chains": {"polish": ["rules"], "smart_action": ["ollama"]},
        }))
        registry = ProviderRegistry(cfg)
        assert registry.chain("polish") == []
        assert registry.rules_only("polish") is True
        assert registry.rules_only("smart_action") is False
```

Append to `backend/tests/test_polish_engine.py`:

```python
class _MustNotBeCalledBackend:
    name = "must-not-be-called"

    def polish(self, *args, **kwargs):
        raise AssertionError("provider backend called in rules-only mode")


class TestRulesOnlyPolish:
    def test_rules_only_serves_floor_with_rules_provenance(self):
        engine = PolishEngine(chain=[(None, _MustNotBeCalledBackend())], rules_only=True)
        out = engine.run("um hello hello world", "neutral")
        assert out.served_by == "rules"
        assert out.degraded_reason is None
        assert out.fallback_depth == 0
        assert out.guardrail_triggered is False
        assert out.text == "Hello world."

    def test_degraded_floor_still_reports_regex(self):
        engine = PolishEngine(chain=[], rules_only=False)
        out = engine.run("hello world", "neutral")
        assert out.served_by == "regex"
        assert out.degraded_reason == "backend_unavailable"
```

(Match the files' existing import style for `load_provider_config`, `ProviderRegistry`, `PolishEngine` — read the tops of both test files first.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `./.venv/bin/python -m pytest backend/tests/test_provider_registry.py backend/tests/test_polish_engine.py -q 2>&1 | tail -4`
Expected: FAIL — `rules_only` attribute/param does not exist; sentinel pruned to default chain.

- [ ] **Step 3: Implement**

In `backend/app/engines/provider_registry.py`:

1. Add below `DEFAULT_TASKS`:

```python
# Reserved chain id: a chain starting with "rules" means the user chose the
# local rules/regex floor deliberately — no LLM provider runs for that task.
# It is a chain concept, not a provider: a provider may never use this id.
RULES_SENTINEL = "rules"
```

2. In `load_provider_config`, inside the provider-entry loop right after `provider_id` is computed and validated non-empty:

```python
        if provider_id == RULES_SENTINEL:
            logger.warning("providers.json: %r is a reserved chain id — provider entry skipped", provider_id)
            continue
```

3. In the chain-pruning loop, keep the sentinel and truncate after its first occurrence:

```python
        pruned = [str(e) for e in entries if str(e) in known_ids or str(e) == RULES_SENTINEL] if isinstance(entries, list) else []
        if RULES_SENTINEL in pruned:
            # Entries after the sentinel are unreachable — normalize them away.
            pruned = pruned[: pruned.index(RULES_SENTINEL) + 1]
        if not pruned:
            ...  # existing default-refill unchanged
```

4. In `ProviderRegistry`, change `chain()` and add `rules_only()`:

```python
    def chain(self, task: str) -> list[tuple[ProviderSpec, object]]:
        """Resolved (spec, backend) pairs for a task, in fallback order.

        A chain starting with RULES_SENTINEL resolves to [] — the caller
        (PolishEngine with rules_only=True) serves the floor deliberately —
        and the default-refill must NOT fire for it.
        """
        ids = self._config.chains.get(task) or self._config.chains.get("polish") or []
        if RULES_SENTINEL in ids:
            ids = ids[: ids.index(RULES_SENTINEL)]
        elif not ids and self._config.providers:
            ids = [self._config.providers[0].id]
        return [(self.spec(pid), self.backend(pid)) for pid in ids]

    def rules_only(self, task: str) -> bool:
        """True when the task's chain deliberately starts at the rules floor."""
        ids = self._config.chains.get(task) or []
        return bool(ids) and ids[0] == RULES_SENTINEL
```

In `backend/app/engines/polish.py`:

1. Extend `__init__`:

```python
    def __init__(
        self,
        backend: TextLLMBackend | None = None,
        *,
        chain: list[tuple[ProviderSpec | None, TextLLMBackend]] | None = None,
        clock: Callable[[], float] = time.monotonic,
        rules_only: bool = False,
    ) -> None:
        ...
        self._rules_only = rules_only
```

2. In `run()`, add the short-circuit directly after the empty-text guard (before the spoken-punctuation conversion — `light_cleanup` performs its own):

```python
        # Rules-only (user-chosen "Local rules only" polish): serve the floor
        # deliberately. served_by="rules" ≠ served_by="regex" — chosen is not
        # degraded, so degraded_reason stays None. Smart actions never carry
        # the sentinel (UI does not offer it); a system_prompt call on a
        # rules-only engine falls through to the normal (empty) chain walk.
        if self._rules_only and system_prompt is None:
            return PolishOutcome(
                apply_tone(light_cleanup(text), tone), False, None,
                served_by="rules", model_id=None, fallback_depth=0,
            )
```

3. Update the `PolishOutcome` docstring's `served_by` line to name all three: provider id, `"regex"` (degraded floor), `"rules"` (chosen floor).

In `backend/app/context.py`:

1. Engine construction (line ~77):

```python
polish_engine = PolishEngine(
    chain=provider_registry.chain("polish"),
    rules_only=provider_registry.rules_only("polish"),
)
```

(`smart_action_polish_engine` unchanged.)

2. In the readiness builder, right after the `for pid in polish_chain:` active-provider loop:

```python
    if provider_registry.rules_only("polish"):
        # User-chosen rules floor: report it as the active provider so the
        # mode-in-use indicator renders "chosen", not "degraded".
        active_provider = "rules"
        active_polish_model_name = ""
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./.venv/bin/python -m pytest backend/tests/test_provider_registry.py backend/tests/test_polish_engine.py -q 2>&1 | tail -3`
Expected: all pass.

Full backend suite: `./.venv/bin/python -m pytest backend/tests -q 2>&1 | tail -2`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add backend/app/engines/provider_registry.py backend/app/engines/polish.py backend/app/context.py backend/tests/test_provider_registry.py backend/tests/test_polish_engine.py
git commit -m "feat: reserved 'rules' chain sentinel — rules-only polish (backend)

chains.polish = [\"rules\"] short-circuits PolishEngine to the regex
floor with served_by=rules (chosen, degraded_reason None) — distinct
from served_by=regex (providers failed). Loader keeps the sentinel
through pruning, truncates unreachable entries after it, refuses
provider entries named 'rules', and /v1/ready reports
active_polish_provider=rules so indicators render chosen-not-degraded.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Swift rules-only sentinel (store + settings + indicators)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/ProviderConfigStore.swift` (sentinel constant, `add` rejection, `remove`/`setChain` pruning)
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift` (picker row + binding branch + caption, ~line 356 and ~line 973)
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift` (`polishProviderIndicator` rules branch)
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift` (`modelPill` rules branch, ~line 45)
- Test: `Tests/VoxFlowAppTests/ProviderConfigStoreTests.swift` (append tests)

**Interfaces:**
- Consumes: Task 4's backend semantics (`active_polish_provider == "rules"` from `/v1/ready`).
- Produces: `ProviderConfigStore.rulesSentinel` (`nonisolated static let rulesSentinel = "rules"`); sentinel-aware `add`/`remove`/`setChain`; picker writes `["rules"]`; both pills render provider `rules` as neutral "rules · local".

- [ ] **Step 1: Write the failing tests**

Append to `Tests/VoxFlowAppTests/ProviderConfigStoreTests.swift` (read its existing temp-file fixture pattern first and reuse it):

```swift
    // MARK: - Rules sentinel (rules-only polish)

    func testAddRejectsReservedRulesID() {
        let store = makeStore()  // use the file's existing fixture helper name
        XCTAssertFalse(store.add(ProviderSpecModel(id: "rules", kind: .ollama)))
        XCTAssertFalse(store.add(ProviderSpecModel(id: "Rules", kind: .ollama)))
        XCTAssertFalse(store.providers.contains { $0.id.lowercased() == "rules" })
    }

    func testSetChainAcceptsSentinelAndTruncatesAfterIt() {
        let store = makeStore()
        store.setChain(task: "polish", providerIDs: ["rules", "ollama"])
        XCTAssertEqual(store.chains["polish"], ["rules"])
    }

    func testSentinelSurvivesProviderRemovalPruning() {
        let store = makeStore()
        store.add(ProviderSpecModel(id: "lmstudio", kind: .openaiCompat))
        store.setChain(task: "polish", providerIDs: ["rules"])
        store.remove(id: "lmstudio")
        XCTAssertEqual(store.chains["polish"], ["rules"])
    }

    func testSentinelRoundTripsThroughSaveAndLoad() {
        let url = makeTempFileURL()  // use the file's existing temp-URL helper name
        let store = ProviderConfigStore(fileURL: url)
        store.setChain(task: "polish", providerIDs: [ProviderConfigStore.rulesSentinel])
        let reloaded = ProviderConfigStore(fileURL: url)
        XCTAssertEqual(reloaded.chains["polish"], ["rules"])
    }
```

(If the file's fixture helpers have different names, adapt the calls — the behaviors asserted are the contract.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProviderConfigStoreTests 2>&1 | tail -4`
Expected: compile FAILURE (`rulesSentinel` missing) or assertion failures (sentinel pruned).

- [ ] **Step 3: Implement**

In `Sources/VoxFlowApp/Services/ProviderConfigStore.swift`:

1. Add near `static let tasks`:

```swift
    /// Reserved chain id: a polish chain of ["rules"] means the user chose
    /// the local rules floor deliberately — no LLM provider runs for polish.
    /// MUST match RULES_SENTINEL in backend provider_registry.py.
    nonisolated static let rulesSentinel = "rules"
```

2. In `add(_:)`, reject the reserved id (after the trimmedID guard):

```swift
        guard trimmedID.lowercased() != Self.rulesSentinel else {
            log.error("Provider id 'rules' is reserved for the rules-only chain sentinel — rejected")
            return false
        }
```

3. In `remove(id:)`, keep the sentinel through pruning:

```swift
        for task in chains.keys {
            chains[task] = (chains[task] ?? []).filter { pid in
                pid == Self.rulesSentinel || providers.contains(where: { $0.id == pid })
            }
            if chains[task]?.isEmpty == true {
                chains[task] = providers.first.map { [$0.id] } ?? []
            }
        }
```

4. In `setChain(task:providerIDs:)`, accept the sentinel and truncate after it:

```swift
    func setChain(task: String, providerIDs: [String]) {
        let known = Set(providers.map(\.id))
        var pruned = providerIDs.filter { known.contains($0) || $0 == Self.rulesSentinel }
        if let idx = pruned.firstIndex(of: Self.rulesSentinel) {
            // Entries after the sentinel are unreachable — normalize them away
            // (matches the backend loader's truncation).
            pruned = Array(pruned[...idx])
        }
        if pruned.isEmpty, let first = providers.first?.id { pruned = [first] }
        chains[task] = pruned
        save()
    }
```

In `Sources/VoxFlowApp/Views/SettingsView.swift`:

1. The chain picker (~line 356) gains a rules row for the polish task only:

```swift
                    Picker(task == "polish" ? "Polish provider" : "Smart-action provider", selection: chainPrimaryBinding(for: task)) {
                        ForEach(providerStore.providers.map(\.id), id: \.self) { pid in
                            Text(pid).tag(pid)
                        }
                        if task == "polish" {
                            Text("Local rules only").tag(ProviderConfigStore.rulesSentinel)
                        }
                    }
```

2. `chainPrimaryBinding(for:)` (~line 973) gains the sentinel branch:

```swift
            set: { newPrimary in
                if newPrimary == ProviderConfigStore.rulesSentinel {
                    // Rules-only is a full stop: no LLM fallback appended.
                    providerStore.setChain(task: task, providerIDs: [newPrimary])
                } else {
                    var chain = [newPrimary]
                    // Keep local Ollama as the availability fallback unless it IS the primary.
                    if newPrimary != "ollama", providerStore.providers.contains(where: { $0.id == "ollama" }) {
                        chain.append("ollama")
                    }
                    providerStore.setChain(task: task, providerIDs: chain)
                }
                applyProviderChanges()
```

3. Update the caption under the pickers:

```swift
                Text("Chains fall back to Ollama, then the local regex pipeline — dictation keeps working offline no matter what. \"Local rules only\" skips LLM polish entirely and never loads a model.")
```

In `Sources/VoxFlowApp/Views/CommandPaletteView.swift`, `polishProviderIndicator` — replace the body with a three-state render (find it by the `R3.7 mode-in-use indicator` comment):

```swift
    /// R3.7 mode-in-use indicator: which provider serves polish right now.
    /// Orange = degraded to the local regex fallback (provider chain down).
    /// "rules · local" = the user CHOSE the rules floor (not degraded).
    @ViewBuilder private var polishProviderIndicator: some View {
        let provider = state.backendReadiness.activePolishProvider
        let model = state.backendReadiness.activePolishModel
        let isRules = provider == ProviderConfigStore.rulesSentinel
        if state.backendReadiness.processRunning || !provider.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: provider.isEmpty ? "exclamationmark.triangle" : (isRules ? "text.badge.checkmark" : "brain"))
                    .font(VF.microFont)
                Text(provider.isEmpty ? "regex fallback" : (isRules ? "rules · local" : (model.isEmpty ? provider : "\(provider) · \(model)")))
                    .font(VF.microFont)
                    .lineLimit(1)
            }
            .foregroundStyle(provider.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .accessibilityLabel(provider.isEmpty
                ? "Polish degraded to regex fallback"
                : (isRules ? "Polish served by local rules (chosen)" : "Polish served by \(provider)"))
            .help(provider.isEmpty
                  ? "No polish provider reachable — output uses the local rules pipeline"
                  : (isRules
                     ? "Local rules only — polish never loads an LLM"
                     : "Polish provider: \(provider) \(model)"))
        }
    }
```

In `Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift`, `modelPill` (~line 45):

```swift
    private var modelPill: some View {
        // R3.7: provenance from /v1/ready — which provider/model the polish
        // chain would use right now. Empty provider = regex fallback
        // (degraded, orange); "rules" = user-chosen rules floor (neutral).
        let provider = state.backendReadiness.activePolishProvider
        let model = state.backendReadiness.activePolishModel
        let isRules = provider == ProviderConfigStore.rulesSentinel
        let label = provider.isEmpty
            ? "regex fallback"
            : (isRules ? "rules · local" : (model.isEmpty ? provider : "\(provider) · \(model)"))
        return pill(label, tint: provider.isEmpty ? VF.colorWarning : VF.colorNeutral)
            .accessibilityLabel(provider.isEmpty
                ? "Polish degraded to regex fallback"
                : (isRules ? "Polish served by local rules (chosen)" : "Polish served by \(label)"))
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build 2>&1 | tail -3` — Expected: `Build complete!`
Run: `swift test 2>&1 | tail -3` — Expected: 0 failures (Task 2 + Task 3 + these 4 new tests over the 671 baseline).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/ProviderConfigStore.swift Sources/VoxFlowApp/Views/SettingsView.swift Sources/VoxFlowApp/Views/CommandPaletteView.swift Sources/VoxFlowApp/Views/Cockpit/CockpitTopBarView.swift Tests/VoxFlowAppTests/ProviderConfigStoreTests.swift
git commit -m "feat: 'Local rules only' polish setting (swift side)

Polish picker gains a rules-only row writing the reserved 'rules' chain
sentinel; ProviderConfigStore keeps the sentinel through pruning,
truncates after it, and rejects a provider named 'rules'. Palette
footer and cockpit pill render provider=rules as neutral
'rules · local' (chosen), distinct from the orange degraded regex
fallback.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: docs + end-to-end verification

**Files:**
- Modify: `CLAUDE.md` (providers.json bullet), `CHANGELOG.md` (two Unreleased entries)
- Verification only otherwise.

- [ ] **Step 1: Update docs**

In `CLAUDE.md`, find the BYOM config bullet in Key Patterns (starts "BYOM config: `~/Library/Application Support/VoxFlow/providers.json`") and append to it:

```
The reserved chain id `rules` (`"polish": ["rules"]`, Settings → "Local rules only") short-circuits polish to the regex floor with `served_by="rules"` — chosen, not degraded; a provider may never be named `rules`.
```

In `CHANGELOG.md` under `## [Unreleased]` / `### Added`:

```markdown
- "Local rules only" polish setting: a reserved `rules` chain id that serves
  the regex floor deliberately (`served_by=rules`, neutral indicator) and
  never probes or loads a local LLM for polish. Smart actions unchanged.
- Corpus-backed cleanup rules (mirrored Swift/Python, shared parity
  fixture): punctuation-orphan repair, punctuation-aware filler matching,
  stutter dedup, ellipsis recase exclusion.
```

- [ ] **Step 2: Full suites**

Run: `swift test 2>&1 | tail -3` and `./.venv/bin/python -m pytest backend/tests -q 2>&1 | tail -2`
Expected: 0 failures both sides.

- [ ] **Step 3: Live verification (requires the user)**

1. `./scripts/reinstall_and_launch.sh`
2. In Settings → set "Polish provider" to "Local rules only" (backend restarts).
3. `curl -s http://127.0.0.1:8765/v1/ready | grep -o '"active_polish_provider":"[^"]*"'` — Expected: `"active_polish_provider":"rules"`.
4. `cat ~/Library/Application\ Support/VoxFlow/providers.json` — Expected: `"polish": ["rules"]`.
5. User dictates once with insert behavior polish → receipt source reads `polish · rules`; `curl -s localhost:11434/api/ps` stays `{"models":[]}` (no model loaded).
6. Indicator check: palette footer shows neutral "rules · local" (not orange).
7. Ask the user whether to LEAVE rules-only active (their stated preference) or restore the Ollama primary — do not decide for them.

- [ ] **Step 4: Commit docs**

```bash
git add CLAUDE.md CHANGELOG.md
git commit -m "docs: rules-only polish + corpus cleanup rules (changelog, CLAUDE.md)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Report**

Report actual observed behavior (receipt provenance, ready fields, api/ps emptiness) back before merging. The standing acceptance check for part (b) lives beyond this branch: future receipts should show the four artifact classes at ~zero (re-run the mining script after a week of field use).
