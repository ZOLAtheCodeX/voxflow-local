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
            // Final cancellation gate: if the user cancelled (or a newer capture
            // superseded this one) after transcription but before insertion, do
            // NOT insert — propagate as cancellation, not a silent insert.
            try Task.checkCancellation()
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

        // WhisperKit handles STT in-app, but local model polish still lives in
        // the backend provider chain. Use it when warm, then fall back to the
        // Swift cleanup pipeline so dictation never hard-depends on Ollama.
        if request.providerMode == .localOnly && request.sttBackend == .whisperKit {
            if state.backendReadiness.readyForDictation {
                do {
                    try await processBackendCleanup(request, recordStage: recordStage)
                    return
                } catch {
                    // A cancelled capture (the user dismissed it, or a newer
                    // capture superseded this one) surfaces here as
                    // CancellationError or URLError.cancelled. Do NOT fall
                    // through to local cleanup — that would insert text the user
                    // cancelled (the ghost-insertion class). Propagate the
                    // cancellation so the pipeline aborts cleanly.
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    // A genuine backend failure (Ollama down / timeout / 5xx):
                    // fall back to the in-app cleanup pipeline so dictation still
                    // completes.
                    let fallbackStarted = ContinuousClock.now
                    recordStage("cleanup_api_fallback", fallbackStarted, error.localizedDescription)
                    state.statusLine = "Local model cleanup unavailable — using in-app cleanup"
                }
            }

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
                targetProcessIdentifier: request.targetApp?.processIdentifier,
                // Both modes came from the in-app TextCleanupService (backend cold).
                lightProvenance: PolishProvenance.inApp,
                polishProvenance: PolishProvenance.inApp
            )
            state.transcriptCandidate = candidate
            state.selectedMode = .raw
            pushToSessionMemory(candidate)

            try await autoInsertOrReview(candidate: candidate, request: request, recordStage: recordStage)
            return
        }

        try await processBackendCleanup(request, recordStage: recordStage)
    }

    private func processBackendCleanup(
        _ request: DictationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws {
        // Auto-insert only ever inserts ONE mode, so only that mode needs the
        // (slow) backend LLM round-trip. Resolve just that one through the
        // backend and fill the other candidate field with the cheap local
        // pipeline — halving the latency the user waits on before text lands.
        // Review and private-API still resolve both modes via the backend:
        // the user toggles between them, so both must be real LLM output.
        let autoMode = request.providerMode == .localOnly ? request.insertBehavior.cleanupMode : nil

        let lightText: String
        let polishText: String
        // Per-mode provenance, stored on the candidate so BOTH auto-insert AND a
        // later review-mode insert (user toggles light/polish, clicks Insert) can
        // prove whether Gemma ran, the regex floor did, or the in-app pipeline.
        var lightProvenance: String?
        var polishProvenance: String?

        if let autoMode {
            // Only the auto-inserted mode round-trips the backend; the other mode
            // is filled by the cheap in-app pipeline (so it is "in-app cleanup").
            let response = try await backendCleanup(request, mode: autoMode, recordStage: recordStage)
            let served = response.outputText
            let servedProvenance = PolishProvenance.label(servedBy: response.servedBy, modelId: response.modelId)
            switch autoMode {
            case .polish:
                polishText = served
                polishProvenance = servedProvenance
                lightText = TextCleanupService.cleanup(request.rawText, mode: .light, tone: request.toneStyle)
                lightProvenance = PolishProvenance.inApp
            case .light:
                lightText = served
                lightProvenance = servedProvenance
                polishText = TextCleanupService.cleanup(request.rawText, mode: .polish, tone: request.toneStyle)
                polishProvenance = PolishProvenance.inApp
            case .raw:
                // Unreachable: .autoInsertRaw + localOnly is intercepted in
                // processDictation (early raw insert), and privateAPI yields
                // autoMode == nil. Fail loudly in debug rather than silently
                // POSTing raw mode to the backend if that guard ever regresses.
                assertionFailure("raw cleanup mode must not reach the backend path")
                lightText = served
                polishText = served
                lightProvenance = servedProvenance
                polishProvenance = servedProvenance
            }
        } else {
            // Review / private-API: both modes are real backend output, so each
            // carries its own provenance for whichever the user ends up inserting.
            let lightResponse = try await backendCleanup(request, mode: .light, recordStage: recordStage)
            let polishResponse = try await backendCleanup(request, mode: .polish, recordStage: recordStage)
            lightText = lightResponse.outputText
            polishText = polishResponse.outputText
            lightProvenance = PolishProvenance.label(servedBy: lightResponse.servedBy, modelId: lightResponse.modelId)
            polishProvenance = PolishProvenance.label(servedBy: polishResponse.servedBy, modelId: polishResponse.modelId)
        }

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
            targetProcessIdentifier: request.targetApp?.processIdentifier,
            lightProvenance: lightProvenance,
            polishProvenance: polishProvenance
        )
        state.transcriptCandidate = candidate
        state.selectedMode = defaultMode
        if request.providerMode == .localOnly { pushToSessionMemory(candidate) }

        try await autoInsertOrReview(candidate: candidate, request: request, recordStage: recordStage)
    }

    /// One backend cleanup round-trip, timed and recorded under the existing
    /// `cleanup_<mode>_api` stage name so traces stay comparable. Returns the
    /// full response so callers can read provenance (served_by/model_id), not
    /// just the cleaned text.
    private func backendCleanup(
        _ request: DictationWorkflowRequest,
        mode: CleanupMode,
        recordStage: WorkflowStageRecorder
    ) async throws -> CleanupResponse {
        let started = ContinuousClock.now
        let response = try await BackendAPIClient.cleanup(
            sessionID: request.sessionID,
            mode: mode,
            inputText: request.rawText,
            toneStyle: request.toneStyle,
            providerMode: request.providerMode,
            consentToken: request.consentToken,
            allowRaw: request.allowRaw
        )
        recordStage("cleanup_\(mode.rawValue)_api", started, "tone=\(request.toneStyle.rawValue), provider=\(request.providerMode.rawValue)")
        return response
    }

    private func autoInsertOrReview(
        candidate: TranscriptCandidate,
        request: DictationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws {
        // Auto-insert light/polish
        if let autoMode = request.insertBehavior.cleanupMode, request.providerMode == .localOnly {
            // Final cancellation gate before inserting: a cancel (or superseding
            // capture) after cleanup but before insert must NOT insert text.
            try Task.checkCancellation()
            let text = candidate.text(for: autoMode)
            let toneLabel = request.toneStyle != state.toneStyle ? ", \(request.toneStyle.displayName)" : ""
            let appLabel = state.focusTarget.appName ?? "app"
            // " · <provenance>" so the audit `source` proves Gemma vs regex vs
            // in-app cleanup; read from the candidate (single source of truth,
            // shared with the review-insert path) and omitted when unknown.
            let provenance = candidate.provenance(for: autoMode)
            let provenanceTag = (provenance.map { $0.isEmpty ? "" : " · \($0)" }) ?? ""
            let insertStarted = ContinuousClock.now
            if await textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel)\(provenanceTag) — \(appLabel))", targetApp: request.targetApp) {
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
