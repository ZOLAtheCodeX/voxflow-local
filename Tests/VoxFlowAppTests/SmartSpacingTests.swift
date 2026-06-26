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

    // MARK: - effectivePrecedingCharacter (AX-unreadable fallback)
    // The AX read returns nil in Electron/web/terminals — the same apps that
    // fall back to paste — so smart-spacing silently no-opped there and
    // dictations ran together. The fallback uses our OWN last insertion into
    // the same target.

    func testAXReadWinsOverPriorInsertion() {
        let prior = SmartSpacing.PriorInsertion(targetPid: 42, trailingCharacter: "x")
        // When AX can read the field, that is the source of truth — prior is ignored.
        XCTAssertEqual(
            SmartSpacing.effectivePrecedingCharacter(axPreceding: ".", prior: prior, currentTargetPid: 42),
            "."
        )
    }

    func testFallsBackToPriorInsertionTrailingCharForSameTarget() {
        let prior = SmartSpacing.PriorInsertion(targetPid: 42, trailingCharacter: ".")
        // AX unreadable (nil) but we last inserted into pid 42 ending in "." —
        // use it so the next dictation gets a leading space.
        XCTAssertEqual(
            SmartSpacing.effectivePrecedingCharacter(axPreceding: nil, prior: prior, currentTargetPid: 42),
            "."
        )
    }

    func testDoesNotReusePriorInsertionAcrossDifferentTargets() {
        let prior = SmartSpacing.PriorInsertion(targetPid: 42, trailingCharacter: ".")
        // Different focused app — we know nothing about THIS field, so no guess.
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(axPreceding: nil, prior: prior, currentTargetPid: 99)
        )
    }

    func testNoFallbackWithoutPriorInsertion() {
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(axPreceding: nil, prior: nil, currentTargetPid: 42)
        )
    }

    func testNoFallbackWhenTargetPidUnknown() {
        // Prior insertion with an unknown (nil) pid can't be confirmed as the
        // same target, so we must not reuse it.
        let prior = SmartSpacing.PriorInsertion(targetPid: nil, trailingCharacter: ".")
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(axPreceding: nil, prior: prior, currentTargetPid: 42)
        )
    }

    func testFallbackThenAdjustedAddsSpaceInUnreadableApp() {
        // End-to-end of the bug: AX nil, prior insertion ended in "." into the
        // same target → the next insertion ("I've tested") gets its space.
        let prior = SmartSpacing.PriorInsertion(targetPid: 7, trailingCharacter: ".")
        let preceding = SmartSpacing.effectivePrecedingCharacter(
            axPreceding: nil, prior: prior, currentTargetPid: 7)
        XCTAssertEqual(SmartSpacing.adjusted("I've tested", precedingCharacter: preceding), " I've tested")
    }
}
