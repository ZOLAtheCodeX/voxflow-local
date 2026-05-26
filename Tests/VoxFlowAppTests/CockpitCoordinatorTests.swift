import XCTest
@testable import VoxFlowApp

@MainActor
final class CockpitCoordinatorTests: XCTestCase {

    // MARK: - Visibility

    func test_open_sets_cockpitVisible_true() {
        let (state, coord, _, _) = makeCoordinator()
        coord.open()
        XCTAssertTrue(state.cockpitVisible)
    }

    func test_close_sets_cockpitVisible_false() {
        let (state, coord, _, _) = makeCoordinator()
        coord.open()
        coord.close()
        XCTAssertFalse(state.cockpitVisible)
    }

    // MARK: - applyAction

    func test_applyAction_increments_invocation_count() async throws {
        let (state, coord, _, _) = makeCoordinator()
        _ = try await coord.applyAction(.memo, to: "raw")
        XCTAssertEqual(state.chipInvocationCounts[.memo], 1)
    }

    func test_applyAction_records_history_on_session() async throws {
        let (_, coord, sessionService, _) = makeCoordinator()
        sessionService.start()
        sessionService.appendChunk("raw transcript")
        sessionService.stop()
        _ = try await coord.applyAction(.memo, to: "raw transcript")
        XCTAssertEqual(sessionService.currentSession?.appliedActions.count, 1)
    }

    func test_applyAction_skips_history_when_guardrail_triggered() async throws {
        let (_, coord, sessionService, _) = makeCoordinatorWithGuardrailBackend()
        sessionService.start()
        sessionService.appendChunk("raw transcript")
        sessionService.stop()
        _ = try await coord.applyAction(.memo, to: "raw transcript")
        // Guardrail trips must not record an AppliedAction — the session JSON
        // would otherwise show entries that ⌘Z cannot undo (SmartActionService
        // already filters guardrail trips from its own undo stack).
        XCTAssertEqual(sessionService.currentSession?.appliedActions.count, 0)
    }

    func test_applyAction_skips_history_when_output_unchanged() async throws {
        let (_, coord, sessionService, _) = makeCoordinatorWithEchoBackend()
        sessionService.start()
        sessionService.appendChunk("identical transcript")
        sessionService.stop()
        _ = try await coord.applyAction(.memo, to: "identical transcript")
        XCTAssertEqual(sessionService.currentSession?.appliedActions.count, 0)
    }

    // MARK: - MRU promotion

    func test_chip_promoted_after_three_invocations() async throws {
        let (state, coord, _, _) = makeCoordinator()
        XCTAssertFalse(state.chipMRU.contains(.steel))
        for _ in 0..<3 {
            _ = try await coord.applyAction(.steel, to: "raw")
        }
        XCTAssertTrue(state.chipMRU.contains(.steel))
    }

    func test_chip_not_promoted_before_threshold() async throws {
        let (state, coord, _, _) = makeCoordinator()
        for _ in 0..<2 {
            _ = try await coord.applyAction(.steel, to: "raw")
        }
        XCTAssertFalse(state.chipMRU.contains(.steel))
    }

    func test_chip_order_reflects_usage_after_threshold() async throws {
        let (state, coord, _, _) = makeCoordinator()
        // 35 total invocations of `items` pushes it to the top.
        for _ in 0..<35 {
            _ = try await coord.applyAction(.items, to: "raw")
        }
        XCTAssertEqual(state.chipMRU.first, .items)
    }

    // MARK: - Voice commands gated on review state

    func test_handleVoiceUtterance_ignored_when_idle() async throws {
        let (state, coord, _, _) = makeCoordinator()
        try await coord.handleVoiceUtterance("memo")
        XCTAssertNil(state.chipInvocationCounts[.memo])
    }

    func test_handleVoiceUtterance_ignored_during_recording() async throws {
        let (state, coord, sessionService, _) = makeCoordinator()
        sessionService.start()
        try await coord.handleVoiceUtterance("memo")
        XCTAssertNil(state.chipInvocationCounts[.memo])
    }

    func test_handleVoiceUtterance_triggers_action_during_review() async throws {
        let (state, coord, sessionService, _) = makeCoordinator()
        sessionService.start()
        sessionService.appendChunk("source text")
        sessionService.stop()
        try await coord.handleVoiceUtterance("memo")
        XCTAssertEqual(state.chipInvocationCounts[.memo], 1)
    }

    // MARK: - didEnterReviewState

    func test_didEnterReviewState_increments_capture_count() {
        let (state, coord, _, _) = makeCoordinator()
        let before = state.totalCaptureCount
        coord.didEnterReviewState()
        XCTAssertEqual(state.totalCaptureCount, before + 1)
    }

    // MARK: - Helpers

    private func makeCoordinator() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: StubSmartActionBackend())
    }

    private func makeCoordinatorWithGuardrailBackend() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: GuardrailSmartActionBackend())
    }

    private func makeCoordinatorWithEchoBackend() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: EchoSmartActionBackend())
    }

    private func makeCoordinator(backend: SmartActionBackend) -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        let state = AppState()
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxflow-cockpit-test-\(UUID().uuidString)")
        let sessionService = LongFormSessionService(autoSaveDirectory: sessionDir)
        let actionService = SmartActionService(backend: backend)
        let coord = CockpitCoordinator(
            state: state,
            sessionService: sessionService,
            actionService: actionService,
            textInsertionCoordinator: nil
        )
        return (state, coord, sessionService, actionService)
    }
}

private final class StubSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action,
            output: "# transformed\n\n\(transcript)",
            guardrailTriggered: false,
            error: nil
        )
    }
}

private final class GuardrailSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action,
            output: "regex fallback",
            guardrailTriggered: true,
            error: nil
        )
    }
}

private final class EchoSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action,
            output: transcript,
            guardrailTriggered: false,
            error: nil
        )
    }
}
