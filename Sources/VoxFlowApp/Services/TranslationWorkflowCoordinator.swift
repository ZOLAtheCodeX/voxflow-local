import Foundation

typealias TranslationWorkflowAction = @MainActor (_ request: TranslationWorkflowRequest) async throws ->
    TranslateResponse

struct TranslationWorkflowRequest {
    let sessionID: String
    let rawText: String
    let sourceLanguage: String
    let targetLanguage: String
    let providerMode: ProviderMode
    let consentToken: String?
    let allowRaw: Bool
}

@MainActor
protocol TranslationWorkflowCoordinating {
    func processTranslation(
        _ request: TranslationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws
}

@MainActor
final class TranslationWorkflowCoordinator: TranslationWorkflowCoordinating {
    private let state: AppState
    private let translate: TranslationWorkflowAction

    init(
        state: AppState,
        translate: @escaping TranslationWorkflowAction = TranslationWorkflowCoordinator.defaultTranslate
    ) {
        self.state = state
        self.translate = translate
    }

    func processTranslation(
        _ request: TranslationWorkflowRequest,
        recordStage: WorkflowStageRecorder
    ) async throws {
        let translationStarted = ContinuousClock.now
        let translation = try await translate(request)
        recordStage("translate", translationStarted, "provider=\(request.providerMode.rawValue)")

        state.translationCandidate = TranslationCandidate(
            sourceEnglish: translation.sourceText,
            targetGerman: translation.translatedText,
            approved: false
        )
        state.sessionState = .review
        state.statusLine = statusLine(for: request)
    }

    private func statusLine(for request: TranslationWorkflowRequest) -> String {
        guard request.providerMode == .privateAPI else {
            return "Approve translation before insert"
        }

        return request.allowRaw
            ? "Review translation before insert"
            : "Review redacted translation before insert"
    }

    private static func defaultTranslate(_ request: TranslationWorkflowRequest) async throws ->
        TranslateResponse {
        try await BackendAPIClient.translate(
            sessionID: request.sessionID,
            sourceText: request.rawText,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            providerMode: request.providerMode,
            consentToken: request.consentToken,
            allowRaw: request.allowRaw
        )
    }
}
