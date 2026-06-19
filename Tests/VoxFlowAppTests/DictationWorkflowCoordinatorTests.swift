import AppKit
import XCTest
@testable import VoxFlowApp

class DictationMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = DictationMockURLProtocol.requestHandler else {
            // A stray/leaked request (an async backend call outliving its test,
            // routed through the shared global BackendAPIClient.session after
            // tearDown nil'd the handler) must NOT fatalError — that crashes the
            // whole xctest process intermittently on CI (signal 5). Fail just
            // this request; a test that genuinely forgot its handler still fails
            // via its own awaited call throwing.
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class DictationWorkflowCoordinatorTests: XCTestCase {
    private var originalSession: URLSession!
    private var originalBaseURL: URL!

    private final class FakeTextInsertionCoordinator: TextInsertionCoordinating {
        var shouldSucceed = true
        var insertedText: String?
        var statusSuffix: String?
        var insertCallCount = 0

        func insertCurrentText() {}
        func insertCurrentText(targetApp: NSRunningApplication?) {}

        func insertText(_ text: String, statusSuffix: String) -> Bool {
            insertText(text, statusSuffix: statusSuffix, targetApp: nil)
        }

        func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) -> Bool {
            insertCallCount += 1
            insertedText = text
            self.statusSuffix = statusSuffix
            return shouldSucceed
        }

        func copyCurrentText() {}
        func copyMeetingMarkdownTemplate() {}
        func copyMeetingNotionTemplate() {}
    }

