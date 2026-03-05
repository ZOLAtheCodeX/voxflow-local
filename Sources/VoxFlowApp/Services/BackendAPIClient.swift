import Foundation

struct TranscribeResponse: Codable {
    let text: String
    let isFinal: Bool
    let latencyMs: Int
    let confidenceEstimate: Double
    let processingTimeMs: Int
}

struct CleanupResponse: Codable {
    let outputText: String
    let modeApplied: String
    let guardrailTriggered: Bool
}

struct TranslateResponse: Codable {
    let sourceText: String
    let translatedText: String
}

struct MeetingSpeakerSegmentResponse: Codable {
    let speaker: String
    let text: String
    let utteranceCount: Int
}

struct MeetingTaskOwnerResponse: Codable {
    let task: String
    let owner: String
    let confidence: Double
}

struct MeetingSummaryResponse: Codable {
    let transcript: String
    let summary: String
    let decisions: [String]
    let actionItems: [String]
    let followUps: [String]
    let speakerSegments: [MeetingSpeakerSegmentResponse]
    let taskOwners: [MeetingTaskOwnerResponse]
    let markdownExport: String
    let notionExport: String
}

struct PromptFrameResponse: Codable {
    let framedPrompt: String
    let detectedIntent: String
}

struct PrivacyPreviewResponse: Codable {
    let operation: String
    let token: String
    let originalText: String
    let redactedText: String
}

struct BackendReadinessResponse: Codable {
    let serviceStatus: String
    let readyForDictation: Bool
    let sttBackend: String
    let activeSttModel: String
    let activeSttModelLoaded: Bool
    let sttFallbackActive: Bool
    let offlineMode: Bool
    let pythonExecutable: String
    let pythonVersion: String
    let modelsDir: String
    let modelsDirExists: Bool
    let openaiAudioConfigured: Bool
    let privateApiConfigured: Bool
    let privateApiPolicyVersion: String
    let privateApiPolicyReady: Bool
    let issues: [String]
}

enum BackendError: LocalizedError {
    case httpError(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let detail):
            return "Backend error \(statusCode): \(detail)"
        }
    }
}

enum BackendAPIClient {
    static var baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        guard let url = URL(string: "http://127.0.0.1:8765") else {
            fatalError("Failed to create default backend URL")
        }
        return url
    }()

    static var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static func checkHTTPStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        // Try to extract FastAPI's {"detail": "..."} error body
        let detail: String
        if let errorBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = errorBody["detail"] as? String {
            detail = message
        } else {
            detail = String(data: data, encoding: .utf8) ?? "Unknown error"
        }
        throw BackendError.httpError(statusCode: http.statusCode, detail: detail)
    }

    private static func performRequest<Response: Decodable, Payload: Encodable>(path: String, payload: Payload) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private static func performGetRequest<Response: Decodable>(path: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    static func health() async throws -> [String: String] {
        return try await performGetRequest(path: "v1/health")
    }

    static func ready() async throws -> BackendReadinessResponse {
        return try await performGetRequest(path: "v1/ready")
    }

    static func transcribe(
        sessionID: String,
        audioPCM: Data,
        sampleRate: Int,
        chunkIndex: Int,
        languageHint: String
    ) async throws -> TranscribeResponse {
        struct Payload: Codable {
            let sessionId: String
            let audioPcm16le: String
            let sampleRate: Int
            let languageHint: String
            let chunkIndex: Int
        }

        let payload = Payload(
            sessionId: sessionID,
            audioPcm16le: audioPCM.base64EncodedString(),
            sampleRate: sampleRate,
            languageHint: languageHint,
            chunkIndex: chunkIndex
        )

        return try await performRequest(path: "v1/transcribe", payload: payload)
    }

    static func cleanup(
        sessionID: String,
        mode: CleanupMode,
        inputText: String,
        toneStyle: ToneStyle,
        providerMode: ProviderMode = .localOnly,
        consentToken: String? = nil,
        allowRaw: Bool = false
    ) async throws -> CleanupResponse {
        struct Payload: Codable {
            let sessionId: String
            let mode: String
            let inputText: String
            let toneStyle: String
            let providerMode: String
            let consentToken: String?
            let allowRaw: Bool
        }

        let payload = Payload(
            sessionId: sessionID,
            mode: mode.rawValue,
            inputText: inputText,
            toneStyle: toneStyle.rawValue,
            providerMode: providerMode.rawValue,
            consentToken: consentToken,
            allowRaw: allowRaw
        )

        return try await performRequest(path: "v1/cleanup", payload: payload)
    }

    static func translate(
        sessionID: String,
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        providerMode: ProviderMode = .localOnly,
        consentToken: String? = nil,
        allowRaw: Bool = false
    ) async throws -> TranslateResponse {
        struct Payload: Codable {
            let sessionId: String
            let sourceText: String
            let sourceLanguage: String
            let targetLanguage: String
            let providerMode: String
            let consentToken: String?
            let allowRaw: Bool
        }

        let payload = Payload(
            sessionId: sessionID,
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            providerMode: providerMode.rawValue,
            consentToken: consentToken,
            allowRaw: allowRaw
        )

        return try await performRequest(path: "v1/translate", payload: payload)
    }

    static func meetingSummarize(
        sessionID: String,
        transcript: String,
        toneStyle: ToneStyle,
        providerMode: ProviderMode = .localOnly,
        consentToken: String? = nil,
        allowRaw: Bool = false
    ) async throws -> MeetingSummaryResponse {
        struct Payload: Codable {
            let sessionId: String
            let transcript: String
            let toneStyle: String
            let providerMode: String
            let consentToken: String?
            let allowRaw: Bool
        }

        let payload = Payload(
            sessionId: sessionID,
            transcript: transcript,
            toneStyle: toneStyle.rawValue,
            providerMode: providerMode.rawValue,
            consentToken: consentToken,
            allowRaw: allowRaw
        )

        return try await performRequest(path: "v1/meeting_summarize", payload: payload)
    }

    static func framePrompt(
        sessionID: String,
        text: String,
        consentToken: String? = nil
    ) async throws -> PromptFrameResponse {
        struct Payload: Codable {
            let sessionId: String
            let text: String
            let consentToken: String?
        }

        let payload = Payload(
            sessionId: sessionID,
            text: text,
            consentToken: consentToken
        )

        return try await performRequest(path: "v1/prompt/frame", payload: payload)
    }

    static func privacyPreview(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String
    ) async throws -> PrivacyPreviewResponse {
        struct Payload: Codable {
            let sessionId: String
            let operation: String
            let inputText: String
        }

        let payload = Payload(
            sessionId: sessionID,
            operation: operation.rawValue,
            inputText: inputText
        )

        return try await performRequest(path: "v1/privacy/preview", payload: payload)
    }
}
