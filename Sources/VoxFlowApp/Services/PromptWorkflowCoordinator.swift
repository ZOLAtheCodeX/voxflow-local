import AppKit
import Foundation

struct PromptWorkflowRequest {
    let sessionID: String
    let rawText: String
    let providerMode: ProviderMode
    let consentToken: String?
    let allowRaw: Bool
    let toneStyle: ToneStyle
    let insertBehavior: InsertBehavior
    let sttBackend: STTBackend
    let targetApp: NSRunningApplication?
}

@MainActor
protocol PromptWorkflowCoordinating {
    func processPrompt(
        _ request: PromptWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws
}

@MainActor
final class PromptWorkflowCoordinator: PromptWorkflowCoordinating {
    private let state: AppState
    private let textInsertion: TextInsertionCoordinating

    init(state: AppState, textInsertion: TextInsertionCoordinating) {
        self.state = state
        self.textInsertion = textInsertion
    }

    func processPrompt(
        _ request: PromptWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws {
        let cleanedText: String
        if request.providerMode == .localOnly && request.sttBackend == .whisperKit {
            let cleanupStarted = ContinuousClock.now
            cleanedText = TextCleanupService.cleanup(
                request.rawText,
                mode: .polish,
                tone: request.toneStyle
            )
            recordStage(
                "cleanup_polish_local",
                cleanupStarted,
                "tone=\(request.toneStyle.rawValue)"
            )
        } else {
            let cleanupStarted = ContinuousClock.now
            let cleanupResponse = try await BackendAPIClient.cleanup(
                sessionID: request.sessionID,
                mode: .polish,
                inputText: request.rawText,
                toneStyle: request.toneStyle,
                providerMode: request.providerMode,
                consentToken: request.consentToken,
                allowRaw: request.allowRaw
            )
            cleanedText = cleanupResponse.outputText
            recordStage(
                "cleanup_polish_api",
                cleanupStarted,
                "tone=\(request.toneStyle.rawValue), provider=\(request.providerMode.rawValue)"
            )
        }

        let framingStarted = ContinuousClock.now
        let intent = PromptFramingService.detectIntent(cleanedText)
        let framedPrompt = PromptFramingService.frame(cleanedText, intent: intent)
        recordStage("prompt_frame", framingStarted, "intent=\(intent.rawValue)")

        let candidate = PromptCandidate(
            sessionID: request.sessionID,
            rawText: request.rawText,
            cleanedText: cleanedText,
            framedPrompt: framedPrompt,
            detectedIntent: intent
        )
        state.promptCandidate = candidate

        if request.insertBehavior.cleanupMode != nil && request.providerMode == .localOnly {
            let appLabel = state.focusTarget.appName ?? "app"
            let insertStarted = ContinuousClock.now
            if await textInsertion.insertText(
                framedPrompt,
                statusSuffix: "Prompt inserted (\(intent.displayName) — \(appLabel))",
                targetApp: request.targetApp
            ) {
                recordStage("insert", insertStarted, "mode=prompt")
                state.sessionState = .idle
            } else {
                recordStage("insert", insertStarted, "mode=prompt, result=fallback")
                state.sessionState = .review
            }
        } else {
            state.sessionState = .review
            state.statusLine = "Review prompt and insert"
        }
    }
}
