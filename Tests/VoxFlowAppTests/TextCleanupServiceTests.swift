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
}
