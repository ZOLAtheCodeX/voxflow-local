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
    // dB of decoder-side gain the in-app WhisperKit path applied before
    // transcription (nil for the backend STT path, which doesn't normalize).
    var appliedGainDB: Double? = nil
    // Decode internals (in-app WhisperKit path) for diagnosing healthy-level
    // empties: mean segment no-speech probability, how many segments the decode
    // produced, and the raw (pre-gain) peak amplitude.
    var meanNoSpeechProb: Double? = nil
    var segmentCount: Int? = nil
    var peakAmplitude: Double? = nil
    // Seconds of speech-bearing audio after the last transcribed segment
    // (in-app WhisperKit path) — the partial-decode / tail-loss flag.
    var speechTailGapSeconds: Double? = nil
}

struct CleanupResponse: Codable {
    let outputText: String
    let modeApplied: String
    let guardrailTriggered: Bool
    // Provenance (R-followup): which provider actually served this cleanup, so
    // the audit log can distinguish a real Gemma/Ollama run from the regex
    // fallback floor. Optional — a lean/older backend response omits them.
    // "rules" = deterministic regex (raw/light modes); "regex" = polish floor;
    // a provider id (e.g. "ollama") = real model output (see `modelId`).
    let servedBy: String?
    let modelId: String?
    let degradedReason: String?
    let fallbackDepth: Int?
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
    /// The listener on the backend port did not prove it is the backend this
    /// launch started, so the request was not sent (no token, no body left the
    /// process).
    case listenerUnverified

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode, let detail):
            return "Backend error \(statusCode): \(detail)"
        case .listenerUnverified:
            return "Backend not verified yet: waiting for the VoxFlow backend"
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
    nonisolated(unsafe) static var baseURL: URL = BackendEndpoint.resolved().url

    nonisolated(unsafe) static var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
