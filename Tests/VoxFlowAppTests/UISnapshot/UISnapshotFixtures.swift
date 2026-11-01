import Foundation
@testable import VoxFlowApp

// Fixtures for the offscreen UI snapshots. Everything here is invented: the
// repository is public, so no rendered text may come from real dictation,
// vocabulary, skill profiles, Notion pages, paths or keys. Stores live on
// temp files, and the fakes return fixed values; nothing touches the
// microphone, the Accessibility API, the pasteboard or the Keychain.

/// Capture fake: never opens a device and always returns 1 s of silence.
final class SnapshotFakeCapture: AudioCapturing {
    func startCapture(onCaptureLive: (@Sendable () -> Void)?) throws {}
    func stopCapture() throws -> CapturedAudio {
        CapturedAudio(pcm: Data(count: 32_000), sampleRate: 16_000)
    }
    func tailRMSEnergy(seconds: Double) -> Double? { nil }
    func takeInvalidatedAudio() -> CapturedAudio? { nil }
}

/// Transcriber fake: returns one fixed invented sentence.
final class SnapshotFakeTranscriber: ChunkTranscribing {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        TranscribeResponse(
            text: "Draft the quarterly update for the design team.", isFinal: true, latencyMs: 1,
            confidenceEstimate: 0.92, processingTimeMs: 1, stageTimingsMs: nil,
            modelLoadedBeforeRequest: nil, modelLoadedAfterRequest: nil, coldStart: nil)
    }
}

/// Smart-action fake: echoes the transcript unchanged.
struct SnapshotFakeSmartActionBackend: SmartActionBackend {
    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        SmartActionResult(actionId: action, output: transcript, guardrailTriggered: false, error: nil)
    }
}

/// Everything `CockpitWindowView` needs, built on temp files and fakes.
@MainActor
struct CockpitFixture {
    let state: AppState
    let coordinator: CockpitCoordinator
    let session: LongFormSessionService
    let capture: CockpitCaptureCoordinator
    let dictionary: DictionaryStore
    let chains: ChainStore
}

/// The stores a Settings render needs, on temp files with invented entries.
@MainActor
struct SettingsStoreFixture {
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let chains: ChainStore
    let providers: ProviderConfigStore
}

@MainActor
enum UISnapshotFixtures {
    private static var tempDirectories: [URL] = []

