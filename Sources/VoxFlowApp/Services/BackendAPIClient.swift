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

enum BackendAPIClient {
    private static let baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://127.0.0.1:8765")!
    }()

    private static let session: URLSession = {
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

    static func health() async throws -> [String: String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.httpMethod = "GET"

        let (data, _) = try await session.data(for: request)
        return try decoder.decode([String: String].self, from: data)
    }

    static func ready() async throws -> BackendReadinessResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ready"))
        request.httpMethod = "GET"

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(BackendReadinessResponse.self, from: data)
    }

    static func transcribe(
        sessionID: String,
        audioPCM: Data,
        sampleRate: Int,
        chunkIndex: Int,
        languageHint: String
    ) async throws -> TranscribeResponse {
        struct Payload: Codable {
            let session_id: String
            let audio_pcm16le: String
            let sample_rate: Int
            let language_hint: String
            let chunk_index: Int
        }

        let payload = Payload(
            session_id: sessionID,
            audio_pcm16le: audioPCM.base64EncodedString(),
            sample_rate: sampleRate,
            language_hint: languageHint,
            chunk_index: chunkIndex
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/transcribe"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TranscribeResponse.self, from: data)
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
            let session_id: String
            let mode: String
            let input_text: String
            let tone_style: String
            let provider_mode: String
            let consent_token: String?
            let allow_raw: Bool
        }

        let payload = Payload(
            session_id: sessionID,
            mode: mode.rawValue,
            input_text: inputText,
            tone_style: toneStyle.rawValue,
            provider_mode: providerMode.rawValue,
            consent_token: consentToken,
            allow_raw: allowRaw
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/cleanup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(CleanupResponse.self, from: data)
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
            let session_id: String
            let source_text: String
            let source_language: String
            let target_language: String
            let provider_mode: String
            let consent_token: String?
            let allow_raw: Bool
        }

        let payload = Payload(
            session_id: sessionID,
            source_text: sourceText,
            source_language: sourceLanguage,
            target_language: targetLanguage,
            provider_mode: providerMode.rawValue,
            consent_token: consentToken,
            allow_raw: allowRaw
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/translate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(TranslateResponse.self, from: data)
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
            let session_id: String
            let transcript: String
            let tone_style: String
            let provider_mode: String
            let consent_token: String?
            let allow_raw: Bool
        }

        let payload = Payload(
            session_id: sessionID,
            transcript: transcript,
            tone_style: toneStyle.rawValue,
            provider_mode: providerMode.rawValue,
            consent_token: consentToken,
            allow_raw: allowRaw
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/meeting_summarize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(MeetingSummaryResponse.self, from: data)
    }

    static func framePrompt(
        sessionID: String,
        text: String,
        consentToken: String? = nil
    ) async throws -> PromptFrameResponse {
        struct Payload: Codable {
            let session_id: String
            let text: String
            let consent_token: String?
        }

        let payload = Payload(
            session_id: sessionID,
            text: text,
            consent_token: consentToken
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/prompt/frame"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(PromptFrameResponse.self, from: data)
    }

    static func privacyPreview(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String
    ) async throws -> PrivacyPreviewResponse {
        struct Payload: Codable {
            let session_id: String
            let operation: String
            let input_text: String
        }

        let payload = Payload(
            session_id: sessionID,
            operation: operation.rawValue,
            input_text: inputText
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/privacy/preview"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        return try decoder.decode(PrivacyPreviewResponse.self, from: data)
    }
}
