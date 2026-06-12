import Foundation

struct TranscribeResponse: Codable {
    let text: String
    let isFinal: Bool
    let latencyMs: Int
    let confidenceEstimate: Double
    let processingTimeMs: Int
    let stageTimingsMs: [String: Int]?
    let modelLoadedBeforeRequest: Bool?
    let modelLoadedAfterRequest: Bool?
    let coldStart: Bool?
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
    let ollamaAvailable: Bool
    // BYOM provenance (R3.4) — optional so older backends still decode.
    let activePolishProvider: String
    let activePolishModel: String
    let polishChain: [String]
    let instanceStamp: String
    let issues: [String]

    init(
        serviceStatus: String,
        readyForDictation: Bool,
        sttBackend: String,
        activeSttModel: String,
        activeSttModelLoaded: Bool,
        sttFallbackActive: Bool,
        offlineMode: Bool,
        pythonExecutable: String,
        pythonVersion: String,
        modelsDir: String,
        modelsDirExists: Bool,
        openaiAudioConfigured: Bool,
        privateApiConfigured: Bool,
        privateApiPolicyVersion: String,
        privateApiPolicyReady: Bool,
        ollamaAvailable: Bool = false,
        activePolishProvider: String = "",
        activePolishModel: String = "",
        polishChain: [String] = [],
        instanceStamp: String = "",
        issues: [String]
    ) {
        self.serviceStatus = serviceStatus
        self.readyForDictation = readyForDictation
        self.sttBackend = sttBackend
        self.activeSttModel = activeSttModel
        self.activeSttModelLoaded = activeSttModelLoaded
        self.sttFallbackActive = sttFallbackActive
        self.offlineMode = offlineMode
        self.pythonExecutable = pythonExecutable
        self.pythonVersion = pythonVersion
        self.modelsDir = modelsDir
        self.modelsDirExists = modelsDirExists
        self.openaiAudioConfigured = openaiAudioConfigured
        self.privateApiConfigured = privateApiConfigured
        self.privateApiPolicyVersion = privateApiPolicyVersion
        self.privateApiPolicyReady = privateApiPolicyReady
        self.ollamaAvailable = ollamaAvailable
        self.activePolishProvider = activePolishProvider
        self.activePolishModel = activePolishModel
        self.polishChain = polishChain
        self.instanceStamp = instanceStamp
        self.issues = issues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceStatus = try container.decode(String.self, forKey: .serviceStatus)
        readyForDictation = try container.decode(Bool.self, forKey: .readyForDictation)
        sttBackend = try container.decode(String.self, forKey: .sttBackend)
        activeSttModel = try container.decode(String.self, forKey: .activeSttModel)
        activeSttModelLoaded = try container.decode(Bool.self, forKey: .activeSttModelLoaded)
        sttFallbackActive = try container.decode(Bool.self, forKey: .sttFallbackActive)
        offlineMode = try container.decode(Bool.self, forKey: .offlineMode)
        pythonExecutable = try container.decode(String.self, forKey: .pythonExecutable)
        pythonVersion = try container.decode(String.self, forKey: .pythonVersion)
        modelsDir = try container.decode(String.self, forKey: .modelsDir)
        modelsDirExists = try container.decode(Bool.self, forKey: .modelsDirExists)
        openaiAudioConfigured = try container.decode(Bool.self, forKey: .openaiAudioConfigured)
        privateApiConfigured = try container.decode(Bool.self, forKey: .privateApiConfigured)
        privateApiPolicyVersion = try container.decode(String.self, forKey: .privateApiPolicyVersion)
        privateApiPolicyReady = try container.decode(Bool.self, forKey: .privateApiPolicyReady)
        ollamaAvailable = try container.decodeIfPresent(Bool.self, forKey: .ollamaAvailable) ?? false
        activePolishProvider = try container.decodeIfPresent(String.self, forKey: .activePolishProvider) ?? ""
        activePolishModel = try container.decodeIfPresent(String.self, forKey: .activePolishModel) ?? ""
        polishChain = try container.decodeIfPresent([String].self, forKey: .polishChain) ?? []
        instanceStamp = try container.decodeIfPresent(String.self, forKey: .instanceStamp) ?? ""
        issues = try container.decode([String].self, forKey: .issues)
    }
}

