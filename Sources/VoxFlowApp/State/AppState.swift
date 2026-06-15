import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessionState: SessionState = .idle
    @Published var selectedMode: CleanupMode = .raw
    @Published var transcriptCandidate: TranscriptCandidate?
    @Published var statusLine: String = "Hold hotkey to talk"
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var lastInsertResult: InsertResult?
    @Published var targetingMode: TargetingMode = .anyApp
    @Published var focusTarget: FocusTargetSnapshot = .unavailable
    @Published var onboardingPhase: OnboardingPhase = .notStarted
    @Published var calibrationItems: [CalibrationItem] = []
    @Published var activeCalibrationIndex: Int = 0
    @Published var workflowMode: WorkflowMode = .dictation
    @Published var dictationCoreModeEnabled = true
    @Published var toneStyle: ToneStyle = .neutral
    @Published var insertBehavior: InsertBehavior = .autoInsertLight
    @Published var appProfiles: [String: AppProfile] = [:]
    @Published var recentDictations: [TranscriptCandidate] = []
    @Published var translationCandidate: TranslationCandidate?
    @Published var meetingCandidate: MeetingCandidate?
    @Published var translationModeEnabled = false
    @Published var meetingModeEnabled = false
    @Published var promptModeEnabled = false
    @Published var promptCandidate: PromptCandidate?
    @Published var lastPipelineTrace: CapturePipelineTrace?
    @Published var translationProfile: TranslationProfile = .translateGemma4B
    @Published var dictationHotkeyPreset: DictationHotkeyPreset = .fnOnly
    @Published var commandLaneHotkeyPreset: CommandLaneHotkeyPreset = .fnCommandSpace
    @Published var sttBackend: STTBackend = .whisperKit
    @Published var localWhisperModel: String = "openai/whisper-small"
    @Published var providerMode: ProviderMode = .localOnly
    @Published var privateAPIBaseURL: String = ""
    @Published var privateAPIModel: String = ""
    /// Non-secret indicator for UI config warnings. The key itself lives in
    /// the Keychain only — holding it in @Published state kept a plaintext
    /// copy in memory and broadcast it via Combine (audit S10).
    @Published var privateAPIKeyConfigured: Bool = false
    /// R5.6: voice-triggered protocols (experimental, off by default).
    @Published var protocolCommandsEnabled: Bool = false
    /// R5.4: assistant handoff (experimental, off by default).
    @Published var assistantHandoffEnabled: Bool = false
    @Published var assistantHandoffCommand: String = ""
    /// Pending handoff payload awaiting explicit user approval (preview card).
    @Published var handoffPreview: String?
    /// Last handoff response, shown for review/copy/append.
    @Published var handoffResult: String?
    @Published var handoffInFlight: Bool = false
    @Published var openAIBaseURL: String = "https://api.openai.com"
    @Published var openAISTTModel: String = "whisper-1"
    @Published var hostMemoryGB: Int = max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    @Published var isBenchmarkRunning = false
    @Published var benchmarkStatusLine: String?
    @Published var translationBenchmarkResults: [TranslationBenchmarkResult] = []
    @Published var isCommandLaneActive = false
    @Published var lastInsertedText: String?
    @Published var privacyPreview: PrivacyPreview?
    @Published var launchedAt: Date = Date()
    @Published var captureCount = 0
    @Published var backendReadiness = BackendReadinessState()
    @Published var ollamaNudgeDismissed: Bool = UserDefaults.standard.bool(forKey: "VoxFlow.ollamaNudgeDismissed")

    // MARK: - Cockpit Layer 0
    @Published var cockpitVisible: Bool = false
    @Published var cockpitSession: LongFormSession?
    /// Visible chip order; defaults to the three Layer-0-shipping actions.
    /// MRU + promotion logic in CockpitCoordinator mutates this after 30+
    /// total invocations or when an unpromoted action hits the threshold.
    /// Persisted across launches via UserDefaults — chip promotions the
    /// user earned should survive quit + reopen.
    @Published var chipMRU: [SmartActionId] = AppState.loadChipMRU()
    @Published var chipInvocationCounts: [SmartActionId: Int] = AppState.loadChipInvocationCounts()
    @Published var totalCaptureCount: Int = UserDefaults.standard.integer(forKey: "VoxFlow.totalCaptureCount")
    @Published var voicePromptStripDismissed: Bool = UserDefaults.standard.bool(forKey: "VoxFlow.voicePromptStripDismissed")
    @Published var localCaptureCount = 0
    @Published var privateAPICaptureCount = 0
    @Published var totalTranscriptionLatencyMs = 0
    @Published var lastTranscriptionLatencyMs: Int?
    @Published var successfulInsertCount = 0
    @Published var fallbackInsertCount = 0
    @Published var failedInsertCount = 0
    @Published var approvedTranslationCount = 0
    @Published var approvedMeetingCount = 0
    @Published var privacyApproveRawCount = 0
    @Published var privacyApproveRedactedCount = 0
    @Published var insertStatsByApp: [String: AppInsertStats] = [:]
    @Published var workflowCaptureCounts: [WorkflowMode: Int] = [:]
    @Published var benchmarkHistoryByProfile: [TranslationProfile: TranslationBenchmarkHistoryStats] = [:]

    var displayText: String {
        if workflowMode == .translateEnToDe {
            return translationCandidate?.targetGerman ?? ""
        }
        if workflowMode == .meeting {
            return meetingCandidate?.formattedNotes ?? ""
        }
        if workflowMode == .prompt {
            return promptCandidate?.framedPrompt ?? ""
        }
        guard let transcriptCandidate else {
            return ""
        }
        return transcriptCandidate.text(for: selectedMode)
    }

    var currentCalibrationPhrase: String? {
        guard onboardingPhase == .calibrating, calibrationItems.indices.contains(activeCalibrationIndex) else {
            return nil
        }
        return calibrationItems[activeCalibrationIndex].expectedPhrase
    }

    var canStartCaptureForDictation: Bool {
        switch targetingMode {
        case .anyApp:
            return true
        case .textFieldOnly:
            return focusTarget.hasFocusedTextInput
        case .cursorAware:
            return focusTarget.hasInsertionCursor || focusTarget.hasFocusedTextInput
        }
    }

    var requiresTranslationApproval: Bool {
        workflowMode == .translateEnToDe
    }

    var requiresMeetingApproval: Bool {
        workflowMode == .meeting
    }

    var availableWorkflowModes: [WorkflowMode] {
        var modes: [WorkflowMode] = [.dictation]
        if translationModeEnabled {
            modes.append(.translateEnToDe)
        }
        if meetingModeEnabled {
            modes.append(.meeting)
        }
        if promptModeEnabled {
            modes.append(.prompt)
        }
        return modes
    }

    var canUseSelectedSTTBackend: Bool {
        backendReadiness.readyForDictation || (sttBackend == .whisperKit && backendReadiness.whisperKitReady)
    }

    var workflowNeedsBackend: Bool {
        if providerMode == .privateAPI {
            return true
        }
        if sttBackend != .whisperKit {
            return true
        }

        switch workflowMode {
        case .translateEnToDe, .meeting:
            return true
        case .dictation, .prompt:
            return false
        }
    }

    var effectiveInsertBehaviorForCurrentFocus: InsertBehavior {
        let bundleID = focusTarget.bundleID ?? ""
        return appProfiles[bundleID]?.insertBehavior
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]?.insertBehavior
            ?? insertBehavior
    }

    var localDictationWantsBackendCleanup: Bool {
        providerMode == .localOnly
            && sttBackend == .whisperKit
            && workflowMode == .dictation
            && effectiveInsertBehaviorForCurrentFocus != .autoInsertRaw
    }

    var backendShouldRun: Bool {
        // An open cockpit needs the backend for smart actions even when the
        // active workflow runs fully in-app (WhisperKit dictation/prompt).
        isBenchmarkRunning || workflowNeedsBackend || cockpitVisible || localDictationWantsBackendCleanup
    }

    var backendStatusColorName: String {
        if !backendShouldRun && !backendReadiness.processRunning && !backendReadiness.warmupInProgress {
            return "secondary"
        }
        if backendReadiness.readyForDictation {
            return "green"
        }
        if backendReadiness.warmupInProgress {
            return "orange"
        }
        return "red"
    }

    var averageTranscriptionLatencyMs: Int {
        guard captureCount > 0 else { return 0 }
        return totalTranscriptionLatencyMs / captureCount
    }

    var insertSuccessRate: Double {
        let attempts = successfulInsertCount + failedInsertCount
        guard attempts > 0 else { return 0 }
        return Double(successfulInsertCount) / Double(attempts)
    }

    var sessionDuration: TimeInterval {
        Date().timeIntervalSince(launchedAt)
    }

    var appInsertStatsSummary: [AppInsertStats] {
        insertStatsByApp
            .values
            .sorted {
                if $0.totalAttempts == $1.totalAttempts {
                    return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                }
                return $0.totalAttempts > $1.totalAttempts
            }
    }

    var workflowUsageSummary: [WorkflowUsageMetric] {
        WorkflowMode.allCases
            .map { mode in
                WorkflowUsageMetric(mode: mode, captures: workflowCaptureCounts[mode, default: 0])
            }
            .sorted {
                if $0.captures == $1.captures {
                    return $0.mode.displayName < $1.mode.displayName
                }
                return $0.captures > $1.captures
            }
    }

    var recommendedProfileFromHistory: TranslationBenchmarkHistoryStats? {
        benchmarkHistoryByProfile
            .values
            .filter { $0.successfulRuns > 0 }
            .sorted {
                if $0.recommendationScore == $1.recommendationScore {
                    if $0.averageMedianLatencyMs == $1.averageMedianLatencyMs {
                        return $0.profile.displayName < $1.profile.displayName
                    }
                    return $0.averageMedianLatencyMs < $1.averageMedianLatencyMs
                }
                return $0.recommendationScore < $1.recommendationScore
            }
            .first
    }

    func resetForNewCapture() {
        sessionState = .recording
        statusLine = "Listening... release hotkey to transcribe"
        errorMessage = nil
        lastInsertResult = nil
        transcriptCandidate = nil
        translationCandidate = nil
        meetingCandidate = nil
        promptCandidate = nil
        privacyPreview = nil
        lastPipelineTrace = nil
    }

    func setIdle() {
        sessionState = .idle
        statusLine = "Hold hotkey to talk"
        recordingDuration = 0
    }

    func resetDashboardMetrics() {
        launchedAt = Date()
        captureCount = 0
        localCaptureCount = 0
        privateAPICaptureCount = 0
        totalTranscriptionLatencyMs = 0
        lastTranscriptionLatencyMs = nil
        successfulInsertCount = 0
        fallbackInsertCount = 0
        failedInsertCount = 0
        approvedTranslationCount = 0
        approvedMeetingCount = 0
        privacyApproveRawCount = 0
        privacyApproveRedactedCount = 0
        insertStatsByApp = [:]
        workflowCaptureCounts = [:]
        benchmarkHistoryByProfile = [:]
        lastPipelineTrace = nil
    }

    // MARK: - Cockpit MRU persistence (UserDefaults)

    static let chipMRUKey = "VoxFlow.cockpit.chipMRU"
    static let chipInvocationCountsKey = "VoxFlow.cockpit.chipInvocationCounts"
    private static let defaultChipMRU: [SmartActionId] = [.memo, .mece, .items]

    static func loadChipMRU() -> [SmartActionId] {
        guard let raw = UserDefaults.standard.array(forKey: chipMRUKey) as? [String] else {
            return defaultChipMRU
        }
        let parsed = raw.compactMap(SmartActionId.init(rawValue:))
        return parsed.isEmpty ? defaultChipMRU : parsed
    }

    static func loadChipInvocationCounts() -> [SmartActionId: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: chipInvocationCountsKey) as? [String: Int] else {
            return [:]
        }
        var result: [SmartActionId: Int] = [:]
        for (key, value) in raw {
            if let id = SmartActionId(rawValue: key) {
                result[id] = value
            }
        }
        return result
    }

    func persistChipMRU() {
        UserDefaults.standard.set(chipMRU.map(\.rawValue), forKey: Self.chipMRUKey)
    }

    func persistChipInvocationCounts() {
        let dict = Dictionary(uniqueKeysWithValues: chipInvocationCounts.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(dict, forKey: Self.chipInvocationCountsKey)
    }
}
