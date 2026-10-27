import XCTest
@testable import VoxFlowApp

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// The one path the running test exercises. Anything else is a stray from a
    /// task that outlived an earlier test (AppCoordinator.shared's readiness
    /// poller keeps calling /v1/ready through the global session) and is failed
    /// quietly instead of tripping this test's handler assertions.
    nonisolated(unsafe) static var expectedPath: String?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        if let expected = MockURLProtocol.expectedPath, request.url?.path != expected {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        guard let handler = MockURLProtocol.requestHandler else {
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

    override func stopLoading() {
        // Required, but we don't need to do anything
    }
}

final class BackendAPIClientTests: XCTestCase {
    private var originalSession: URLSession!
    private var originalBaseURL: URL!
    private var originalToken: String?

    override func setUp() {
        super.setUp()
        originalSession = BackendAPIClient.session
        originalBaseURL = BackendAPIClient.baseURL
        originalToken = BackendAuthToken.current()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        BackendAPIClient.session = URLSession(configuration: configuration)
        BackendAPIClient.baseURL = URL(string: "http://mock.test")!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.expectedPath = nil
        BackendAPIClient.session = originalSession
        BackendAPIClient.baseURL = originalBaseURL
        BackendAuthToken.set(originalToken)
        super.tearDown()
    }

    func testHealth_Success() async throws {
        // Arrange
        let expectedDictionary = ["status": "ok"]
        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/health")
            XCTAssertEqual(request.httpMethod, "GET")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = try JSONSerialization.data(withJSONObject: expectedDictionary)
            return (response, data)
        }

        // Act
        let result = try await BackendAPIClient.health()

        // Assert
        XCTAssertEqual(result, expectedDictionary)
    }

    /// The backend returns provenance (served_by / model_id / degraded_reason /
    /// fallback_depth) on every cleanup. Swift must decode it so the audit log
    /// can tell Gemma output from the regex fallback floor.
    func testCleanupDecodesProvenanceFields() async throws {
        let body = """
        {
            "output_text": "polished",
            "mode_applied": "polish",
            "guardrail_triggered": false,
            "served_by": "ollama",
            "model_id": "gemma4:e2b-mlx",
            "degraded_reason": null,
            "fallback_depth": 0
        }
        """
        MockURLProtocol.expectedPath = "/v1/cleanup"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/cleanup")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await BackendAPIClient.cleanup(
            sessionID: "s", mode: .polish, inputText: "x", toneStyle: .neutral)

        XCTAssertEqual(result.outputText, "polished")
        XCTAssertEqual(result.servedBy, "ollama")
        XCTAssertEqual(result.modelId, "gemma4:e2b-mlx")
        XCTAssertNil(result.degradedReason)
        XCTAssertEqual(result.fallbackDepth, 0)
    }

    /// A response WITHOUT the provenance fields (older/lean backend) must still
    /// decode — the new fields are optional, not required.
    func testCleanupDecodesWithoutProvenanceFields() async throws {
        let body = """
        {"output_text": "x", "mode_applied": "light", "guardrail_triggered": false}
        """
        MockURLProtocol.expectedPath = "/v1/cleanup"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await BackendAPIClient.cleanup(
            sessionID: "s", mode: .light, inputText: "x", toneStyle: .neutral)

        XCTAssertEqual(result.outputText, "x")
        XCTAssertNil(result.servedBy)
        XCTAssertNil(result.modelId)
    }

    func testTranscribe_Success() async throws {
        // Arrange
        let mockResponse = """
        {
            "text": "Hello world",
            "is_final": true,
            "latency_ms": 150,
            "confidence_estimate": 0.98,
            "processing_time_ms": 140
        }
        """.data(using: .utf8)!

        MockURLProtocol.expectedPath = "/v1/transcribe"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/transcribe")
            XCTAssertEqual(request.httpMethod, "POST")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, mockResponse)
        }

        // Act
        let audioData = Data(count: 32)
        let result = try await BackendAPIClient.transcribe(
            sessionID: "test-session",
            audioPCM: audioData,
            sampleRate: 16000,
            chunkIndex: 0,
            languageHint: "en"
        )

        // Assert
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertTrue(result.isFinal)
        XCTAssertEqual(result.latencyMs, 150)
        XCTAssertEqual(result.confidenceEstimate, 0.98)
        XCTAssertEqual(result.processingTimeMs, 140)
    }

    func testPerformRequest_HTTPError() async {
        // Arrange
        let mockResponse = """
        {"error": "Internal Server Error"}
        """.data(using: .utf8)!

        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, mockResponse)
        }

        // Act & Assert
        do {
            _ = try await BackendAPIClient.health()
            XCTFail("Expected HTTP error to be thrown")
        } catch BackendError.httpError(let statusCode, let detail) {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(detail, "{\"error\": \"Internal Server Error\"}")
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }

    func testPerformRequest_FastAPIError() async {
        // Arrange
        let mockResponse = """
        {"detail": "Invalid session ID"}
        """.data(using: .utf8)!

        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (response, mockResponse)
        }

        // Act & Assert
        do {
            _ = try await BackendAPIClient.health()
            XCTFail("Expected HTTP error to be thrown")
        } catch BackendError.httpError(let statusCode, let detail) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertEqual(detail, "Invalid session ID")
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }

    // MARK: - Launch token (trust boundary)

    private static let readyBody = """
    {"service_status":"ok","ready_for_dictation":true,"stt_backend":"whisper","active_stt_model":"m",
     "active_stt_model_loaded":true,"stt_fallback_active":false,"offline_mode":true,
     "python_executable":"/p","python_version":"3.12","models_dir":"/m","models_dir_exists":true,
     "openai_audio_configured":false,"private_api_configured":false,"private_api_policy_version":"1",
     "private_api_policy_ready":false,"issues":[]}
    """

    /// Stubs `path` with a 200 JSON body and records the token header the request carried.
    private func stubRecordingToken(
        _ path: String, body: String, into sink: TokenSink, method: String? = nil
    ) {
        MockURLProtocol.expectedPath = path
        MockURLProtocol.requestHandler = { request in
            sink.record(path, request.value(forHTTPHeaderField: BackendAuthToken.headerName))
            if let method { XCTAssertEqual(request.httpMethod, method) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
    }

    final class TokenSink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String?] = [:]
        func record(_ path: String, _ value: String?) {
            lock.lock(); defer { lock.unlock() }
            values[path] = .some(value)
        }
        var snapshot: [String: String?] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    func testEveryRequestBuilderAttachesToken() async throws {
        let token = String(repeating: "ab", count: 32)
        BackendAuthToken.set(token)
        let sink = TokenSink()

        stubRecordingToken(
            "/v1/cleanup",
            body: #"{"output_text":"x","mode_applied":"light","guardrail_triggered":false}"#, into: sink)
        _ = try await BackendAPIClient.cleanup(sessionID: "s", mode: .light, inputText: "x", toneStyle: .neutral)

        stubRecordingToken("/v1/ready", body: Self.readyBody, into: sink)
        _ = try await BackendAPIClient.ready()

        stubRecordingToken(
            "/v1/smart_action",
            body: #"{"action_id":"memo","output":"o","guardrail_triggered":false}"#, into: sink)
        _ = try await BackendAPIClient.performSmartAction(.memo, transcript: "t")

        stubRecordingToken(
            "/v1/providers/test",
            body: #"{"provider_id":"p","reachable":true,"detail":"ok"}"#, into: sink)
        _ = try await BackendAPIClient.providerTest(providerID: "p")

        stubRecordingToken("/v1/notion/search", body: #"{"results":[]}"#, into: sink)
        _ = try await BackendAPIClient.notionSearch(query: "q", token: "notion-secret")

        stubRecordingToken("/v1/notion/append", body: #"{"appended_blocks":1}"#, into: sink)
        _ = try await BackendAPIClient.notionAppend(pageId: "pg", text: "t", token: "notion-secret")

        stubRecordingToken("/v1/ollama/pull", body: "{\"status\":\"success\"}\n", into: sink)
        try await BackendAPIClient.ollamaPull(model: "m", onProgress: { _ in })

        let seen = sink.snapshot
        XCTAssertEqual(seen.count, 7, "expected one recorded request per builder, got \(seen.keys.sorted())")
        for (path, value) in seen {
            XCTAssertEqual(value, token, "\(path) did not carry the token")
        }
    }

    func testRequestsOmitTokenHeaderWhenNoneIsSet() async throws {
        BackendAuthToken.set(nil)
        let sink = TokenSink()

        stubRecordingToken("/v1/ready", body: Self.readyBody, into: sink, method: "GET")
        _ = try await BackendAPIClient.ready()

        stubRecordingToken(
            "/v1/cleanup",
            body: #"{"output_text":"x","mode_applied":"light","guardrail_triggered":false}"#,
            into: sink, method: "POST")
        _ = try await BackendAPIClient.cleanup(sessionID: "s", mode: .light, inputText: "x", toneStyle: .neutral)

        stubRecordingToken("/v1/ollama/pull", body: "{\"status\":\"success\"}\n", into: sink, method: "POST")
        try await BackendAPIClient.ollamaPull(model: "m", onProgress: { _ in })

        let seen = sink.snapshot
        XCTAssertEqual(seen.count, 3)
        for (path, value) in seen {
            XCTAssertNil(value, "\(path) sent a token header with no token set")
        }
    }

    func testRequestsOmitTokenHeaderWhenTokenIsEmpty() async throws {
        BackendAuthToken.set("")
        let sink = TokenSink()
        stubRecordingToken("/v1/ready", body: Self.readyBody, into: sink)
        _ = try await BackendAPIClient.ready()
        XCTAssertNil(sink.snapshot["/v1/ready"] ?? nil)
        XCTAssertEqual(sink.snapshot.count, 1)
    }

    func testIdentityProbeReadsInstanceStampWithoutToken() async throws {
        BackendAuthToken.set(nil)
        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "X-VoxFlow-Token"))
            XCTAssertEqual(request.httpMethod, "GET")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"instance_stamp":"previous-launch"}"#.utf8))
        }
        let stamp = try await BackendAPIClient.identityProbe()
        XCTAssertEqual(stamp, "previous-launch")
    }

    /// The probe exists to identify an UNVERIFIED listener on the port, so it must
    /// never hand that listener the launch token, even when one is held.
    func testIdentityProbeNeverSendsTokenEvenWhenHeld() async throws {
        BackendAuthToken.set(String(repeating: "ab", count: 32))
        let sink = TokenSink()
        stubRecordingToken("/v1/health", body: #"{"instance_stamp":"squatter-or-not"}"#, into: sink, method: "GET")
        let stamp = try await BackendAPIClient.identityProbe()
        XCTAssertEqual(stamp, "squatter-or-not")
        XCTAssertEqual(sink.snapshot.count, 1)
        XCTAssertNil(sink.snapshot["/v1/health"] ?? nil, "identityProbe leaked the token")
    }

    func testHealthNeverSendsTokenEvenWhenHeld() async throws {
        BackendAuthToken.set(String(repeating: "ab", count: 32))
        let sink = TokenSink()
        stubRecordingToken("/v1/health", body: #"{"status":"ok"}"#, into: sink)
        _ = try await BackendAPIClient.health()
        XCTAssertEqual(sink.snapshot.count, 1)
        XCTAssertNil(sink.snapshot["/v1/health"] ?? nil, "health() leaked the token")
    }

    func testIdentityProbeReturnsEmptyStringWhenStampAbsent() async throws {
        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"status":"ok"}"#.utf8))
        }
        let stamp = try await BackendAPIClient.identityProbe()
        XCTAssertEqual(stamp, "")
    }

    func testIdentityProbeAppliesTimeoutInterval() async throws {
        MockURLProtocol.expectedPath = "/v1/health"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.timeoutInterval, 3, accuracy: 0.001)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"instance_stamp":"s"}"#.utf8))
        }
        _ = try await BackendAPIClient.identityProbe()
    }

    func testOllamaPullSurfacesBackendDetailOnError() async {
        MockURLProtocol.expectedPath = "/v1/ollama/pull"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"detail":"Missing or invalid token"}"#.utf8))
        }
        do {
            try await BackendAPIClient.ollamaPull(model: "m", onProgress: { _ in })
            XCTFail("Expected HTTP error to be thrown")
        } catch BackendError.httpError(let statusCode, let detail) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(detail, "Missing or invalid token")
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }
}
