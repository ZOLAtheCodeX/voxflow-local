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

    func test_applyAction_surfaces_provider_unavailable_error() async throws {
        let (state, coord, _, _) = makeCoordinator(backend: ErroringSmartActionBackend())

        let result = try await coord.applyAction(.memo, to: "raw transcript")

        // The soft error must reach the user (the direct chip/voice path
        // previously discarded it, unlike ChainExecutor).
        XCTAssertEqual(result.error, "provider_unavailable")
        XCTAssertTrue(
            state.statusLine.lowercased().contains("provider")
                || state.statusLine.lowercased().contains("configure"),
            "provider_unavailable must be surfaced on the status line, got: \(state.statusLine)")
        // An errored action did nothing — it must not count as an invocation.
        XCTAssertEqual(state.chipInvocationCounts[.memo, default: 0], 0)
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

    // MARK: - ⌘↩ insert failure (session 29 review)

    /// The insert result used to be discarded: cockpit closed and the session
    /// reset identically on success and failure, so a failed insert was easy
    /// to miss and the transcript was only recoverable via app relaunch. On
    /// failure the cockpit stays open with the session intact (the text is
    /// in the clipboard via insertText's own fallback).
    func test_insert_failure_keeps_cockpit_open_and_session_intact() async {
        final class FailingInsertService: TextInserting {
            func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
                InsertResult(method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
            }
        }
        let state = AppState()
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxflow-cockpit-test-\(UUID().uuidString)")
        let sessionService = LongFormSessionService(autoSaveDirectory: sessionDir)
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-insert-audit-\(UUID().uuidString).jsonl")
        let insertion = TextInsertionCoordinator(
            state: state, insertService: FailingInsertService(),
            audit: InsertionAuditLog(fileURL: auditURL))
        let coord = CockpitCoordinator(
            state: state,
            sessionService: sessionService,
            actionService: SmartActionService(backend: StubSmartActionBackend()),
            textInsertionCoordinator: insertion,
            snippetStore: nil
        )
        coord.open()
        sessionService.start()
        sessionService.appendChunk("the transcript that must survive")
        sessionService.stop()

        await coord.insertIntoTarget()

        XCTAssertTrue(state.cockpitVisible, "failure must not close the cockpit")
        XCTAssertEqual(sessionService.currentSession?.transcript,
                       "the transcript that must survive")
        XCTAssertTrue(state.statusLine.contains("Insert failed"),
                      "got: \(state.statusLine)")
    }

    private func makeCoordinator() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: StubSmartActionBackend())
    }

    private func makeCoordinatorWithGuardrailBackend() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: GuardrailSmartActionBackend())
    }

    private func makeCoordinatorWithEchoBackend() -> (AppState, CockpitCoordinator, LongFormSessionService, SmartActionService) {
        makeCoordinator(backend: EchoSmartActionBackend())
    }

    func test_smartActionErrorMessage_names_memory_pressure() {
        let msg = CockpitCoordinator.smartActionErrorMessage(
            .memo, error: "provider_unavailable", degradedReason: "memory_pressure")
        XCTAssertTrue(msg.lowercased().contains("memory pressure"), msg)
        XCTAssertFalse(msg.lowercased().contains("configure"), "the provider is fine — do not send the user to Settings")
    }

    func test_smartActionErrorMessage_names_wedged_runner() {
        let msg = CockpitCoordinator.smartActionErrorMessage(
            .memo, error: "provider_unavailable", degradedReason: "provider_wedged")
        XCTAssertTrue(msg.contains("ollama stop"), msg)
    }

    /// The backend refuses with degraded_reason when the memory guard (not a
    /// missing provider) kept the action from running; the status line must
    /// say that instead of sending the user to Settings.
    func test_applyAction_surfaces_memory_pressure_reason() async throws {
        let (state, coord, _, _) = makeCoordinator(backend: MemoryPressureSmartActionBackend())

        let result = try await coord.applyAction(.memo, to: "raw transcript")

        XCTAssertEqual(result.degradedReason, "memory_pressure")
        XCTAssertTrue(state.statusLine.lowercased().contains("memory pressure"), state.statusLine)
        XCTAssertEqual(state.chipInvocationCounts[.memo, default: 0], 0)
    }

    /// Single-flight: chips had no in-flight state, so a second tap during a
    /// 6 s transform dispatched a duplicate. The second call is refused with a
    /// soft error and the state clears when the first completes.
    func test_applyAction_refuses_second_dispatch_while_in_flight() async throws {
        let backend = GatedSmartActionBackend()
        let (state, coord, _, _) = makeCoordinator(backend: backend)

        let first = Task { try await coord.applyAction(.memo, to: "raw transcript") }
        await backend.waitUntilCalled()
        XCTAssertEqual(state.smartActionInFlight, .memo)
        XCTAssertNotNil(state.smartActionStartedAt)

        let second = try await coord.applyAction(.mece, to: "raw transcript")
        XCTAssertEqual(second.error, "action_in_flight")
        XCTAssertEqual(state.chipInvocationCounts[.mece, default: 0], 0)

        backend.release()
        let result = try await first.value
        XCTAssertNil(result.error)
        XCTAssertNil(state.smartActionInFlight)
        XCTAssertNil(state.smartActionStartedAt)
        XCTAssertEqual(state.chipInvocationCounts[.memo, default: 0], 1)
    }

    func test_applyAction_clears_in_flight_state_on_throw() async {
        let (state, coord, _, _) = makeCoordinator(backend: ThrowingSmartActionBackend())
        do {
            _ = try await coord.applyAction(.memo, to: "raw transcript")
            XCTFail("expected throw")
        } catch {}
        XCTAssertNil(state.smartActionInFlight)
    }

    func test_smartActionErrorMessage_in_flight() {
        let msg = CockpitCoordinator.smartActionErrorMessage(.mece, error: "action_in_flight")
        XCTAssertTrue(msg.lowercased().contains("still running"), msg)
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

private final class ErroringSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        // The fail-closed shape: error set, output == transcript (no real transform).
        SmartActionResult(actionId: action, output: transcript, guardrailTriggered: false, error: "provider_unavailable")
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

private final class MemoryPressureSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action, output: transcript, guardrailTriggered: false,
            error: "provider_unavailable", degradedReason: "memory_pressure")
    }
}

/// Blocks inside performSmartAction until released, so tests can observe the
/// in-flight window deterministically.
private final class GatedSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var released = false
    private var calledWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilCalled() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if called { cont.resume() } else { calledWaiter = cont }
            }
        }
    }

    func release() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let waiter = releaseWaiter
            releaseWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    /// Synchronous so the lock never spans a suspension point (NSLock is
    /// unavailable from async contexts under Swift 6).
    private func markCalled() -> CheckedContinuation<Void, Never>? {
        lock.withLock {
            called = true
            let waiter = calledWaiter
            calledWaiter = nil
            return waiter
        }
    }

    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        markCalled()?.resume()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if released { cont.resume() } else { releaseWaiter = cont }
            }
        }
        return SmartActionResult(actionId: action, output: "# transformed\n\n\(transcript)", guardrailTriggered: false, error: nil)
    }
}

private final class ThrowingSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    struct Boom: Error {}
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        throw Boom()
    }
}
