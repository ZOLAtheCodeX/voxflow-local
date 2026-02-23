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

    func testAlwaysFilteredMusicNotes() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266A}", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266A}\u{266A}\u{266A}", shortAudio: false))
    }

    func testAlwaysFilteredEllipsis() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("...", shortAudio: false))
    }

    func testAlwaysFilteredEmpty() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("   ", shortAudio: false))
    }

    func testShortOnlyFilteredOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you", shortAudio: true))
    }

    func testGreetingHallucinationsFilteredOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hello", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hello.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("hey", shortAudio: true))
    }

    func testGreetingsPassOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hi", shortAudio: false))
    }

    func testShortOnlyPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: false))
    }

    func testRepeatedWordFilteredOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("the the the the", shortAudio: true))
    }

    func testRepeatedWordPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: false))
    }

    func testTwoRepeatedWordsNotFiltered() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("yes yes", shortAudio: true))
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

    // MARK: - Unicode hallucination variants (review fix coverage)

    func testUnicodeEllipsisFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{2026}", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{2026}", shortAudio: true))
    }

    func testMusicNoteVariantsFiltered() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266B}", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("\u{266C}", shortAudio: false))
    }

    // MARK: - Greeting edge cases

    func testGreetingPunctuationVariantsOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hi.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Hey.", shortAudio: true))
    }

    func testGreetingCaseInsensitiveOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HELLO", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HI", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("HEY", shortAudio: true))
    }

    func testWhitespaceTrimmedBeforeFiltering() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination(" hello ", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("  Thank you for watching.  ", shortAudio: false))
    }
}
