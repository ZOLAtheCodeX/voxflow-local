import XCTest
@testable import VoxFlowApp

/// Pure-logic tests for AccessibilityInsertService decisions. NEVER construct
/// the real service here — it performs genuine AX insertions and CGEvent
/// posts (the ghost-"hello" incident class). Only nonisolated statics.
final class AccessibilityInsertLogicTests: XCTestCase {
    func testFocusMustBelongToFrozenTarget() {
        XCTAssertTrue(AccessibilityInsertService.ownsFocusedElement(targetPID: 101, focusedPID: 101))
        XCTAssertFalse(AccessibilityInsertService.ownsFocusedElement(targetPID: 101, focusedPID: 202))
        XCTAssertFalse(AccessibilityInsertService.ownsFocusedElement(targetPID: nil, focusedPID: 202))
        XCTAssertFalse(AccessibilityInsertService.ownsFocusedElement(targetPID: 101, focusedPID: nil))
        XCTAssertFalse(AccessibilityInsertService.ownsFocusedElement(targetPID: 0, focusedPID: 0))
    }

    func testVerbatimPolicyPreservesCLIInvocationAtAnyBoundary() {
        for preceding: Character? in [nil, "x", ".", " ", "\n"] {
            XCTAssertEqual(TextInsertionPolicy.verbatim.adjusted("/research", precedingCharacter: preceding), "/research")
            XCTAssertEqual(TextInsertionPolicy.verbatim.adjusted("$research --local", precedingCharacter: preceding), "$research --local")
        }
        XCTAssertEqual(TextInsertionPolicy.prose.adjusted("Next", precedingCharacter: "."), " Next")
    }

    /// Session 29 review: simulatePaste returning true only proves the Cmd+V
    /// event was POSTED. Under secure event input the target never receives
    /// it — reporting success wrote an "Inserted" receipt and status line
    /// while the text landed nowhere (not in the app, not in the clipboard:
    /// the paste path restores the user's previous clipboard). The outcome
    /// mapper must convert that case to an explicit failure so the caller's
    /// copy-to-clipboard fallback and an honest receipt fire.
    func testPostedPasteUnderSecureInputIsFailure() {
        let result = AccessibilityInsertService.pasteOutcome(
            posted: true, secureInputActive: true)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, "SECURE_INPUT_BLOCKED")
        XCTAssertEqual(result.method, .failed)
    }

    func testPostedPasteWithoutSecureInputIsSuccess() {
        let result = AccessibilityInsertService.pasteOutcome(
            posted: true, secureInputActive: false)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.method, .simulatedPaste)
        XCTAssertTrue(result.fallbackUsed)
    }

    func testUnpostedPasteIsFailure() {
        let result = AccessibilityInsertService.pasteOutcome(
            posted: false, secureInputActive: false)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, "INSERT_FAILED")
    }
}