    /// A fresh, empty directory under the system temp folder.
    static func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-ui-snapshots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempDirectories.append(url)
        return url
    }

    /// Removes every directory `makeTempDirectory()` created.
    static func removeTempDirectories() {
        tempDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        tempDirectories = []
    }

    /// An `AppState` with a healthy, deterministic baseline, then `configure`.
    static func state(_ configure: (AppState) -> Void = { _ in }) -> AppState {
        let state = AppState()
        state.hostMemoryGB = 16
        state.focusTarget = FocusTargetSnapshot(
            hasFocusedTextInput: true, hasInsertionCursor: true, appName: "Notes",
            bundleID: "com.apple.Notes", role: "AXTextArea", processIdentifier: nil)
        state.backendReadiness = BackendReadinessState(
            readyForDictation: true, processRunning: true, whisperKitReady: true,
            statusSummary: "Backend ready", activeSTTModel: "whisper-small",
            ollamaAvailable: true, activePolishProvider: "ollama", activePolishModel: "gemma4:e2b-mlx")
        state.captureCount = 42
        state.totalCaptureCount = 42
        state.localCaptureCount = 42
        state.successfulInsertCount = 38
        state.fallbackInsertCount = 3
        state.failedInsertCount = 1
        state.totalTranscriptionLatencyMs = 42 * 640
        state.lastTranscriptionLatencyMs = 590
        state.insertStatsByApp = [
            "Notes": AppInsertStats(appName: "Notes", successCount: 24, fallbackCount: 1, failedCount: 0),
            "Mail": AppInsertStats(appName: "Mail", successCount: 14, fallbackCount: 2, failedCount: 1),
        ]
        configure(state)
        return state
    }

    /// A receipt candidate for the palette's Recent panel.
    static func candidate(_ text: String, minutesAgo: Double) -> TranscriptCandidate {
        TranscriptCandidate(
            rawText: text, lightText: text, polishText: text, selectedMode: .light,
            confidence: 0.92, timestamp: Date().addingTimeInterval(-minutesAgo * 60))
    }

    /// An `InsertionReceiptStore` over a temp `insertions.jsonl` holding
    /// `lines`, refreshed once.
    static func receiptStore(lines: [String]) -> InsertionReceiptStore {
        let file = makeTempDirectory().appendingPathComponent("insertions.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let store = InsertionReceiptStore(fileURL: file)
        store.refresh()
        return store
    }

    /// Invented receipts, oldest first as in the real log: two inserts, a
    /// silence reject, then the newest insert.
    static func sampleReceiptLines(now: Date = Date()) -> [String] {
        func stamp(_ minutesAgo: Double) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        }
        return [
            #"{"event":"insert","ts":"\#(stamp(42))","text":"Add the accessibility review to Thursday's agenda.","source":"Inserted (light · rules — app)","target":"Notes","confidence":0.94,"audio_seconds":3.1}"#,
            #"{"event":"reject","ts":"\#(stamp(31))","reason":"silence","source":"Rejected (silence)","audio_seconds":1.2,"rms":0.002}"#,
            #"{"event":"insert","ts":"\#(stamp(18))","text":"Remind the team that the onboarding flow ships next sprint.","source":"Inserted (polish · gemma4:e2b-mlx — app)","target":"Mail","confidence":0.91,"audio_seconds":4.6}"#,
            #"{"event":"insert","ts":"\#(stamp(4))","text":"Draft the quarterly update for the design team.","source":"Inserted (light · rules — app)","target":"Notes","confidence":0.93,"audio_seconds":2.8}"#,
        ]
    }

    /// Settings stores on temp files: invented vocabulary and one invented
    /// snippet; chains keep the shipped seed chains.
    static func settingsStores() -> SettingsStoreFixture {
        let dir = makeTempDirectory()
        let dictionary = DictionaryStore(fileURL: dir.appendingPathComponent("dictionary.json"), seedOnFirstRun: false)
        dictionary.add(wrong: "quarter ly", right: "quarterly", context: nil)
        dictionary.add(wrong: "on boarding", right: "onboarding", context: nil)
        dictionary.add(wrong: "a eleven y", right: "a11y", context: nil)
        let snippets = SnippetStore(fileURL: dir.appendingPathComponent("snippets.json"))
        snippets.add(keyword: "thanks", text: "Thanks for the update, much appreciated.", scope: .global)
        let chains = ChainStore(fileURL: dir.appendingPathComponent("chains.json"))
        let providers = ProviderConfigStore(fileURL: dir.appendingPathComponent("providers.json"))
        return SettingsStoreFixture(dictionary: dictionary, snippets: snippets, chains: chains, providers: providers)
    }

    /// A cockpit on temp files and fakes. With `transcript` nil the session
    /// stays idle (the empty cockpit); otherwise it is driven through
    /// start, setTranscript and stop into the reviewing state.
    static func cockpit(state: AppState, transcript: String?) -> CockpitFixture {
        let dir = makeTempDirectory()
        let session = LongFormSessionService(autoSaveDirectory: dir.appendingPathComponent("sessions", isDirectory: true))
        let actions = SmartActionService(backend: SnapshotFakeSmartActionBackend())
        let coordinator = CockpitCoordinator(state: state, sessionService: session, actionService: actions)
        let dictionary = DictionaryStore(fileURL: dir.appendingPathComponent("dictionary.json"), seedOnFirstRun: false)
        dictionary.add(wrong: "quarter ly", right: "quarterly", context: nil)
        let chains = ChainStore(fileURL: dir.appendingPathComponent("chains.json"))
        let capture = CockpitCaptureCoordinator(
            capture: SnapshotFakeCapture(), transcriber: SnapshotFakeTranscriber(),
            session: session, dictionary: dictionary)
        if let transcript {
            session.start(targetApp: state.focusTarget)
            session.setTranscript(transcript)
            session.stop()
        }
        return CockpitFixture(
            state: state, coordinator: coordinator, session: session,
            capture: capture, dictionary: dictionary, chains: chains)
    }
}