#else
    private static let baseURL: URL = BackendEndpoint.resolved().url

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

    /// `tokenBearing` is false for the token-less identity calls: a 401 to one of
    /// those is not a token rejection and must not trigger the reload hook.
    private static func checkHTTPStatus(
        _ response: URLResponse, data: Data, tokenBearing: Bool = true
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        // Adopt mode re-reads the backend's token file after any 401 (the manual
        // backend may have restarted with a new token).
        if http.statusCode == 401 && tokenBearing {
            BackendAuthToken.tokenRejected()
        }

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

    /// The single place a backend request is built: base URL, method, and the
    /// launch token header when one is held. Callers add their own
    /// `Content-Type`, body, and timeout. Pass `attachToken: false` for calls
    /// that must not carry the token (the `/v1/health` identity probe).
    ///
    /// Every token-bearing request first proves the listener on the port is the
    /// backend this launch started (`verifyListener`), so no caller can hand the
    /// token or a body (Notion tokens, audio) to whatever bound the port. Throws
    /// `BackendError.listenerUnverified` before anything is sent.
    private static func makeRequest(
        path: String, method: String, attachToken: Bool = true
    ) async throws -> URLRequest {
        if attachToken {
            try await verifyListener()
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if attachToken, let token = BackendAuthToken.current(), !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: BackendAuthToken.headerName)
        }
        return request
    }

    /// Managed mode publishes the stamp its backend child was launched with;
    /// require the listener to echo it over `/v1/health` (never with the token).
    /// Deliberately uncached: the listener can change between any two requests.
    /// Skipped when no stamp is expected (adopt mode, or no managed backend).
    /// `URLError`s (including cancellation) propagate as themselves so callers
    /// keep their cancellation and connection-failure handling.
    private static func verifyListener() async throws {
        guard let expected = BackendAuthToken.expectedStamp() else { return }
        let reported: String
        do {
            reported = try await identityProbe()
        } catch {
            // Transport failures (a dead backend: .cannotConnectToHost, .timedOut,
            // .networkConnectionLost, cancellation) propagate unchanged so the
            // capture error handler's stale-readiness recovery still sees them.
            // Only a listener that answered wrongly (HTTP error, undecodable
            // body) is "unverified". Either way the guarded request is not sent.
            if error is CancellationError || error is URLError { throw error }
            throw BackendError.listenerUnverified
        }
        guard reported == expected else { throw BackendError.listenerUnverified }
    }

    private static func performRequest<Response: Decodable, Payload: Encodable>(
        path: String,
        payload: Payload,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = try await makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }

        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private static func performGetRequest<Response: Decodable>(
        path: String,
        timeoutInterval: TimeInterval? = nil,
        attachToken: Bool = true
    ) async throws -> Response {
        var request = try await makeRequest(path: path, method: "GET", attachToken: attachToken)
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }

        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data, tokenBearing: attachToken)
        return try decoder.decode(Response.self, from: data)
    }

    static func health() async throws -> [String: String] {
        return try await performGetRequest(path: "v1/health", attachToken: false)
    }

    static func ready() async throws -> BackendReadinessResponse {
        return try await performGetRequest(path: "v1/ready")
    }

    /// Identity probe: reads `instance_stamp` from `/v1/health` (empty string
    /// when the backend does not report one). Never sends the launch token: the
    /// route does not need it and the listener is not yet verified as ours. Uses a short
    /// timeout because the shared session allows 120 s for model warmup, and a
    /// wedged process squatting on the port must fail fast instead.
    static func identityProbe(timeoutInterval: TimeInterval = 3) async throws -> String {
        struct Health: Decodable { let instanceStamp: String? }
        let health: Health = try await performGetRequest(
            path: "v1/health", timeoutInterval: timeoutInterval, attachToken: false)
        return health.instanceStamp ?? ""
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
            let degradedReason: String?

            enum CodingKeys: String, CodingKey {
                case actionId = "action_id"
                case output
                case guardrailTriggered = "guardrail_triggered"
                case error
                case degradedReason = "degraded_reason"
            }
        }

        var request = try await makeRequest(path: "v1/smart_action", method: "POST")
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
            error: parsed.error,
            degradedReason: parsed.degradedReason
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
        var request = try await makeRequest(path: "v1/ollama/pull", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Payload(model: model))

        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The body is a short FastAPI error JSON; read it so the caller sees
            // the backend's own detail (e.g. a 401 token rejection) rather than a
            // fixed string. Capped so a misbehaving listener cannot stream
            // unbounded data into the error path.
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
                if errorBody.count >= 8192 { break }
            }
            try checkHTTPStatus(response, data: errorBody)
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

    /// Speech-presence diagnosis for an empty capture (R6): the backend's
    /// Silero VAD says whether speech was present, so the status line can
    /// distinguish "too quiet" from "background noise only". Localhost-only —
    /// the audio never leaves the machine. Callers treat any thrown error as
    /// "no diagnosis" and keep the RMS-based message (a cold backend refuses
    /// the connection fast; this call never triggers a spawn).
    static func diagnoseAudio(
        sessionID: String,
        audioPCM: Data,
        sampleRate: Int
    ) async throws -> AudioDiagnosis {
        struct Payload: Codable {
            let sessionId: String
            let audioPcm16le: String
            let sampleRate: Int
        }
        struct Response: Decodable {
            let speechDetected: Bool
            let speechMs: Int
            let vadAvailable: Bool
        }

        let response: Response = try await performRequest(
            path: "v1/audio/diagnose",
            payload: Payload(
                sessionId: sessionID,
                audioPcm16le: audioPCM.base64EncodedString(),
                sampleRate: sampleRate
            )
        )
        return AudioDiagnosis(
            speechDetected: response.speechDetected,
            speechMs: response.speechMs,
            vadAvailable: response.vadAvailable
        )
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

        // 45 s: comfortably above the backend's worst honest case (30 s
        // provider timeout + floor fallback + response), well under the
        // session's 120 s. The user is WAITING on this call mid-dictation —
        // a hung connection must fail into the in-app cleanup fallback, not
        // stall the pipeline for two minutes (session 29 stability review;
        // the server-side wedge breaker handles the chronic case).
        return try await performRequest(path: "v1/cleanup", payload: payload, timeoutInterval: 45)
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
        var request = try await makeRequest(path: "v1/providers/test", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(providerId: providerID))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(ProviderTestResult.self, from: data)
    }

    static func notionSearch(query: String, token: String) async throws -> [NotionTarget] {
        struct Request: Encodable { let notionToken: String; let query: String }
        struct Response: Decodable { let results: [NotionTarget] }
        var request = try await makeRequest(path: "v1/notion/search", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(notionToken: token, query: query))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data).results
    }

    static func notionAppend(pageId: String, text: String, token: String) async throws -> Int {
        struct Request: Encodable { let notionToken: String; let pageId: String; let text: String }
        struct Response: Decodable { let appendedBlocks: Int }
        var request = try await makeRequest(path: "v1/notion/append", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Request(notionToken: token, pageId: pageId, text: text))
        let (data, response) = try await session.data(for: request)
        try checkHTTPStatus(response, data: data)
        return try decoder.decode(Response.self, from: data).appendedBlocks
    }
}
