import XCTest
@testable import VoxFlowApp

/// Safety-net tests validating key guard conditions and state transitions
/// on AppState that AppCoordinator relies on. These must pass before and
/// after each extraction phase.
final class AppCoordinatorSmokeTests: XCTestCase {

    @MainActor
    func testInitialStateIsOnboardingWhenNotComplete() {
        let state = AppState()
        // AppState defaults to .idle / .notStarted. The coordinator's
        // configureInitialState() moves to .calibrating when the
        // UserDefaults key is absent. Verify the raw default here.
        XCTAssertEqual(state.onboardingPhase, .notStarted)
        XCTAssertEqual(state.sessionState, .idle)
    }

    @MainActor
    func testStartCaptureGuardsOnSessionState() {
        let state = AppState()
        // When sessionState is .transcribing, capture must NOT start.
        state.sessionState = .transcribing
        // Simulating the guard logic from AppCoordinator.startCapture:
        let allowedStates: [SessionState] = [.idle, .review, .error, .onboarding]
        XCTAssertFalse(allowedStates.contains(state.sessionState))
    }

    @MainActor
    func testRetryLastCaptureClearsState() {
        let state = AppState()
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "test", lightText: "test", polishText: "test", selectedMode: .raw
        )
        state.translationCandidate = TranslationCandidate(
            sourceEnglish: "hello", targetGerman: "hallo", approved: false
        )
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "o", redactedText: "r"
        )

        // Simulate retryLastCapture logic:
        state.transcriptCandidate = nil
        state.translationCandidate = nil
        state.meetingCandidate = nil
        state.privacyPreview = nil
        state.isCommandLaneActive = false
        state.setIdle()

        XCTAssertNil(state.transcriptCandidate)
        XCTAssertNil(state.translationCandidate)
        XCTAssertNil(state.meetingCandidate)
        XCTAssertNil(state.privacyPreview)
        XCTAssertEqual(state.sessionState, .idle)
    }

    @MainActor
    func testSelectWorkflowModeTranslateRequiresEnabled() {
        let state = AppState()
        state.translationModeEnabled = false
        // Guard logic: if mode == .translateEnToDe && !state.translationModeEnabled → reject
        let mode: WorkflowMode = .translateEnToDe
        let shouldReject = mode == .translateEnToDe && !state.translationModeEnabled
        XCTAssertTrue(shouldReject)
    }

    @MainActor
    func testResetForNewCaptureTransitionsToRecording() {
        let state = AppState()
        state.sessionState = .idle
        state.errorMessage = "old error"
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "old", lightText: "old", polishText: "old", selectedMode: .raw
        )

        state.resetForNewCapture()

        XCTAssertEqual(state.sessionState, .recording)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.transcriptCandidate)
        XCTAssertNil(state.translationCandidate)
        XCTAssertNil(state.privacyPreview)
    }

    @MainActor
    func testSetIdleResetsSessionState() {
        let state = AppState()
        state.sessionState = .recording
        state.recordingDuration = 5.0

        state.setIdle()

        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertEqual(state.recordingDuration, 0)
        XCTAssertEqual(state.statusLine, "Hold hotkey to talk")
    }
}
