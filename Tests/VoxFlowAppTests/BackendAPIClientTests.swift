import XCTest
@testable import VoxFlowApp

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            fatalError("Handler is unavailable.")
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

    override func setUp() {
        super.setUp()
        originalSession = BackendAPIClient.session
        originalBaseURL = BackendAPIClient.baseURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        BackendAPIClient.session = URLSession(configuration: configuration)
        BackendAPIClient.baseURL = URL(string: "http://mock.test")!
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        BackendAPIClient.session = originalSession
        BackendAPIClient.baseURL = originalBaseURL
        super.tearDown()
    }

    func testHealth_Success() async throws {
        // Arrange
        let expectedDictionary = ["status": "ok"]
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
}
