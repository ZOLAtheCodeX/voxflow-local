import XCTest
@testable import VoxFlowApp

final class HallucinationFilterTests: XCTestCase {

    func testAlwaysFilteredThankYouForWatching() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you for watching.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you for watching!", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("thanks for watching.", shortAudio: false))
    }

    func testAlwaysFilteredSubscribe() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Subscribe to my channel.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Like and subscribe.", shortAudio: false))
    }

    func testAlwaysFilteredEmpty() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("   ", shortAudio: false))
    }

    func testShortOnlyFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you", shortAudio: true))
    }

    func testGreetingHallucinationsFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hello", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hello.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hey", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hello", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hey.", shortAudio: false))
    }

    func testRepeatedWordFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("the the the the", shortAudio: true))
    }

    func testValidDictationPasses() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Send the report to the team by Friday", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello world", shortAudio: true))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("I need to update the project plan", shortAudio: false))
    }

    /// Regression guard: a single legitimate word must NOT be discarded. The
    /// repeat heuristic (`Set(words).count == 1`) is trivially true for one
    /// word, so without a `count >= 2` guard every lone word a user dictates
    /// ("Approved", a name, a number) vanished. Single-word dictation is a
    /// first-class use case for a dictation tool.
    func testLegitSingleWordPasses() {
        for word in ["Banana", "Seattle", "Approved", "Cancelled", "Done", "Stop", "Friday"] {
            XCTAssertFalse(
                HallucinationFilter.isLikelyHallucination(word, shortAudio: false),
                "Single legit word '\(word)' was wrongly filtered (long audio)")
            XCTAssertFalse(
                HallucinationFilter.isLikelyHallucination(word, shortAudio: true),
                "Single legit word '\(word)' was wrongly filtered (short audio)")
        }
        // F5 fix: Emphatic 2-word repeats now pass.
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Banana Banana", shortAudio: false))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("THANK YOU FOR WATCHING.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("subscribe to my channel.", shortAudio: false))
    }

    func testUnicodeEllipsisFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{2026}", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{2026}", shortAudio: true))
    }

    func testMusicNoteVariantsFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266B}", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266C}", shortAudio: false))
    }

    func testGreetingPunctuationVariants() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hey.", shortAudio: true))
    }

    func testGreetingCaseInsensitive() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HELLO", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HI", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HEY", shortAudio: true))
    }

    func testWhitespaceTrimmedBeforeFiltering() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(" hello ", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("  Thank you for watching.  ", shortAudio: false))
    }

    func testGreetingPunctuationVariantsFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hello!", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hello?", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hello,", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hello;", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hello...", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi!", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hey?", shortAudio: false))
    }

    func testShortOnlyPunctuationVariantsFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thanks!", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Bye!", shortAudio: true))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Thanks!", shortAudio: false))
    }

    func testShortOnlyPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("you", shortAudio: false))
    }

    func testRepeatedWordPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("the the the the", shortAudio: false))
    }

    func testBracketNotePasses() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("[note] there was background noise", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("[keyboard clacking]", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("(typing)", shortAudio: true))
    }

    func testMultiWordPhrasesNotAffectedByNormalization() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello world!", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hey, can you help me?", shortAudio: true))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("I'm watching the kids", shortAudio: false))
    }

    // MARK: - Behavioral parity fixture (shared contract with backend filter)

    /// Both this filter and backend/app/nlp/hallucination.py must satisfy every
    /// case in Tests/Fixtures/hallucination_parity.json. Replaces the old
    /// regex-on-source parity test that silently broke on the token rewrite.
    func testParityFixtureCasesHold() throws {
        struct ParityCase: Decodable {
            let text: String
            let short_audio: Bool
            let expected: Bool
            let note: String?
        }
        struct ParityFixture: Decodable {
            let cases: [ParityCase]
        }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/VoxFlowAppTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/hallucination_parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: data)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 40, "Fixture unexpectedly small — wrong file?")

        var failures: [String] = []
        for c in fixture.cases {
            let got = HallucinationFilter.isLikelyHallucination(c.text, shortAudio: c.short_audio)
            if got != c.expected {
                failures.append("'\(c.text)' (short=\(c.short_audio)): expected \(c.expected), got \(got) — \(c.note ?? "")")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Parity contract violations:\n" + failures.joined(separator: "\n"))
    }
}
