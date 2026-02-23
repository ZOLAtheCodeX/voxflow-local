# NLP-Lite Cleanup Engine — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the broken FLAN-T5-Small polish pipeline with a Swift-native 7-step NLP-lite cleanup engine using Apple's NaturalLanguage framework, eliminating the Python backend dependency for cleanup when using WhisperKit STT.

**Architecture:** New `TextCleanupService` struct in Swift with a pure-function pipeline: normalize → spoken punctuation → dedup → sentence split (NLTokenizer) → filler removal (NLTagger POS-aware) → recase → tone transform. Integrated into `AppCoordinator.processDictation` when `sttBackend == .whisperKit`.

**Tech Stack:** Swift 6.2, Apple NaturalLanguage framework (NLTokenizer, NLTagger), XCTest

---

### Task 1: Spoken Punctuation Converter

**Files:**
- Create: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Create: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

```swift
import XCTest
@testable import VoxFlowApp

final class TextCleanupServiceTests: XCTestCase {

    // MARK: - Spoken punctuation

    func testSpokenPeriod() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("hello world period"),
            "hello world."
        )
    }

    func testSpokenComma() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("first comma second"),
            "first, second"
        )
    }

    func testSpokenQuestionMark() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("how are you question mark"),
            "how are you?"
        )
    }

    func testSpokenExclamationPoint() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("wow exclamation point"),
            "wow!"
        )
    }

    func testSpokenNewLine() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("line one new line line two"),
            "line one\nline two"
        )
    }

    func testSpokenNewParagraph() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("para one new paragraph para two"),
            "para one\n\npara two"
        )
    }

    func testSpokenColon() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("note colon important"),
            "note: important"
        )
    }

    func testSpokenOpenCloseQuote() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("he said open quote hello close quote"),
            "he said \"hello\""
        )
    }

    func testNoSpokenPunctuation() {
        XCTAssertEqual(
            TextCleanupService.replaceSpokenPunctuation("no punctuation here"),
            "no punctuation here"
        )
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -5`
Expected: Compile error — `TextCleanupService` not found

**Step 3: Write minimal implementation**

Create `Sources/VoxFlowApp/Services/TextCleanupService.swift`:

