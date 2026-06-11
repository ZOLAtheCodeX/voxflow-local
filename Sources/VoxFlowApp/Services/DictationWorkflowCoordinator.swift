import AppKit
import Foundation

struct DictationWorkflowRequest {
    let sessionID: String
    let rawText: String
    let providerMode: ProviderMode
    let consentToken: String?
    let allowRaw: Bool
    let toneStyle: ToneStyle
    let insertBehavior: InsertBehavior
    let sttBackend: STTBackend
    let lastTranscriptionConfidence: Double
    let targetApp: NSRunningApplication?
}

@MainActor
protocol DictationWorkflowCoordinating {
    func processDictation(
        _ request: DictationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws
}

@MainActor
final class DictationWorkflowCoordinator: DictationWorkflowCoordinating {
    private let state: AppState
    private let textInsertion: TextInsertionCoordinating
    private let pushToSessionMemory: @MainActor (TranscriptCandidate) -> Void

    init(
        state: AppState,
        textInsertion: TextInsertionCoordinating,
        pushToSessionMemory: @escaping @MainActor (TranscriptCandidate) -> Void
    ) {
        self.state = state
        self.textInsertion = textInsertion
        self.pushToSessionMemory = pushToSessionMemory
    }

    func processDictation(
        _ request: DictationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws {
        // Auto-insert raw skips cleanup entirely
        if request.insertBehavior == .autoInsertRaw && request.providerMode == .localOnly {
            let candidate = TranscriptCandidate(
                rawText: request.rawText,
                lightText: request.rawText,
                polishText: request.rawText,
                selectedMode: .raw,
                confidence: request.lastTranscriptionConfidence,
                timestamp: Date(),
                targetProcessIdentifier: request.targetApp?.processIdentifier
            )
            state.transcriptCandidate = candidate
            pushToSessionMemory(candidate)
            let appLabel = state.focusTarget.appName ?? "app"
            let insertStarted = ContinuousClock.now
            if await textInsertion.insertText(request.rawText, statusSuffix: "Inserted (raw — \(appLabel))", targetApp: request.targetApp) {
                recordStage("insert", insertStarted, "mode=raw")
                state.sessionState = .idle
            } else {
                recordStage("insert", insertStarted, "mode=raw, result=fallback")
                state.sessionState = .review
            }
            return
        }

        // Local cleanup for WhisperKit — no backend needed
        if request.providerMode == .localOnly && request.sttBackend == .whisperKit {
            let lightStarted = ContinuousClock.now
            let lightText = TextCleanupService.cleanup(request.rawText, mode: .light, tone: request.toneStyle)
            recordStage("cleanup_light_local", lightStarted, "tone=\(request.toneStyle.rawValue)")
            let polishStarted = ContinuousClock.now
            let polishText = TextCleanupService.cleanup(request.rawText, mode: .polish, tone: request.toneStyle)
            recordStage("cleanup_polish_local", polishStarted, "tone=\(request.toneStyle.rawValue)")

            let candidate = TranscriptCandidate(
                rawText: request.rawText,
                lightText: lightText,
                polishText: polishText,
                selectedMode: .raw,
                confidence: request.lastTranscriptionConfidence,
                timestamp: Date(),
                targetProcessIdentifier: request.targetApp?.processIdentifier
            )
            state.transcriptCandidate = candidate
            state.selectedMode = .raw
            pushToSessionMemory(candidate)

            await autoInsertOrReview(candidate: candidate, request: request, recordStage: recordStage)
            return
        }

        let lightStarted = ContinuousClock.now
        let lightText = try await BackendAPIClient.cleanup(
            sessionID: request.sessionID,
            mode: .light,
            inputText: request.rawText,
            toneStyle: request.toneStyle,
            providerMode: request.providerMode,
            consentToken: request.consentToken,
            allowRaw: request.allowRaw
        ).outputText
        recordStage("cleanup_light_api", lightStarted, "tone=\(request.toneStyle.rawValue), provider=\(request.providerMode.rawValue)")
        let polishStarted = ContinuousClock.now
        let polishText = try await BackendAPIClient.cleanup(
            sessionID: request.sessionID,
            mode: .polish,
            inputText: request.rawText,
            toneStyle: request.toneStyle,
            providerMode: request.providerMode,
            consentToken: request.consentToken,
            allowRaw: request.allowRaw
        ).outputText
        recordStage("cleanup_polish_api", polishStarted, "tone=\(request.toneStyle.rawValue), provider=\(request.providerMode.rawValue)")
        
        // Private-API: default to .light so the redacted/cleaned version
        // is shown first — .raw would expose the unredacted original.
        let defaultMode: CleanupMode = request.providerMode == .privateAPI ? .light : .raw
        let candidate = TranscriptCandidate(
            rawText: request.rawText,
            lightText: lightText,
            polishText: polishText,
            selectedMode: defaultMode,
            confidence: request.lastTranscriptionConfidence,
            timestamp: Date(),
            targetProcessIdentifier: request.targetApp?.processIdentifier
        )
        state.transcriptCandidate = candidate
        state.selectedMode = defaultMode
        if request.providerMode == .localOnly { pushToSessionMemory(candidate) }

        await autoInsertOrReview(candidate: candidate, request: request, recordStage: recordStage)
    }

    private func autoInsertOrReview(
        candidate: TranscriptCandidate,
        request: DictationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async {
        // Auto-insert light/polish
        if let autoMode = request.insertBehavior.cleanupMode, request.providerMode == .localOnly {
            let text = candidate.text(for: autoMode)
            let toneLabel = request.toneStyle != state.toneStyle ? ", \(request.toneStyle.displayName)" : ""
            let appLabel = state.focusTarget.appName ?? "app"
            let insertStarted = ContinuousClock.now
            if await textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel) — \(appLabel))", targetApp: request.targetApp) {
                recordStage("insert", insertStarted, "mode=\(autoMode.rawValue)")
                state.sessionState = .idle
            } else {
                recordStage("insert", insertStarted, "mode=\(autoMode.rawValue), result=fallback")
                state.sessionState = .review
                state.statusLine = "Auto-insert failed — review and retry"
            }
            return
        }

        state.sessionState = .review
        state.statusLine = request.providerMode == .privateAPI
            ? (request.allowRaw ? "Private API cleanup complete" : "Private API cleanup complete (redacted)")
            : "Review and insert"
    }
}
