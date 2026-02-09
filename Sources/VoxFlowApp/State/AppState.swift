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
    @Published var showSettingsWindow = false
    @Published var targetingMode: TargetingMode = .cursorAware
    @Published var focusTarget: FocusTargetSnapshot = .unavailable
    @Published var onboardingPhase: OnboardingPhase = .notStarted
    @Published var calibrationItems: [CalibrationItem] = []
    @Published var activeCalibrationIndex: Int = 0
    @Published var workflowMode: WorkflowMode = .dictation
    @Published var toneStyle: ToneStyle = .neutral
    @Published var insertBehavior: InsertBehavior = .alwaysReview
    @Published var appToneOverrides: [String: ToneStyle] = [:]
    @Published var recentDictations: [TranscriptCandidate] = []
    @Published var translationCandidate: TranslationCandidate?
    @Published var meetingCandidate: MeetingCandidate?
    @Published var translationModeEnabled = false
    @Published var translationProfile: TranslationProfile = .translateGemma4B
    @Published var sttBackend: STTBackend = .voxtral
    @Published var localVoxtralModel: String = "mistralai/Voxtral-Mini-3B-2507"
    @Published var localWhisperModel: String = "openai/whisper-small"
    @Published var voxtralSafeModeEnabled = true
    @Published var providerMode: ProviderMode = .localOnly
    @Published var privateAPIBaseURL: String = ""
    @Published var privateAPIModel: String = ""
    @Published var privateAPIKey: String = ""
    @Published var openAIBaseURL: String = "https://api.openai.com"
    @Published var openAIAPIKey: String = ""
    @Published var openAISTTModel: String = "whisper-1"
    @Published var openAITTSModel: String = "gpt-4o-mini-tts"
    @Published var openAITTSVoice: String = "alloy"
    @Published var hostMemoryGB: Int = max(1, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    @Published var isBenchmarkRunning = false
    @Published var benchmarkStatusLine: String?
    @Published var translationBenchmarkResults: [TranslationBenchmarkResult] = []
    @Published var isCommandLaneActive = false
    @Published var lastInsertedText: String?
    @Published var privacyPreview: PrivacyPreview?
    @Published var launchedAt: Date = Date()
    @Published var captureCount = 0
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
        privacyPreview = nil
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
    }
}
