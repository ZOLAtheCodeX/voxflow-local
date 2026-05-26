import AppKit
import XCTest
@testable import VoxFlowApp

@MainActor
final class PromptWorkflowCoordinatorTests: XCTestCase {

    private final class FakeTextInsertionCoordinator: TextInsertionCoordinating {
        var shouldSucceed = true
        var insertedText: String?
        var statusSuffix: String?
        var insertCallCount = 0

        func insertCurrentText() {}
        func insertCurrentText(targetApp: NSRunningApplication?) {}

        func insertText(_ text: String, statusSuffix: String) -> Bool {
            insertText(text, statusSuffix: statusSuffix, targetApp: nil)
        }

        func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) -> Bool {
            insertCallCount += 1
            insertedText = text
            self.statusSuffix = statusSuffix
            return shouldSucceed
        }

        func copyCurrentText() {}
        func copyMeetingMarkdownTemplate() {}
        func copyMeetingNotionTemplate() {}
    }

    private func makeSUT() -> (PromptWorkflowCoordinator, AppState, FakeTextInsertionCoordinator) {
        let state = AppState()
        let textInsertion = FakeTextInsertionCoordinator()
        let sut = PromptWorkflowCoordinator(state: state, textInsertion: textInsertion)
        return (sut, state, textInsertion)
    }

    func testLocalPromptWorkflowBuildsCandidateAndLeavesReviewState() async throws {
        let (sut, state, textInsertion) = makeSUT()
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true,
            hasInsertionCursor: true,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            role: "AXTextField",
            processIdentifier: nil
        )

        var recordedStages: [String] = []
        let request = PromptWorkflowRequest(
            sessionID: "prompt-1",
            rawText: "draft an email to the team about the new timeline",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .alwaysReview,
            sttBackend: .whisperKit,
            targetApp: nil
        )

        try await sut.processPrompt(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(state.promptCandidate?.rawText, request.rawText)
        XCTAssertEqual(state.promptCandidate?.detectedIntent, .email)
        XCTAssertTrue(state.promptCandidate?.framedPrompt.contains("Draft an email") == true)
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertEqual(state.statusLine, "Review prompt and insert")
        XCTAssertEqual(textInsertion.insertCallCount, 0)
        XCTAssertEqual(recordedStages, ["cleanup_polish_local", "prompt_frame"])
    }

    func testLocalPromptWorkflowAutoInsertsFramedPrompt() async throws {
        let (sut, state, textInsertion) = makeSUT()
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true,
            hasInsertionCursor: true,
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            role: "AXTextField",
            processIdentifier: nil
        )

        var recordedStages: [String] = []
        let request = PromptWorkflowRequest(
            sessionID: "prompt-2",
            rawText: "write a function that reverses a linked list",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertLight,
            sttBackend: .whisperKit,
            targetApp: nil
        )

        try await sut.processPrompt(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(state.promptCandidate?.detectedIntent, .code)
        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.insertedText, state.promptCandidate?.framedPrompt)
        XCTAssertEqual(textInsertion.statusSuffix, "Prompt inserted (Code — Xcode)")
        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertEqual(recordedStages, ["cleanup_polish_local", "prompt_frame", "insert"])
    }
}
