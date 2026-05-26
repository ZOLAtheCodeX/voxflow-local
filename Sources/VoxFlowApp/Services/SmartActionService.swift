import Foundation
import os

/// Pluggable backend for smart-action transformations.
///
/// The production implementation is ``BackendAPISmartActionAdapter`` which
/// forwards to the static ``BackendAPIClient.performSmartAction``. Test
/// suites supply lightweight stubs that don't hit the network.
protocol SmartActionBackend: Sendable {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult
}

/// Adapter wrapping ``BackendAPIClient`` static methods as a conformance.
struct BackendAPISmartActionAdapter: SmartActionBackend {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        try await BackendAPIClient.performSmartAction(action, transcript: transcript)
    }
}

/// Cockpit Layer 0 client-side wrapper around ``POST /v1/smart_action``.
///
/// Maintains an in-memory undo stack of the last 20 applied actions so the
/// cockpit can roll back a transformation without re-issuing a network call.
/// Backend failure (empty output, guardrail trip) is reported through the
/// returned ``SmartActionResult`` rather than thrown — callers always get a
/// usable result; the engine's regex fallback guarantees that.
actor SmartActionService {
    private let backend: SmartActionBackend
    private let log = Logger(subsystem: "local.voxflow.app", category: "SmartActionService")
    private var history: [(SmartActionId, beforeText: String, afterText: String)] = []
    private static let historyCap = 20

    init(backend: SmartActionBackend) {
        self.backend = backend
    }

    func apply(_ action: SmartActionId, to transcript: String) async throws -> SmartActionResult {
        log.info("applying \(action.rawValue) to \(transcript.count) chars")
        let result = try await backend.performSmartAction(action, transcript: transcript)
        // Only record successful (non-guardrail) transforms in the undo stack
        // — guardrail trips substitute the regex fallback, which the user
        // expects as the floor, not as something to undo.
        if !result.guardrailTriggered && result.output != transcript {
            history.append((action, beforeText: transcript, afterText: result.output))
            if history.count > Self.historyCap {
                history.removeFirst(history.count - Self.historyCap)
            }
        }
        return result
    }

    /// Pop the last applied action and return ``(actionId, beforeText)`` so
    /// the caller can restore the previous transcript. Returns ``nil`` when
    /// the history is empty.
    func popLast() -> (SmartActionId, String)? {
        guard let last = history.popLast() else { return nil }
        return (last.0, last.beforeText)
    }

    /// Number of actions currently in the undo stack — exposed for the UI's
    /// ``⌘Z`` enable/disable state.
    func historyCount() -> Int { history.count }
}
