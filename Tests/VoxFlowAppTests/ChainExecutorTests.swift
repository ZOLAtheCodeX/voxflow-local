import AppKit
import XCTest
@testable import VoxFlowApp

@MainActor
final class ChainExecutorTests: XCTestCase {

    // MARK: - Happy path

    func test_run_capture_action_insert_happy_path() async {
        let backend = RecordingSmartActionBackend(output: "MEMO OUTPUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "raw transcript" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Memo Flow",
            steps: [.capture(mode: .quick), .action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(result.completedSteps, 3)
        XCTAssertNil(result.error)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertFalse(result.clipboardFallback)
        XCTAssertEqual(result.finalText, "MEMO OUTPUT")
        XCTAssertEqual(insert.calls.count, 1)
        XCTAssertEqual(insert.calls.first?.text, "MEMO OUTPUT")
    }

    func test_run_threads_text_capture_to_action() async {
        let backend = RecordingSmartActionBackend(output: "MEMO OUTPUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "raw transcript" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.capture(mode: .quick), .action(actionId: .memo)],
            createdAt: Date()
        )

        _ = await executor.run(chain)

        // The captured transcript must flow into the action as its input.
        let received = await backend.receivedTranscripts
        XCTAssertEqual(received, ["raw transcript"])
    }

    // MARK: - Capture stop

    func test_capture_empty_transcript_stops() async {
        let backend = RecordingSmartActionBackend(output: "SHOULD-NOT-RUN")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.capture(mode: .quick), .action(actionId: .memo)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(result.error, .noTranscript)
        XCTAssertEqual(result.failedStepIndex, 0)
        XCTAssertEqual(result.completedSteps, 0)
        let received = await backend.receivedTranscripts
        XCTAssertTrue(received.isEmpty, "Action must never run after an empty capture")
    }

    // MARK: - Action stop

    func test_action_error_result_stops() async {
        let backend = ConfigurableSmartActionBackend(
            result: SmartActionResult(actionId: .memo, output: "", guardrailTriggered: false, error: "boom")
        )
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(result.error, .actionFailed("boom"))
        XCTAssertEqual(result.failedStepIndex, 0)
        XCTAssertTrue(insert.calls.isEmpty, "Insert must never run after a failed action")
    }

    func test_action_throws_stops() async {
        let backend = ThrowingSmartActionBackend()
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(result.failedStepIndex, 0)
        XCTAssertTrue(insert.calls.isEmpty, "Insert must never run after a thrown action")
        // The error case must be .actionFailed with a non-empty message derived
        // from the thrown error's localizedDescription.
        guard case let .actionFailed(message)? = result.error else {
            return XCTFail("Expected .actionFailed, got \(String(describing: result.error))")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Guardrail pass-through

    func test_guardrail_triggered_passes_through() async {
        let backend = ConfigurableSmartActionBackend(
            result: SmartActionResult(actionId: .memo, output: "fallback text", guardrailTriggered: true, error: nil)
        )
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        // guardrailTriggered does NOT stop the chain — the fallback output passes through.
        XCTAssertEqual(result.completedSteps, 2)
        XCTAssertNil(result.error)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertEqual(insert.calls.count, 1)
        XCTAssertEqual(insert.calls.first?.text, "fallback text")
    }

    // MARK: - Insert failure

    func test_insert_failure_sets_clipboardFallback_and_stops() async {
        let backend = RecordingSmartActionBackend(output: "OUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: false)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(result.error, .insertFailed)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertTrue(result.clipboardFallback)
        XCTAssertEqual(result.completedSteps, 1)
    }

    // MARK: - frozenTarget wiring

    func test_insert_uses_frozenTarget() async {
        // NSRunningApplication can't be cheaply faked, so we verify the executor
        // invokes the frozenTarget closure exactly once during an insert step.
        // (The closure flips a captured flag / increments a counter.)
        let backend = RecordingSmartActionBackend(output: "OUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let counter = CallCounter()
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: {
                counter.count += 1
                return nil
            }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        _ = await executor.run(chain)

        XCTAssertEqual(counter.count, 1, "frozenTarget must be invoked exactly once for the single insert step")
    }

    // MARK: - Insert-only ordering

    func test_insert_only_chain_with_empty_text_fails_without_clipboard() async {
        // workingText starts "" — an insert-only chain does not implicitly
        // capture first. Production's insertText returns false on empty text
        // BEFORE its clipboard-fallback branch, so the chain STOPS with
        // .insertFailed and NOTHING is copied to the clipboard (clipboardFallback
        // is false — an empty insert is not a recoverable clipboard situation).
        let backend = RecordingSmartActionBackend(output: "OUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "ignored transcript" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertEqual(insert.calls.count, 1)
        XCTAssertEqual(insert.calls.first?.text, "")
        XCTAssertEqual(result.error, .insertFailed)
        XCTAssertEqual(result.failedStepIndex, 0)
        XCTAssertFalse(result.clipboardFallback, "Nothing is copied for an empty insert")
        XCTAssertEqual(result.completedSteps, 0)
    }

    func test_action_then_insert_with_nonempty_output_succeeds() async {
        // The positive companion: an action yields non-empty output, so the
        // following insert lands and the chain completes. Proves the non-empty
        // insert path still works after the empty-guard was added to the fake.
        let backend = RecordingSmartActionBackend(output: "ACTION OUT")
        let service = SmartActionService(backend: backend)
        let insert = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: service,
            textInsertion: insert,
            currentTranscript: { "seed" },
            frozenTarget: { nil }
        )
        let chain = WorkflowChain(
            name: "Flow",
            steps: [.action(actionId: .memo), .insert(targetHint: nil)],
            createdAt: Date()
        )

        let result = await executor.run(chain)

        XCTAssertNil(result.error)
        XCTAssertNil(result.failedStepIndex)
        XCTAssertFalse(result.clipboardFallback)
        XCTAssertEqual(result.completedSteps, 2)
        XCTAssertEqual(result.finalText, "ACTION OUT")
        XCTAssertEqual(insert.calls.count, 1)
        XCTAssertEqual(insert.calls.first?.text, "ACTION OUT")
    }
}

// MARK: - Test doubles

/// Records every insertText call (text + targetApp) and returns a configurable
/// Bool to drive the success/failure branch. The other protocol members are
/// no-ops since ChainExecutor only exercises insertText(_:statusSuffix:targetApp:).
@MainActor
private final class FakeTextInsertion: TextInsertionCoordinating {
    struct Call {
        let text: String
        let targetApp: NSRunningApplication?
    }

    private let result: Bool
    private(set) var calls: [Call] = []

    init(returns result: Bool) {
        self.result = result
    }

    func insertCurrentText() async {}
    func insertCurrentText(targetApp: NSRunningApplication?) async {}

    func insertText(_ text: String, statusSuffix: String) async -> Bool {
        await insertText(text, statusSuffix: statusSuffix, targetApp: nil)
    }

    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) async -> Bool {
        // Record the call so tests can assert what the executor attempted, but
        // mirror production: the real TextInsertionCoordinator.insertText starts
        // with `guard !text.isEmpty else { return false }` — an empty insert
        // returns false (and copies nothing) regardless of the configured Bool.
        calls.append(Call(text: text, targetApp: targetApp))
        guard !text.isEmpty else { return false }
        return result
    }

    func copyCurrentText() {}
    func copyMeetingMarkdownTemplate() {}
    func copyMeetingNotionTemplate() {}
}

/// A non-throwing backend that returns a fixed `output` and records every
/// transcript it was handed (so tests can assert capture→action data flow).
private actor RecordingSmartActionBackend: SmartActionBackend {
    private let output: String
    private(set) var receivedTranscripts: [String] = []

    init(output: String) {
        self.output = output
    }

    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        receivedTranscripts.append(transcript)
        return SmartActionResult(actionId: action, output: output, guardrailTriggered: false, error: nil)
    }
}

/// Returns a caller-supplied SmartActionResult verbatim (its actionId field is
/// overridden to the requested action so the result is well-formed).
private final class ConfigurableSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    private let result: SmartActionResult

    init(result: SmartActionResult) {
        self.result = result
    }

    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(
            actionId: action,
            output: result.output,
            guardrailTriggered: result.guardrailTriggered,
            error: result.error
        )
    }
}

/// Always throws, so tests can pin the .actionFailed(localizedDescription) path.
private final class ThrowingSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    struct Boom: Error {}
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        throw Boom()
    }
}