    override func setUp() {
        super.setUp()
        originalSession = BackendAPIClient.session
        originalBaseURL = BackendAPIClient.baseURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DictationMockURLProtocol.self]
        BackendAPIClient.session = URLSession(configuration: configuration)
        BackendAPIClient.baseURL = URL(string: "http://mock.test")!
    }

    override func tearDown() {
        DictationMockURLProtocol.requestHandler = nil
        BackendAPIClient.session = originalSession
        BackendAPIClient.baseURL = originalBaseURL
        super.tearDown()
    }

    @MainActor private func makeSUT() -> (DictationWorkflowCoordinator, AppState, FakeTextInsertionCoordinator, [TranscriptCandidate]) {
        let state = AppState()
        let textInsertion = FakeTextInsertionCoordinator()
        var sessionMemory: [TranscriptCandidate] = []
        let sut = DictationWorkflowCoordinator(
            state: state,
            textInsertion: textInsertion,
            pushToSessionMemory: { candidate in
                sessionMemory.append(candidate)
            }
        )
        return (sut, state, textInsertion, sessionMemory)
    }

    @MainActor func testLocalDictationAutoInsertRaw() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true,
            hasInsertionCursor: true,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            role: "AXTextField",
            processIdentifier: nil
        )

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-1",
            rawText: "hello world raw text",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: true,
            toneStyle: .neutral,
            insertBehavior: .autoInsertRaw,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.95,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(state.transcriptCandidate?.rawText, "hello world raw text")
        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.insertedText, "hello world raw text")
        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertEqual(recordedStages, ["insert"])
    }

    @MainActor func testLocalDictationWhisperKitAlwaysReview() async throws {
        let (sut, state, textInsertion, _) = makeSUT()

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-2",
            rawText: "hello world clean me",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .alwaysReview,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(state.transcriptCandidate?.rawText, "hello world clean me")
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertEqual(state.statusLine, "Review and insert")
        XCTAssertEqual(textInsertion.insertCallCount, 0)
        XCTAssertTrue(recordedStages.contains("cleanup_light_local"))
        XCTAssertTrue(recordedStages.contains("cleanup_polish_local"))
    }

    @MainActor func testLocalDictationWhisperKitAutoInsertUsesSingleBackendCall() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        let polishResponse = """
        {
            "output_text": "hello world polished by ollama",
            "mode_applied": "polish",
            "guardrail_triggered": false
        }
        """.data(using: .utf8)!

        var requestCount = 0
        DictationMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/cleanup")
            XCTAssertEqual(request.httpMethod, "POST")
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Auto-insert polish needs only the polish round-trip.
            return (response, polishResponse)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-whisperkit-backend",
            rawText: "hello world clean me",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertPolish,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        // Only the inserted mode (polish) hits the slow backend; the unused
        // light field is filled cheaply in-app.
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(state.transcriptCandidate?.rawText, "hello world clean me")
        XCTAssertEqual(state.transcriptCandidate?.polishText, "hello world polished by ollama")
        XCTAssertNotEqual(state.transcriptCandidate?.lightText, "hello world polished by ollama")
        XCTAssertFalse((state.transcriptCandidate?.lightText ?? "").isEmpty)
        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.insertedText, "hello world polished by ollama")
        XCTAssertTrue(recordedStages.contains("cleanup_polish_api"))
        XCTAssertFalse(recordedStages.contains("cleanup_light_api"))
    }

    /// Local-only auto-insert (here via the API Whisper STT backend) makes a
    /// SINGLE backend call — only the inserted mode round-trips; the unused mode
    /// is filled locally. (The single-call optimization gates on
    /// providerMode == .localOnly, NOT on "remote" — see the privateAPI test
    /// below for the two-call path.)
    @MainActor func testLocalWhisperAutoInsertPolishMakesSingleBackendCall() async throws {
        let (sut, state, textInsertion, _) = makeSUT()

        let polishResponse = """
        {
            "output_text": "hello world polished text",
            "mode_applied": "polish",
            "guardrail_triggered": false
        }
        """.data(using: .utf8)!

        var requestCount = 0
        DictationMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/cleanup")
            XCTAssertEqual(request.httpMethod, "POST")
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, polishResponse)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-3",
            rawText: "hello world raw input",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertPolish,
            sttBackend: .whisper, // Whisper uses the API STT backend, still localOnly
            lastTranscriptionConfidence: 0.92,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        // Auto-insert polish makes a single backend call; the unused light
        // field is filled locally and never round-trips.
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(state.transcriptCandidate?.rawText, "hello world raw input")
        XCTAssertEqual(state.transcriptCandidate?.polishText, "hello world polished text")
        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.insertedText, "hello world polished text")
        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertTrue(recordedStages.contains("cleanup_polish_api"))
        XCTAssertFalse(recordedStages.contains("cleanup_light_api"))
    }

    /// PrivateAPI dictation resolves BOTH modes via the backend (autoMode is nil
    /// for non-localOnly) and goes to REVIEW even with an auto-insert behavior —
    /// the redacted/cleaned version must be shown before anything is inserted.
    /// This covers the two-call branch the single-call optimization skips.
    @MainActor func testPrivateAPIDictationResolvesBothModesAndReviews() async throws {
        let (sut, state, textInsertion, _) = makeSUT()

        let lightResponse = """
        {"output_text": "hello world light cleaned", "mode_applied": "light", "guardrail_triggered": false}
        """.data(using: .utf8)!
        let polishResponse = """
        {"output_text": "hello world polished text", "mode_applied": "polish", "guardrail_triggered": false}
        """.data(using: .utf8)!

        var requestCount = 0
        DictationMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/cleanup")
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return requestCount == 1 ? (response, lightResponse) : (response, polishResponse)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-private",
            rawText: "hello world raw input",
            providerMode: .privateAPI,
            consentToken: "test-consent",
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertPolish, // ignored for privateAPI — still reviews
            sttBackend: .whisper,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(requestCount, 2, "privateAPI resolves both modes via the backend")
        XCTAssertEqual(state.transcriptCandidate?.lightText, "hello world light cleaned")
        XCTAssertEqual(state.transcriptCandidate?.polishText, "hello world polished text")
        XCTAssertEqual(textInsertion.insertCallCount, 0, "privateAPI reviews, never auto-inserts")
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertTrue(recordedStages.contains("cleanup_light_api"))
        XCTAssertTrue(recordedStages.contains("cleanup_polish_api"))
    }

    /// Review mode (no auto-insert mode) still resolves BOTH light and polish
    /// through the backend so the review toggle shows real LLM output for each.
    @MainActor func testReviewDictationResolvesBothModesViaBackend() async throws {
        let (sut, state, textInsertion, _) = makeSUT()

        let lightResponse = """
        {
            "output_text": "hello world light cleaned",
            "mode_applied": "light",
            "guardrail_triggered": false
        }
        """.data(using: .utf8)!

        let polishResponse = """
        {
            "output_text": "hello world polished text",
            "mode_applied": "polish",
            "guardrail_triggered": false
        }
        """.data(using: .utf8)!

        var requestCount = 0
        DictationMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/cleanup")
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return requestCount == 1 ? (response, lightResponse) : (response, polishResponse)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-review",
            rawText: "hello world raw input",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .alwaysReview,
            sttBackend: .whisper,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(state.transcriptCandidate?.lightText, "hello world light cleaned")
        XCTAssertEqual(state.transcriptCandidate?.polishText, "hello world polished text")
        XCTAssertEqual(textInsertion.insertCallCount, 0)
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertTrue(recordedStages.contains("cleanup_light_api"))
        XCTAssertTrue(recordedStages.contains("cleanup_polish_api"))
    }

    /// Audit S7: the transcript candidate must carry the frozen capture
    /// target so a later re-insert from history can resolve the ORIGINAL
    /// destination instead of whatever app is frontmost at click time
    /// (which is VoxFlow's own panel).
    @MainActor func testCandidateCarriesFrozenTargetProcessIdentifier() async throws {
        let (sut, state, _, _) = makeSUT()
        let request = DictationWorkflowRequest(
            sessionID: "dictation-target",
            rawText: "carry the target",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: true,
            toneStyle: .neutral,
            insertBehavior: .alwaysReview,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9,
            targetApp: NSRunningApplication.current
        )
        try await sut.processDictation(request) { _, _, _ in }
        XCTAssertEqual(
            state.transcriptCandidate?.targetProcessIdentifier,
            NSRunningApplication.current.processIdentifier
        )
    }

    /// A cancelled in-flight backend cleanup (the user dismissed the capture, or
    /// a newer capture superseded this one) must abort — NOT fall through to the
    /// local cleanup pipeline and insert text the user cancelled. URLSession
    /// surfaces task cancellation as `URLError.cancelled`.
    @MainActor func testWhisperKitBackendCancellationRethrowsAndDoesNotInsert() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        DictationMockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        let request = DictationWorkflowRequest(
            sessionID: "dictation-cancelled",
            rawText: "hello world clean me",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertPolish,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        do {
            try await sut.processDictation(request) { _, _, _ in }
            XCTFail("Cancellation must propagate, not be swallowed into a local insert")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(textInsertion.insertCallCount, 0)
        XCTAssertNil(state.transcriptCandidate)
    }

    /// A genuine backend failure (Ollama down / timeout / 5xx) is NOT a
    /// cancellation: dictation still completes via the in-app cleanup fallback
    /// and inserts. This guards that the cancellation discrimination doesn't
    /// regress the legitimate fallback.
    @MainActor func testWhisperKitBackendGenuineErrorFallsBackToLocalAndInserts() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        DictationMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        var recordedStages: [String] = []
        let request = DictationWorkflowRequest(
            sessionID: "dictation-backend-down",
            rawText: "hello world clean me",
            providerMode: .localOnly,
            consentToken: nil,
            allowRaw: false,
            toneStyle: .neutral,
            insertBehavior: .autoInsertPolish,
            sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9,
            targetApp: nil
        )

        try await sut.processDictation(request) { name, _, _ in
            recordedStages.append(name)
        }

        XCTAssertTrue(recordedStages.contains("cleanup_api_fallback"))
        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertNotNil(state.transcriptCandidate)
    }

    /// Provenance: when the backend serves real model output, the insert status
    /// suffix (which becomes the audit `source`) must name the model so the
    /// receipt proves Gemma ran.
    @MainActor func testAutoInsertSuffixCarriesModelProvenance() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        let polishResponse = """
        {"output_text": "polished by gemma", "mode_applied": "polish", "guardrail_triggered": false, "served_by": "ollama", "model_id": "gemma4:e2b-mlx"}
        """.data(using: .utf8)!
        DictationMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, polishResponse)
        }

        let request = DictationWorkflowRequest(
            sessionID: "prov-gemma", rawText: "clean me", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertPolish, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9, targetApp: nil)

        try await sut.processDictation(request) { _, _, _ in }

        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.statusSuffix?.contains("gemma4:e2b-mlx"), true,
                       "suffix was \(textInsertion.statusSuffix ?? "nil")")
    }

    /// Provenance: when Ollama is down the backend serves the regex floor
    /// (served_by == "regex"); the suffix/audit must say so, not look identical
    /// to a real Gemma run.
    @MainActor func testAutoInsertSuffixShowsRegexFallbackWhenServedByRegex() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        let regexResponse = """
        {"output_text": "regex floored", "mode_applied": "polish", "guardrail_triggered": false, "served_by": "regex", "degraded_reason": "backend_unavailable"}
        """.data(using: .utf8)!
        DictationMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, regexResponse)
        }

        let request = DictationWorkflowRequest(
            sessionID: "prov-regex", rawText: "clean me", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertPolish, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9, targetApp: nil)

        try await sut.processDictation(request) { _, _, _ in }

        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.statusSuffix?.contains("regex fallback"), true,
                       "suffix was \(textInsertion.statusSuffix ?? "nil")")
    }

    /// Provenance (review mode): always-review resolves BOTH modes via the
    /// backend, so the candidate must carry per-mode provenance for the LATER
    /// review insert to stamp the receipt correctly.
    @MainActor func testReviewModeCandidateCarriesPerModeProvenance() async throws {
        let (sut, state, _, _) = makeSUT()

        let lightResponse = """
        {"output_text": "l", "mode_applied": "light", "guardrail_triggered": false, "served_by": "rules"}
        """.data(using: .utf8)!
        let polishResponse = """
        {"output_text": "p", "mode_applied": "polish", "guardrail_triggered": false, "served_by": "ollama", "model_id": "gemma4:e2b-mlx"}
        """.data(using: .utf8)!

        var requestCount = 0
        DictationMockURLProtocol.requestHandler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return requestCount == 1 ? (response, lightResponse) : (response, polishResponse)
        }

        let request = DictationWorkflowRequest(
            sessionID: "prov-review", rawText: "clean me", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .alwaysReview, sttBackend: .whisper,
            lastTranscriptionConfidence: 0.9, targetApp: nil)

        try await sut.processDictation(request) { _, _, _ in }

        XCTAssertEqual(state.transcriptCandidate?.lightProvenance, "rules")
        XCTAssertEqual(state.transcriptCandidate?.polishProvenance, "gemma4:e2b-mlx")
    }

    /// Provenance: when the backend is cold the in-app Swift cleanup path runs;
    /// the suffix must mark it so the receipt is distinguishable from a backend
    /// regex floor (the two degraded paths used to look identical).
    @MainActor func testInAppCleanupSuffixMarkedInApp() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = false // backend cold → in-app path

        let request = DictationWorkflowRequest(
            sessionID: "prov-inapp", rawText: "clean me locally", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertPolish, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9, targetApp: nil)

        try await sut.processDictation(request) { _, _, _ in }

        XCTAssertEqual(textInsertion.insertCallCount, 1)
        XCTAssertEqual(textInsertion.statusSuffix?.contains("in-app"), true,
                       "suffix was \(textInsertion.statusSuffix ?? "nil")")
    }
}
