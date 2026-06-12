import XCTest
@testable import VoxFlowApp

@MainActor
final class CockpitCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear chip-MRU UserDefaults so persistence from prior runs doesn't
        // bleed into invocation counts / promotion thresholds. AppState reads
        // these defaults at construction time.
        UserDefaults.standard.removeObject(forKey: AppState.chipMRUKey)
        UserDefaults.standard.removeObject(forKey: AppState.chipInvocationCountsKey)
    }

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

    func test_open_fires_onCockpitOpened() {
        let (_, coord, _, _) = makeCoordinator()
        var fired = 0
        coord.onCockpitOpened = { fired += 1 }
        coord.open()
        XCTAssertEqual(fired, 1)
    }

    func test_close_does_not_fire_onCockpitOpened() {
        let (_, coord, _, _) = makeCoordinator()
        coord.open()
        var fired = 0
        coord.onCockpitOpened = { fired += 1 }
        coord.close()
        XCTAssertEqual(fired, 0)
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

    // MARK: - Snippet expansion in review

    func test_handleVoiceUtterance_expands_snippet_during_review() async throws {
        let snippetStore = makeSnippetStore(seed: [
            VoiceSnippet(keyword: "signoff", text: "Best regards", scope: .global, createdAt: Date())
        ])
        let (_, coord, sessionService, _) = makeCoordinator(
            backend: StubSmartActionBackend(), snippetStore: snippetStore)
        sessionService.start()
        sessionService.appendChunk("source text")
        sessionService.stop()

        try await coord.handleVoiceUtterance("signoff")

        let transcript = try XCTUnwrap(sessionService.currentSession?.transcript)
        XCTAssertTrue(transcript.contains("Best regards"))
        // Appends, never replaces — the original content survives.
        XCTAssertTrue(transcript.contains("source text"))
    }

    func test_handleVoiceUtterance_reserved_word_does_not_expand_snippet() async throws {
        // A snippet keyword that collides with a reserved meta-word ("cancel")
        // must never expand — reserved/action-word precedence wins. "cancel"
        // resets the session, so the transcript must NOT contain the expansion.
        let snippetStore = makeSnippetStore(seed: [
            VoiceSnippet(keyword: "cancel", text: "SHOULD-NOT-APPEAR", scope: .global, createdAt: Date())
        ])
        let (_, coord, sessionService, _) = makeCoordinator(
            backend: StubSmartActionBackend(), snippetStore: snippetStore)
        sessionService.start()
        sessionService.appendChunk("source text")
        sessionService.stop()

        try await coord.handleVoiceUtterance("cancel")

        // "cancel" is reserved: it resets the session (currentSession == nil),
        // and crucially the snippet expansion never appears anywhere.
        XCTAssertNil(sessionService.currentSession)
    }

    func test_handleVoiceUtterance_expands_longFormOnly_snippet_in_cockpit() async throws {
        // A .longFormOnly snippet must expand in the cockpit review loop —
        // proves the call site passes context: .longFormOnly (not .quickOnly).
        let snippetStore = makeSnippetStore(seed: [
            VoiceSnippet(keyword: "agenda", text: "1. Intro", scope: .longFormOnly, createdAt: Date())
        ])
        let (_, coord, sessionService, _) = makeCoordinator(
            backend: StubSmartActionBackend(), snippetStore: snippetStore)
        sessionService.start()
        sessionService.appendChunk("source text")
        sessionService.stop()

        try await coord.handleVoiceUtterance("agenda")

        let transcript = try XCTUnwrap(sessionService.currentSession?.transcript)
        XCTAssertTrue(transcript.contains("1. Intro"))
        XCTAssertTrue(transcript.contains("source text"))
    }

    func test_handleVoiceUtterance_does_not_expand_quickOnly_snippet_in_cockpit() async throws {
        // A .quickOnly snippet must NOT expand in the cockpit review loop —
        // proves the cockpit context (.longFormOnly) gates out .quickOnly scope.
        let snippetStore = makeSnippetStore(seed: [
            VoiceSnippet(keyword: "agenda", text: "SHOULD-NOT-APPEAR", scope: .quickOnly, createdAt: Date())
        ])
        let (_, coord, sessionService, _) = makeCoordinator(
            backend: StubSmartActionBackend(), snippetStore: snippetStore)
        sessionService.start()
        sessionService.appendChunk("source text")
        sessionService.stop()
        let before = try XCTUnwrap(sessionService.currentSession?.transcript)

        try await coord.handleVoiceUtterance("agenda")

        let after = try XCTUnwrap(sessionService.currentSession?.transcript)
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.contains("SHOULD-NOT-APPEAR"))
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

    private func makeCoordinator(
        backend: SmartActionBackend,
        snippetStore: SnippetStore? = nil
    ) -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        let state = AppState()
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxflow-cockpit-test-\(UUID().uuidString)")
        let sessionService = LongFormSessionService(autoSaveDirectory: sessionDir)
        let actionService = SmartActionService(backend: backend)
        let coord = CockpitCoordinator(
            state: state,
            sessionService: sessionService,
            actionService: actionService,
            textInsertionCoordinator: nil,
            snippetStore: snippetStore
        )
        return (state, coord, sessionService, actionService)
    }

    /// Builds a SnippetStore over a throwaway temp file with seeding disabled,
    /// then injects the supplied snippets so tests control the exact set.
    private func makeSnippetStore(seed: [VoiceSnippet]) -> SnippetStore {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxflow-snippets-test-\(UUID().uuidString).json")
        let store = SnippetStore(fileURL: fileURL, seedOnFirstRun: false)
        for snippet in seed {
            store.add(keyword: snippet.keyword, text: snippet.text, scope: snippet.scope)
        }
        return store
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
