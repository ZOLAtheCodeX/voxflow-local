import Foundation

typealias PrivacyWorkflowContinuation = @MainActor (String, Bool) async throws -> Void

@MainActor protocol PrivacyConsentCoordinating {
    func requestPrivacyPreview(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String,
        continuation: @escaping PrivacyWorkflowContinuation
    ) async throws
    func approvePrivacyPreview(sendRaw: Bool)
    func cancelPrivacyPreview()
    func clearPendingOperation()
}

@MainActor
final class PrivacyConsentCoordinator: PrivacyConsentCoordinating {
    private let state: AppState
    private var pendingContinuation: PrivacyWorkflowContinuation?
    private var activeApprovalTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func requestPrivacyPreview(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String,
        continuation: @escaping PrivacyWorkflowContinuation
    ) async throws {
        let previewResponse = try await BackendAPIClient.privacyPreview(
            sessionID: sessionID,
            operation: operation,
            inputText: inputText
        )

        guard let op = PrivacyOperationKind(rawValue: previewResponse.operation) else {
            throw NSError(domain: "VoxFlow", code: 4001, userInfo: [NSLocalizedDescriptionKey: "Invalid privacy preview operation"])
        }

        state.privacyPreview = PrivacyPreview(
            operation: op,
            token: previewResponse.token,
            originalText: previewResponse.originalText,
            redactedText: previewResponse.redactedText
        )
        pendingContinuation = continuation
        state.sessionState = .review
        state.statusLine = "Review privacy preview and approve request"
        state.recordingDuration = 0
    }

    func approvePrivacyPreview(sendRaw: Bool) {
        guard let preview = state.privacyPreview,
              let continuation = pendingContinuation else {
            return
        }

        state.statusLine = sendRaw ? "Sending approved raw text to private API..." : "Sending redacted text to private API..."

        activeApprovalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await continuation(preview.token, sendRaw)
                guard !Task.isCancelled else { return }
                if sendRaw {
                    state.privacyApproveRawCount += 1
                } else {
                    state.privacyApproveRedactedCount += 1
                }
                state.privacyPreview = nil
                pendingContinuation = nil
            } catch is CancellationError {
                // New capture started — stale approval silently discarded
            } catch {
                guard !Task.isCancelled else { return }
                state.errorMessage = "Private API processing failed: \(error.localizedDescription)"
                state.sessionState = .error
                state.privacyPreview = nil
                pendingContinuation = nil
            }
        }
    }

    func cancelPrivacyPreview() {
        activeApprovalTask?.cancel()
        activeApprovalTask = nil
        state.privacyPreview = nil
        pendingContinuation = nil
        state.statusLine = "Private API request cancelled"
        state.sessionState = .review
    }

    func clearPendingOperation() {
        activeApprovalTask?.cancel()
        activeApprovalTask = nil
        pendingContinuation = nil
    }

    /// Test-only: inject a continuation without calling the backend.
    func testSetContinuation(_ continuation: @escaping PrivacyWorkflowContinuation) {
        pendingContinuation = continuation
    }
}
