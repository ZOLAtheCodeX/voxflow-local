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