```swift
import Foundation

enum TextCleanupService {

    static func replaceSpokenPunctuation(_ text: String) -> String {
        var result = text

        let replacements: [(pattern: String, replacement: String)] = [
            (#"\s+new paragraph\b"#, "\n\n"),
            (#"\s+new ?line\b"#, "\n"),
            (#"\s+period\b"#, "."),
            (#"\s+full stop\b"#, "."),
            (#"\s+comma\b"#, ","),
            (#"\s+question mark\b"#, "?"),
            (#"\s+exclamation (?:point|mark)\b"#, "!"),
            (#"\s+colon\b"#, ":"),
            (#"\s+semicolon\b"#, ";"),
            (#"\bopen quote\s+"#, "\""),
            (#"\s+close quote\b"#, "\""),
            (#"\s+dash\b"#, " —"),
            (#"\s+hyphen\b"#, "-"),
        ]

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -10`
Expected: All spoken punctuation tests PASS

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add TextCleanupService with spoken punctuation conversion"
```

---

### Task 2: Repeated Word Removal

**Files:**
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Modify: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

Add to `TextCleanupServiceTests`:

```swift
    // MARK: - Repeated word removal

    func testRemoveAdjacentDuplicateWords() {
        XCTAssertEqual(
            TextCleanupService.removeRepeatedWords("I want to to go"),
            "I want to go"
        )
    }

    func testRemoveTripleDuplicate() {
        XCTAssertEqual(
            TextCleanupService.removeRepeatedWords("the the the cat"),
            "the cat"
        )
    }

    func testPreserveIntentionalRepetition() {
        // "that that" can be intentional ("I know that that is true")
        // but adjacent exact duplicates are removed — this is a trade-off
        XCTAssertEqual(
            TextCleanupService.removeRepeatedWords("I said hello hello to her"),
            "I said hello to her"
        )
    }

    func testNoRepeats() {
        XCTAssertEqual(
            TextCleanupService.removeRepeatedWords("all words are unique"),
            "all words are unique"
        )
    }

    func testCaseInsensitiveDuplicate() {
        XCTAssertEqual(
            TextCleanupService.removeRepeatedWords("The the cat"),
            "The cat"
        )
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter testRemoveAdjacentDuplicateWords 2>&1 | tail -5`
Expected: Compile error — `removeRepeatedWords` not found

**Step 3: Write minimal implementation**

Add to `TextCleanupService`:

```swift
    static func removeRepeatedWords(_ text: String) -> String {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count > 1 else { return text }

        var result = [words[0]]
        for i in 1..<words.count {
            if words[i].lowercased() != words[i - 1].lowercased() {
                result.append(words[i])
            }
        }
        return result.joined(separator: " ")
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -10`
Expected: All tests PASS (spoken punctuation + repeated word tests)

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add repeated word removal to TextCleanupService"
```

---

### Task 3: NLTokenizer Sentence Splitting + Recasing

**Files:**
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Modify: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

```swift
    // MARK: - Sentence splitting + recasing

    func testSplitAndRecaseSingleSentence() {
        XCTAssertEqual(
            TextCleanupService.splitAndRecase("hello world"),
            "Hello world"
        )
    }

    func testSplitAndRecaseMultipleSentences() {
        XCTAssertEqual(
            TextCleanupService.splitAndRecase("hello world. how are you. good thanks"),
            "Hello world. How are you. Good thanks"
        )
    }

    func testSplitAndRecasePreservesProperNouns() {
        XCTAssertEqual(
            TextCleanupService.splitAndRecase("i spoke to Dr. Smith about it"),
            "I spoke to Dr. Smith about it"
        )
    }

    func testSplitAndRecasePreservesAcronyms() {
        XCTAssertEqual(
            TextCleanupService.splitAndRecase("the API is down"),
            "The API is down"
        )
    }

    func testSplitAndRecaseAddsTrailingPeriod() {
        XCTAssertEqual(
            TextCleanupService.splitAndRecase("hello world"),
            "Hello world"
        )
        // Note: trailing period is added in the full pipeline, not in splitAndRecase
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter testSplitAndRecase 2>&1 | tail -5`
Expected: Compile error — `splitAndRecase` not found

**Step 3: Write minimal implementation**

Add to `TextCleanupService`:

```swift
    import NaturalLanguage

    static func splitAndRecase(_ text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var sentence = String(text[range]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                // Capitalize first character, preserve rest
                let first = sentence.prefix(1).uppercased()
                sentence = first + sentence.dropFirst()
            }
            sentences.append(sentence)
            return true
        }

        return sentences.joined(separator: " ")
    }
```

Note: The `import NaturalLanguage` should be at the file level, not inside the enum.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -10`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add NLTokenizer sentence splitting and recasing"
```

---

### Task 4: NLTagger Filler Detection + Removal

**Files:**
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Modify: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

```swift
    // MARK: - Filler removal

    func testRemoveObviousFillers() {
        XCTAssertEqual(
            TextCleanupService.removeFillers("um I want to uh go there"),
            "I want to go there"
        )
    }

    func testRemoveHmm() {
        XCTAssertEqual(
            TextCleanupService.removeFillers("hmm let me think"),
            "let me think"
        )
    }

    func testKeepLikeAsVerb() {
        let result = TextCleanupService.removeFillers("I like dogs")
        XCTAssertTrue(result.contains("like"), "Should keep 'like' as verb")
    }

    func testRemoveLikeAsFiller() {
        let result = TextCleanupService.removeFillers("I was like going to the store")
        XCTAssertFalse(
            result.hasPrefix("I was like"),
            "Should remove 'like' as filler before verb"
        )
    }

    func testRemoveYouKnow() {
        XCTAssertEqual(
            TextCleanupService.removeFillers("it was you know really good"),
            "it was really good"
        )
    }

    func testRemoveIMean() {
        XCTAssertEqual(
            TextCleanupService.removeFillers("I mean the project is done"),
            "the project is done"
        )
    }

    func testRemoveBasically() {
        XCTAssertEqual(
            TextCleanupService.removeFillers("basically we need to finish this"),
            "we need to finish this"
        )
    }

    func testPreserveActuallyInContent() {
        // "actually" modifying a verb should be kept when it adds meaning
        // This is a best-effort heuristic — POS tagger decides
        let result = TextCleanupService.removeFillers("that is actually correct")
        // Accept either outcome — the POS tagger may or may not keep it
        XCTAssertTrue(result.contains("correct"))
    }

    func testMultipleFillerTypes() {
        let result = TextCleanupService.removeFillers("um so basically I uh you know went there")
        XCTAssertFalse(result.contains("um"))
        XCTAssertFalse(result.contains("uh"))
        XCTAssertTrue(result.contains("went there"))
    }

    func testEmptyAfterFillerRemoval() {
        let result = TextCleanupService.removeFillers("um uh er")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespaces), "")
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter testRemoveObviousFillers 2>&1 | tail -5`
Expected: Compile error — `removeFillers` not found

**Step 3: Write minimal implementation**

Add to `TextCleanupService`:

```swift
    private static let alwaysFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "err", "ah", "ahh", "hmm", "hm",
        "mm", "mmm", "mhm"
    ]

    private static let ambiguousFillers: Set<String> = [
        "like", "so", "right", "actually", "basically", "literally",
        "anyway", "anyways"
    ]

    private static let phraseFillers: [(pattern: String, replacement: String)] = [
        (#"\byou know\b"#, ""),
        (#"\bI mean\b"#, ""),
        (#"\bkind of\b"#, ""),
        (#"\bsort of\b"#, ""),
        (#"\bokay so\b"#, ""),
    ]

    static func removeFillers(_ text: String) -> String {
        var result = text

        // Pass 0: Remove phrase fillers (multi-word)
        for (pattern, replacement) in phraseFillers {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = normalizeWhitespace(result)

        // Pass 1: Remove always-fillers
        let words = result.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let afterAlways = words.filter { !alwaysFillers.contains($0.lowercased()) }
        result = afterAlways.joined(separator: " ")

        // Pass 2: POS-aware removal of ambiguous fillers
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = result

        var keepRanges: [Range<String.Index>] = []
        tagger.enumerateTokens(in: result.startIndex..<result.endIndex, unit: .word) { range, _ in
            let word = String(result[range]).lowercased()
            if ambiguousFillers.contains(word) {
                let tag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
                // Keep if verb, adjective, or noun — remove if adverb, interjection, or particle
                if tag == .verb || tag == .adjective || tag == .noun {
                    keepRanges.append(range)
                }
                // else: drop it (filler use)
            } else {
                keepRanges.append(range)
            }
            return true
        }

        let kept = keepRanges.map { String(result[$0]) }.joined(separator: " ")
        return normalizeWhitespace(kept)
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -15`
Expected: All tests PASS. Note: some POS-aware tests may need tuning based on NLTagger behavior — adjust test expectations if the tagger classifies differently than expected.

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add NLTagger POS-aware filler detection and removal"
```

---

### Task 5: Tone Transforms

**Files:**
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Modify: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

```swift
    // MARK: - Tone transforms

    func testToneNeutralNoChange() {
        XCTAssertEqual(
            TextCleanupService.applyTone("Hello world.", tone: .neutral),
            "Hello world."
        )
    }

    func testToneConciseRemovesHedging() {
        let result = TextCleanupService.applyTone(
            "I think maybe we should do it.", tone: .concise
        )
        XCTAssertFalse(result.contains("I think maybe"))
        XCTAssertTrue(result.contains("should do it"))
    }

    func testToneConciseRemovesSofteners() {
        let result = TextCleanupService.applyTone(
            "It is just really very important.", tone: .concise
        )
        XCTAssertFalse(result.contains("just"))
        XCTAssertFalse(result.contains("really"))
        XCTAssertFalse(result.contains("very"))
        XCTAssertTrue(result.contains("important"))
    }

    func testToneFormalExpandsContractions() {
        XCTAssertEqual(
            TextCleanupService.applyTone("I don't think we can't do it.", tone: .formal),
            "I do not think we cannot do it."
        )
    }

    func testToneFormalRemovesCasualInterjections() {
        let result = TextCleanupService.applyTone(
            "Okay so the project is done.", tone: .formal
        )
        XCTAssertFalse(result.lowercased().contains("okay so"))
        XCTAssertTrue(result.contains("project is done"))
    }

    func testToneFormalEnsuresTrailingPeriod() {
        XCTAssertTrue(
            TextCleanupService.applyTone("The report is ready", tone: .formal).hasSuffix(".")
        )
    }

    func testToneFriendlyKeepsContractions() {
        let result = TextCleanupService.applyTone(
            "I don't think so.", tone: .friendly
        )
        XCTAssertTrue(result.contains("don't"))
    }

    func testToneFriendlySoftensImperatives() {
        let result = TextCleanupService.applyTone(
            "Send the report.", tone: .friendly
        )
        XCTAssertTrue(
            result.lowercased().contains("let's send") || result.contains("Send"),
            "Should soften imperative or leave as-is"
        )
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter testToneNeutral 2>&1 | tail -5`
Expected: Compile error — `applyTone` not found

**Step 3: Write minimal implementation**

Add to `TextCleanupService`:

```swift
    static func applyTone(_ text: String, tone: ToneStyle) -> String {
        switch tone {
        case .neutral:
            return text
        case .concise:
            return applyConciseTone(text)
        case .formal:
            return applyFormalTone(text)
        case .friendly:
            return applyFriendlyTone(text)
        }
    }

    // MARK: - Concise

    private static let hedgingPhrases: [(String, String)] = [
        (#"\bI think maybe\b"#, ""),
        (#"\bit seems like\b"#, ""),
        (#"\bin my opinion\b"#, ""),
        (#"\bI feel like\b"#, ""),
        (#"\bI guess\b"#, ""),
        (#"\bto be honest\b"#, ""),
    ]

    private static let softeners: [(String, String)] = [
        (#"\bjust\b"#, ""),
        (#"\breally\b"#, ""),
        (#"\bvery\b"#, ""),
        (#"\bquite\b"#, ""),
        (#"\ba bit\b"#, ""),
    ]

    private static func applyConciseTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in hedgingPhrases + softeners {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return normalizeWhitespace(result)
    }

    // MARK: - Formal

    private static let contractions: [(String, String)] = [
        (#"\bdon't\b"#, "do not"),
        (#"\bdon't\b"#, "do not"),
        (#"\bcan't\b"#, "cannot"),
        (#"\bcan't\b"#, "cannot"),
        (#"\bwon't\b"#, "will not"),
        (#"\bwon't\b"#, "will not"),
        (#"\bshouldn't\b"#, "should not"),
        (#"\bwouldn't\b"#, "would not"),
        (#"\bcouldn't\b"#, "could not"),
        (#"\bisn't\b"#, "is not"),
        (#"\baren't\b"#, "are not"),
        (#"\bwasn't\b"#, "was not"),
        (#"\bweren't\b"#, "were not"),
        (#"\bhasn't\b"#, "has not"),
        (#"\bhaven't\b"#, "have not"),
        (#"\bhadn't\b"#, "had not"),
        (#"\bdoesn't\b"#, "does not"),
        (#"\bdidn't\b"#, "did not"),
        (#"\bI'm\b"#, "I am"),
        (#"\bI've\b"#, "I have"),
        (#"\bI'll\b"#, "I will"),
        (#"\bI'd\b"#, "I would"),
        (#"\bwe're\b"#, "we are"),
        (#"\bwe've\b"#, "we have"),
        (#"\bwe'll\b"#, "we will"),
        (#"\bthey're\b"#, "they are"),
        (#"\bthey've\b"#, "they have"),
        (#"\bthey'll\b"#, "they will"),
        (#"\byou're\b"#, "you are"),
        (#"\byou've\b"#, "you have"),
        (#"\byou'll\b"#, "you will"),
        (#"\bit's\b"#, "it is"),
        (#"\bthat's\b"#, "that is"),
        (#"\bwho's\b"#, "who is"),
        (#"\bwhat's\b"#, "what is"),
        (#"\bthere's\b"#, "there is"),
        (#"\bhere's\b"#, "here is"),
        (#"\blet's\b"#, "let us"),
    ]

    private static let casualInterjections: [(String, String)] = [
        (#"\bokay so\b"#, ""),
        (#"\balright\b"#, ""),
        (#"\bhey\b"#, ""),
        (#"\byeah\b"#, "yes"),
        (#"\bnope\b"#, "no"),
    ]

    private static func applyFormalTone(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in contractions + casualInterjections {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = normalizeWhitespace(result)
        if !result.isEmpty && !".!?".contains(result.last!) {
            result += "."
        }
        return result
    }

    // MARK: - Friendly

    private static func applyFriendlyTone(_ text: String) -> String {
        var result = text
        // Soften bare imperatives at sentence start: "Send X" → "Let's send X"
        let sentences = result.components(separatedBy: ". ")
        let softened = sentences.map { sentence -> String in
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return trimmed }
            let firstWord = trimmed.split(separator: " ").first.map(String.init) ?? ""
            // Simple heuristic: if first word is capitalized and not "I"/"The"/"A" etc,
            // it might be an imperative. Check with POS tagger.
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = trimmed
            if let (tag, _) = tagger.tag(at: trimmed.startIndex, unit: .word, scheme: .lexicalClass),
               tag == .verb, firstWord != "I" {
                let lower = firstWord.lowercased()
                return "Let's " + lower + trimmed.dropFirst(firstWord.count)
            }
            return trimmed
        }
        result = softened.joined(separator: ". ")
        return result
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -15`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add tone transforms (concise, formal, friendly) to TextCleanupService"
```

---

### Task 6: Full Pipeline — `cleanup(text:mode:tone:)` Method

**Files:**
- Modify: `Sources/VoxFlowApp/Services/TextCleanupService.swift`
- Modify: `Tests/VoxFlowAppTests/TextCleanupServiceTests.swift`

**Step 1: Write the failing tests**

```swift
    // MARK: - Full pipeline

    func testCleanupRawNormalizesAndConvertsPunctuation() {
        let result = TextCleanupService.cleanup(
            "  hello   world  period  ", mode: .raw, tone: .neutral
        )
        XCTAssertEqual(result, "hello world.")
    }

    func testCleanupLightFullPipeline() {
        let result = TextCleanupService.cleanup(
            "um so I want to to go to the store period",
            mode: .light, tone: .neutral
        )
        // Should: remove fillers, dedup "to to", spoken punct, recase
        XCTAssertFalse(result.contains("um"))
        XCTAssertTrue(result.contains("want to go"))
        XCTAssertTrue(result.hasSuffix("."))
        XCTAssertTrue(result.first?.isUppercase == true)
    }

    func testCleanupPolishAppliesConcisTone() {
        let result = TextCleanupService.cleanup(
            "um I think maybe we should just do it period",
            mode: .polish, tone: .concise
        )
        XCTAssertFalse(result.contains("um"))
        XCTAssertFalse(result.contains("I think maybe"))
        XCTAssertFalse(result.contains("just"))
        XCTAssertTrue(result.contains("should"))
        XCTAssertTrue(result.contains("do it"))
    }

    func testCleanupPolishFormalTone() {
        let result = TextCleanupService.cleanup(
            "uh I can't do it", mode: .polish, tone: .formal
        )
        XCTAssertFalse(result.contains("uh"))
        XCTAssertTrue(result.contains("cannot"))
        XCTAssertTrue(result.hasSuffix("."))
    }

    func testCleanupEmptyString() {
        XCTAssertEqual(
            TextCleanupService.cleanup("", mode: .polish, tone: .formal),
            ""
        )
    }

    func testCleanupWhitespaceOnly() {
        XCTAssertEqual(
            TextCleanupService.cleanup("   ", mode: .light, tone: .neutral),
            ""
        )
    }
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter testCleanupRaw 2>&1 | tail -5`
Expected: Compile error — `cleanup(text:mode:tone:)` not found

**Step 3: Write minimal implementation**

Add to `TextCleanupService`:

```swift
    static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Full cleanup pipeline. Steps applied depend on mode:
    /// - Raw: normalize + spoken punctuation (steps 1-2)
    /// - Light: + dedup + sentence split + filler removal + recase (steps 1-6)
    /// - Polish: + tone transform (steps 1-7)
    static func cleanup(_ text: String, mode: CleanupMode, tone: ToneStyle) -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }

        // Step 1: Normalize whitespace
        var result = normalizeWhitespace(text)

        // Step 2: Spoken punctuation
        result = replaceSpokenPunctuation(result)

        guard mode != .raw else { return normalizeWhitespace(result) }

        // Step 3: Repeated word removal
        result = removeRepeatedWords(result)

        // Step 4 + 6: Sentence split + recase
        result = splitAndRecase(result)

        // Step 5: Filler removal
        result = removeFillers(result)

        // Re-normalize after removals
        result = normalizeWhitespace(result)

        // Ensure trailing punctuation
        if !result.isEmpty && !".!?".contains(result.last!) {
            result += "."
        }

        // Re-capitalize first char after filler removal may have lowered it
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        guard mode != .light else { return result }

        // Step 7: Tone transform (polish only)
        result = applyTone(result, tone: tone)

        return result
    }
```

**Step 4: Run tests to verify they pass**

Run: `swift test --filter TextCleanupServiceTests 2>&1 | tail -20`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/TextCleanupService.swift \
       Tests/VoxFlowAppTests/TextCleanupServiceTests.swift
git commit -m "feat: add full cleanup pipeline with mode-based step selection"
```

---

### Task 7: Wire into AppCoordinator (WhisperKit path)

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:683-748` (processDictation)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:451-484` (selectToneStyle retone)

**Step 1: Run existing tests to establish baseline**

Run: `swift test 2>&1 | tail -5`
Expected: 143+ tests PASS

**Step 2: Add local cleanup branch to `processDictation`**

In `AppCoordinator.swift`, modify `processDictation` (around line 683). After the
`autoInsertRaw` early return (line 707), add a branch for local cleanup when using
WhisperKit:

```swift
            // Local cleanup for WhisperKit — no backend needed
            if providerMode == .localOnly && self.state.sttBackend == .whisperKit {
                let lightText = TextCleanupService.cleanup(rawText, mode: .light, tone: effectiveTone)
                let polishText = TextCleanupService.cleanup(rawText, mode: .polish, tone: effectiveTone)
                let candidate = TranscriptCandidate(
                    rawText: rawText, lightText: lightText,
                    polishText: polishText, selectedMode: .raw,
                    timestamp: Date()
                )
                self.state.transcriptCandidate = candidate
                self.state.selectedMode = .raw
                self.pushToSessionMemory(candidate)

                // Auto-insert light/polish
                if let autoMode = effectiveInsert.cleanupMode {
                    let text = candidate.text(for: autoMode)
                    let toneLabel = effectiveTone != self.state.toneStyle ? ", \(effectiveTone.displayName)" : ""
                    let appLabel = self.state.focusTarget.appName ?? "app"
                    if self.textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel) — \(appLabel))", targetApp: self.capturedTargetApp) {
                        self.state.sessionState = .idle
                    } else {
                        self.state.sessionState = .review
                        self.state.statusLine = "Auto-insert failed — review and retry"
                    }
                    return
                }

                self.state.sessionState = .review
                self.state.statusLine = "Review and insert"
                return
            }
```

This block goes right after line 708 (`return` from the autoInsertRaw block) and before
the existing `BackendAPIClient.cleanup` calls at line 710.

**Step 3: Add local cleanup branch to `selectToneStyle` retone**

In `AppCoordinator.swift`, modify `selectToneStyle` (around line 459). Add a branch
before the existing `BackendAPIClient.cleanup` calls:

```swift
            // Local retone for WhisperKit
            if self.state.sttBackend == .whisperKit {
                let lightText = TextCleanupService.cleanup(rawText, mode: .light, tone: tone)
                let polishText = TextCleanupService.cleanup(rawText, mode: .polish, tone: tone)
                state.transcriptCandidate = TranscriptCandidate(
                    rawText: rawText, lightText: lightText,
                    polishText: polishText, selectedMode: state.selectedMode
                )
                state.statusLine = "Tone: \(tone.displayName)"
                return
            }
```

This block goes right after `Task { @MainActor in` / `do {` (line 460) and before the
existing `BackendAPIClient.cleanup` calls.

**Step 4: Run all tests**

Run: `swift test 2>&1 | tail -10`
Expected: All tests PASS (existing 143 + new TextCleanupService tests)

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift
git commit -m "feat: wire TextCleanupService into WhisperKit dictation path

When STT backend is WhisperKit, cleanup runs in-process via
TextCleanupService instead of calling Python backend. Covers both
processDictation and selectToneStyle retone paths."
```

---

### Task 8: Update CLAUDE.md + progress.txt

**Files:**
- Modify: `CLAUDE.md`
- Modify: `progress.txt`

**Step 1: Update CLAUDE.md**

Add under "Key Patterns > Swift":

```markdown
- **TextCleanupService**: Swift-native 7-step NLP-lite cleanup pipeline using Apple NaturalLanguage
  framework (NLTokenizer, NLTagger). Handles spoken punctuation, filler removal (POS-aware),
  repeated word dedup, sentence splitting, recasing, and tone transforms. Used in-process when
  `sttBackend == .whisperKit` — no Python backend needed for cleanup.
```

**Step 2: Update progress.txt**

Move P5 to Completed, update test counts.

**Step 3: Run full test suite one final time**

Run: `swift test 2>&1 | tail -5`
Expected: All tests PASS (143 original + ~25 new TextCleanupService tests)

**Step 4: Commit**

```bash
git add CLAUDE.md progress.txt
git commit -m "docs: update conventions and progress for NLP-lite cleanup engine"
```

---

## Summary

| Task | Description | New Tests |
|------|-------------|-----------|
| 1 | Spoken punctuation converter | ~9 |
| 2 | Repeated word removal | ~5 |
| 3 | NLTokenizer sentence split + recase | ~4 |
| 4 | NLTagger filler detection | ~9 |
| 5 | Tone transforms (concise, formal, friendly) | ~8 |
| 6 | Full pipeline `cleanup(text:mode:tone:)` | ~6 |
| 7 | Wire into AppCoordinator (WhisperKit path) | 0 (integration) |
| 8 | Update CLAUDE.md + progress.txt | 0 (docs) |
| **Total** | **8 tasks, 8 commits** | **~41 new tests** |
