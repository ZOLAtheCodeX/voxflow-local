import XCTest
@testable import VoxFlowApp

/// R5.0: successive dictations concatenated without separators
/// ("test.I've tested") — insertions are now boundary-aware.
final class SmartSpacingTests: XCTestCase {

    func testInsertsSpaceAfterSentencePunctuation() {
        XCTAssertEqual(SmartSpacing.adjusted("I've tested it.", precedingCharacter: "."), " I've tested it.")
        XCTAssertEqual(SmartSpacing.adjusted("next point", precedingCharacter: "!"), " next point")
        XCTAssertEqual(SmartSpacing.adjusted("and then", precedingCharacter: "d"), " and then")
    }

    func testNoSpaceWhenBoundaryAlreadyClean() {
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: " "), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "\n"), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: nil), "hello", "empty field / unknown context stays untouched")
    }

    func testNoSpaceAfterOpeningBrackets() {
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "("), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "["), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "\""), "hello")
    }

    func testNoSpaceWhenInsertionStartsWithPunctuationOrSpace(){
        XCTAssertEqual(SmartSpacing.adjusted(", continued", precedingCharacter: "d"), ", continued")
        XCTAssertEqual(SmartSpacing.adjusted(" already spaced", precedingCharacter: "."), " already spaced")
    }
}
