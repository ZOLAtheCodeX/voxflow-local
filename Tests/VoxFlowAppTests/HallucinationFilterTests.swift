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
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: false))
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
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("yes yes", shortAudio: true))
    }

    func testValidDictationPasses() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Send the report to the team by Friday", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello world", shortAudio: true))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("I need to update the project plan", shortAudio: false))
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
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thanks!", shortAudio: false))
    }

    func testMultiWordPhrasesNotAffectedByNormalization() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello world!", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hey, can you help me?", shortAudio: true))
        // "Hi there." -> "there" is in singleWordHallucinations now, so "hi there" is filtered.
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi there.", shortAudio: false))
    }
}
