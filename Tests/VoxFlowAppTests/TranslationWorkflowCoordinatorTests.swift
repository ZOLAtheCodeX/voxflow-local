import XCTest
@testable import VoxFlowApp

@MainActor
final class TranslationWorkflowCoordinatorTests: XCTestCase {

    func testLocalTranslationWorkflowBuildsReviewCandidate() async throws {
        let state = AppState()
        var receivedRequest: TranslationWorkflowRequest?
        let sut = TranslationWorkflowCoordinator(
            state: state,
            translate: { request in
                receivedRequest = request
                return TranslateResponse(
                    sourceText: request.rawText,
                    translatedText: "Guten Morgen Team"
                )
            }
        )

        var recordedStages: [String] = []
        let request = TranslationWorkflowRequest(
            sessionID: "translate-1",
            rawText: "Good morning team",
            sourceLanguage: "en",
            targetLanguage: "de",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false
        )

        try await sut.processTranslation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(receivedRequest?.sessionID, request.sessionID)
        XCTAssertEqual(receivedRequest?.sourceLanguage, "en")
        XCTAssertEqual(receivedRequest?.targetLanguage, "de")
        XCTAssertEqual(state.translationCandidate?.sourceEnglish, "Good morning team")
        XCTAssertEqual(state.translationCandidate?.targetGerman, "Guten Morgen Team")
        XCTAssertEqual(state.translationCandidate?.approved, false)
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertEqual(state.statusLine, "Approve translation before insert")
        XCTAssertEqual(recordedStages, ["translate"])
    }

    func testPrivateAPITranslationWorkflowMarksRedactedReview() async throws {
        let state = AppState()
        let sut = TranslationWorkflowCoordinator(
            state: state,
            translate: { request in
                XCTAssertEqual(request.providerMode, .privateAPI)
                XCTAssertEqual(request.consentToken, "consent-1")
                XCTAssertFalse(request.allowRaw)
                return TranslateResponse(
                    sourceText: "My SSN is 123-45-6789",
                    translatedText: "Meine SSN ist [REDACTED]"
                )
            }
        )

        let request = TranslationWorkflowRequest(
            sessionID: "translate-2",
            rawText: "My SSN is 123-45-6789",
            sourceLanguage: "en",
            targetLanguage: "de",
            providerMode: .privateAPI,
            consentToken: "consent-1",
            allowRaw: false
        )

        try await sut.processTranslation(request) { _, _, _ in }

        XCTAssertEqual(state.translationCandidate?.targetGerman, "Meine SSN ist [REDACTED]")
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertEqual(state.statusLine, "Review redacted translation before insert")
    }
}