struct OllamaModelInfo: Codable, Identifiable, Hashable {
    let name: String
    let size: Int
    let digest: String
    let modifiedAt: String

    var id: String { name }
}

struct OllamaModelsResponse: Codable {
    let available: Bool
    let models: [OllamaModelInfo]
    let currentModel: String
    let recommendedModel: String?
    let hostMemoryGb: Double
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

/// Shared Keychain account key for the Notion integration token.
/// Used by BackendAPIClient methods, SettingsView, and CockpitCoordinator.
enum NotionKeychain {
    static let account = "notion.integration.token"
}

enum BackendAPIClient {
#if DEBUG
    nonisolated(unsafe) static var baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        guard let url = URL(string: "http://127.0.0.1:8765") else {
            fatalError("Failed to create default backend URL")
        }
        return url
    }()

    nonisolated(unsafe) static var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
#else
    private static let baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        guard let url = URL(string: "http://127.0.0.1:8765") else {
            fatalError("Failed to create default backend URL")
        }
        return url
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
#endif

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

    private static func performGetRequest<Response: Decodable>(
        path: String,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }

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

    /// Identity probe for the launch-time stale-listener check. The shared
    /// session allows 120 s (model warmup); this must fail fast instead when
    /// a wedged process squats on the port.
    static func readyProbe(timeoutInterval: TimeInterval = 3) async throws -> BackendReadinessResponse {
        return try await performGetRequest(path: "v1/ready", timeoutInterval: timeoutInterval)
    }

    static func ollamaModels() async throws -> OllamaModelsResponse {
        return try await performGetRequest(path: "v1/ollama/models")
    }

    /// Cockpit Layer 0 — apply a smart action to a captured transcript.
    static func performSmartAction(
        _ action: SmartActionId,
        transcript: String
    ) async throws -> SmartActionResult {
        struct Request: Encodable {
            let actionId: String
            let transcript: String

            enum CodingKeys: String, CodingKey {
                case actionId = "action_id"
                case transcript
            }
        }
        struct Response: Decodable {
            let actionId: String
            let output: String
            let guardrailTriggered: Bool
            let error: String?

            enum CodingKeys: String, CodingKey {
                case actionId = "action_id"
                case output
                case guardrailTriggered = "guardrail_triggered"
                case error
            }
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/smart_action"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(actionId: action.rawValue, transcript: transcript))

        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        let parsed = try JSONDecoder().decode(Response.self, from: data)
        let actionId = SmartActionId(rawValue: parsed.actionId) ?? action
        return SmartActionResult(
            actionId: actionId,
            output: parsed.output,
            guardrailTriggered: parsed.guardrailTriggered,
            error: parsed.error
        )
    }

    /// Trigger an Ollama model pull. Streams NDJSON progress lines back from
    /// the backend; ``onProgress`` is invoked once per line so the UI can
    /// surface status and byte-progress. Returns when the stream terminates
    /// (success or error event).
    static func ollamaPull(model: String, onProgress: @escaping @Sendable (String) -> Void) async throws {
        struct Payload: Codable {
            let model: String
        }
        let url = baseURL.appendingPathComponent("v1/ollama/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Payload(model: model))

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BackendError.httpError(statusCode: http.statusCode, detail: "Ollama pull failed")
        }
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onProgress(trimmed)
            }
        }
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

    // MARK: - Notion Integration (Phase C)

    struct ProviderTestResult: Decodable {
        let providerId: String
        let reachable: Bool
        let detail: String
    }

    static func providerTest(providerID: String) async throws -> ProviderTestResult {
        struct Request: Encodable { let providerId: String }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/providers/test"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(providerId: providerID))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(ProviderTestResult.self, from: data)
    }

    static func notionSearch(query: String, token: String) async throws -> [NotionTarget] {
        struct Request: Encodable { let notionToken: String; let query: String }
        struct Response: Decodable { let results: [NotionTarget] }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/notion/search"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(notionToken: token, query: query))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data).results
    }

    static func notionAppend(pageId: String, text: String, token: String) async throws -> Int {
        struct Request: Encodable { let notionToken: String; let pageId: String; let text: String }
        struct Response: Decodable { let appendedBlocks: Int }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/notion/append"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(notionToken: token, pageId: pageId, text: text))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data).appendedBlocks
    }
}