/// Reference-type counter so an `@escaping @MainActor` closure can mutate a
/// captured value without escaping-capture warnings.
@MainActor
private final class CallCounter {
    var count = 0

    /// R5.6: app-level steps dispatch through the injected handler and do
    /// not disturb workingText.
    @MainActor
    func testAppStepsDispatchAndPreserveWorkingText() async {
        let actionService = SmartActionService(backend: ConfigurableSmartActionBackend(
            result: SmartActionResult(actionId: .memo, output: "transformed", guardrailTriggered: false, error: nil)))
        let insertion = FakeTextInsertion(returns: true)
        var performed: [ChainStep] = []
        let executor = ChainExecutor(
            actionService: actionService,
            textInsertion: insertion,
            currentTranscript: { "captured transcript" },
            frozenTarget: { nil },
            performAppStep: { step in performed.append(step); return true }
        )
        let chain = WorkflowChain(name: "Focus", steps: [
            .capture(mode: .longForm),
            .setMode(mode: "meeting"),
            .openWindow(window: "cockpit"),
            .insert(targetHint: nil),
        ], createdAt: Date())
        let result = await executor.run(chain)
        XCTAssertNil(result.error)
        XCTAssertEqual(performed.count, 2)
        XCTAssertEqual(insertion.calls.last?.text, "captured transcript")
    }

    @MainActor
    func testFailedAppStepStopsChain() async {
        let actionService = SmartActionService(backend: ConfigurableSmartActionBackend(
            result: SmartActionResult(actionId: .memo, output: "x", guardrailTriggered: false, error: nil)))
        let insertion = FakeTextInsertion(returns: true)
        let executor = ChainExecutor(
            actionService: actionService,
            textInsertion: insertion,
            currentTranscript: { "text" },
            frozenTarget: { nil },
            performAppStep: { _ in false }
        )
        let chain = WorkflowChain(name: "F", steps: [
            .capture(mode: .longForm),
            .setMode(mode: "nonsense"),
            .insert(targetHint: nil),
        ], createdAt: Date())
        let result = await executor.run(chain)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.failedStepIndex, 1)
        XCTAssertTrue(insertion.calls.isEmpty, "stop-on-error: insert must not run")
    }
}

