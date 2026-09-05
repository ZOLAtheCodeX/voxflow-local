import XCTest
@testable import VoxFlowApp

final class AutoSubmitModeTests: XCTestCase {
    func testSelectableScopesKeepPromptsAndOrdinaryDictationIndependent() {
        let expected: [(AutoSubmitMode, Bool, Bool)] = [
            (.off, false, false), (.voiceActionPrompts, true, false),
            (.ordinaryDictation, false, true), (.both, true, true)
        ]
        for (mode, prompts, dictation) in expected {
            XCTAssertEqual(mode.includes(voiceActionPrompt: true), prompts)
            XCTAssertEqual(mode.includes(voiceActionPrompt: false), dictation)
        }
    }

    func testNewAndUnrecognizedSettingsStayOffAndChoicesPersist() throws {
        let suite = "voxflow-auto-submit-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AutoSubmitMode.load(from: defaults), .off)
        defaults.set("future-mode", forKey: AutoSubmitMode.defaultsKey)
        XCTAssertEqual(AutoSubmitMode.load(from: defaults), .off)
        for mode in AutoSubmitMode.allCases {
            mode.save(to: defaults)
            XCTAssertEqual(AutoSubmitMode.load(from: defaults), mode)
        }
    }

    func testSubmissionPreservesExactCommandAndProseSpacingPolicies() {
        let command = TextInsertionPolicy.verbatim.withSubmission(true)
        XCTAssertTrue(command.submits)
        XCTAssertEqual(command.adjusted("$research --local", precedingCharacter: "x"), "$research --local")
        XCTAssertEqual(command.withSubmission(false), .verbatim)
        let prose = TextInsertionPolicy.prose.withSubmission(true)
        XCTAssertEqual(prose.adjusted("Next", precedingCharacter: "."), " Next")
        XCTAssertEqual(prose.withSubmission(false), .prose)
    }

    func testEnterIsRefusedAfterCancellationOrAnyTargetGuardFailure() {
        XCTAssertTrue(AccessibilityInsertService.maySubmit(cancelled: false, targetActive: true,
            targetTerminated: false, focusUnchanged: true, secureInputActive: false))
        for failedGuard in 0..<5 {
            XCTAssertFalse(AccessibilityInsertService.maySubmit(cancelled: failedGuard == 0,
                targetActive: failedGuard != 1, targetTerminated: failedGuard == 2,
                focusUnchanged: failedGuard != 3, secureInputActive: failedGuard == 4))
        }
    }

    func testCapturedIdentityBlocksOtherWindowsAndFieldsInTheSameApp() {
        let capture = InsertionFocusSnapshot(processID: 101, window: "document-a", field: "prompt-a")
        XCTAssertTrue(capture.matches(capture, requireKnown: true))
        for changed in [
            InsertionFocusSnapshot(processID: 202, window: "document-a", field: "prompt-a"),
            InsertionFocusSnapshot(processID: 101, window: "document-b", field: "prompt-a"),
            InsertionFocusSnapshot(processID: 101, window: "document-a", field: "prompt-b"),
            InsertionFocusSnapshot(processID: 101, window: nil, field: "prompt-a"),
            InsertionFocusSnapshot(processID: 101, window: "document-a", field: nil)
        ] {
            XCTAssertFalse(capture.matches(changed, requireKnown: false))
            XCTAssertFalse(capture.matches(changed, requireKnown: true))
        }
    }

    func testUnknownFocusCanUseTextFallbackButCannotAuthorizeEnter() {
        for capture: InsertionFocusSnapshot<String> in [
            .init(processID: 101, window: nil, field: nil),
            .init(processID: 101, window: "window", field: nil),
            .init(processID: 101, window: nil, field: "field")
        ] {
            XCTAssertTrue(capture.matches(capture, requireKnown: false))
            XCTAssertFalse(capture.matches(capture, requireKnown: true))
        }
        let unavailable = InsertionFocusSnapshot<String>(processID: 0, window: nil, field: nil)
        XCTAssertFalse(unavailable.matches(unavailable, requireKnown: false))
    }
}
