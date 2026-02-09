import AppKit
import Foundation
import os.log

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()
    private let log = Logger(subsystem: "local.voxflow.app", category: "AppCoordinator")

    @Published var state = AppState()

    private let backendManager = BackendProcessManager()
    private let audioCapture = AudioCaptureService()
    private let hotkeyService = GlobalHotkeyService()
    private let commandHotkeyService = GlobalHotkeyService()
    private let permissionService = PermissionService()
    private let insertService = AccessibilityInsertService()
    private let sessionMemory = SessionMemoryStore(capacity: 20)
    private lazy var focusMonitor = FocusContextMonitor(insertService: insertService)

    private var timer: Timer?
    private var sessionCounter: Int = 0
    private var pendingPrivacyOperation: PendingPrivacyOperation?

    private let onboardingKey = "voxflow.onboarding.complete"
    private let translationProfileKey = "voxflow.translation.profile"
    private let translationModeEnabledKey = "voxflow.translation.modeEnabled"
    private let sttBackendKey = "voxflow.stt.backend"
    private let sttModelKey = "voxflow.stt.model"
    private let whisperModelKey = "voxflow.whisper.model"
    private let voxtralSafeModeKey = "voxflow.voxtral.safeMode"
    private let providerModeKey = "voxflow.provider.mode"
    private let privateAPIBaseURLKey = "voxflow.privateapi.baseURL"
    private let privateAPIModelKey = "voxflow.privateapi.model"
    private let privateAPIKeyKey = "voxflow.privateapi.key"
    private let openAIBaseURLKey = "voxflow.openai.baseURL"
    private let openAIAPIKeyKey = "voxflow.openai.apiKey"
    private let openAISTTModelKey = "voxflow.openai.sttModel"
    private let openAITTSModelKey = "voxflow.openai.ttsModel"
    private let openAITTSVoiceKey = "voxflow.openai.ttsVoice"

    private static let keychainPrivateAPIKeyAccount = "voxflow.privateapi.key"
    private static let keychainOpenAIAPIKeyAccount = "voxflow.openai.apiKey"

    private init() {
        migrateAPIKeysToKeychain()
        configureInitialState()
        backendManager.startIfNeeded(configuration: currentBackendLaunchConfiguration())
        configureHotkeys()
        startFocusMonitoring()
        Task { await warmup() }
    }

    private func migrateAPIKeysToKeychain() {
        let defaults = UserDefaults.standard
        if let existingPrivateKey = defaults.string(forKey: privateAPIKeyKey), !existingPrivateKey.isEmpty {
            KeychainService.save(account: Self.keychainPrivateAPIKeyAccount, value: existingPrivateKey)
            defaults.removeObject(forKey: privateAPIKeyKey)
        }
        if let existingOpenAIKey = defaults.string(forKey: openAIAPIKeyKey), !existingOpenAIKey.isEmpty {
            KeychainService.save(account: Self.keychainOpenAIAPIKeyAccount, value: existingOpenAIKey)
            defaults.removeObject(forKey: openAIAPIKeyKey)
        }
    }

    func warmup() async {
        do {
            _ = try await BackendAPIClient.health()
        } catch {
            state.statusLine = "Backend offline. Start backend in Settings."
        }
    }

    func configureHotkeys() {
        do {
            try hotkeyService.register(configuration: .default, onPress: { [weak self] in
                Task { @MainActor in self?.startCapture() }
            }, onRelease: { [weak self] in
                Task { @MainActor in await self?.finishCaptureAndTranscribe() }
            })

            try commandHotkeyService.register(configuration: .commandLane, onPress: { [weak self] in
                Task { @MainActor in self?.startCapture(commandLane: true) }
            }, onRelease: { [weak self] in
                Task { @MainActor in await self?.finishCaptureAndTranscribe(commandLane: true) }
            })
        } catch {
            log.error("Failed to register hotkey: \(error.localizedDescription)")
            state.errorMessage = "Failed to register hotkey. Check accessibility permissions."
        }
    }

    func startCapture(commandLane: Bool = false) {
        guard state.sessionState == .idle || state.sessionState == .review || state.sessionState == .error || state.sessionState == .onboarding else {
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !state.canStartCaptureForDictation {
            state.statusLine = "Focus a text field or place cursor before dictating"
            return
        }

        state.resetForNewCapture()
        sessionCounter += 1
        state.isCommandLaneActive = commandLane
        pendingPrivacyOperation = nil

        do {
            try audioCapture.startCapture()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.state.recordingDuration += 0.1
                }
            }
        } catch {
            state.sessionState = .error
            state.errorMessage = "Microphone access failed: \(error.localizedDescription)"
            state.isCommandLaneActive = false
        }
    }

    func finishCaptureAndTranscribe(commandLane: Bool = false) async {
        guard state.sessionState == .recording else { return }
        defer { state.isCommandLaneActive = false }

        timer?.invalidate()
        state.sessionState = .transcribing
        state.statusLine = commandLane ? "Interpreting command..." : "Transcribing..."

        do {
            let capturedAudio = try audioCapture.stopCapture()
            let sessionID = "session-\(sessionCounter)"
            let transcription = try await BackendAPIClient.transcribe(
                sessionID: sessionID,
                audioPCM: capturedAudio.pcm,
                sampleRate: Int(capturedAudio.sampleRate),
                chunkIndex: 0,
                languageHint: "en"
            )
            let isCalibrationCapture = state.onboardingPhase == .calibrating
            recordCaptureMetrics(
                latencyMs: transcription.latencyMs,
                commandLane: commandLane,
                onboardingCalibration: isCalibrationCapture
            )

            let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if state.onboardingPhase == .calibrating {
                handleCalibrationResult(rawText: rawText)
                return
            }

            if commandLane {
                executeCommandLane(rawText: rawText)
                return
            }

            switch state.workflowMode {
            case .translateEnToDe:
                try await processTranslation(sessionID: sessionID, rawText: rawText)
            case .meeting:
                try await processMeeting(sessionID: sessionID, rawText: rawText)
            case .dictation:
                try await processDictation(sessionID: sessionID, rawText: rawText)
            }
        } catch {
            log.error("Transcription failed: \(error.localizedDescription)")
            state.sessionState = .error
            state.errorMessage = "Transcription failed: \(error.localizedDescription)"
            state.statusLine = "Error. Retry capture."
        }
    }

    func retryLastCapture() {
        state.transcriptCandidate = nil
        state.translationCandidate = nil
        state.meetingCandidate = nil
        state.privacyPreview = nil
        pendingPrivacyOperation = nil
        state.isCommandLaneActive = false
        state.setIdle()
    }

    func copyCurrentText() {
        guard !state.displayText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.displayText, forType: .string)
        state.statusLine = "Copied to clipboard"
    }

    func copyMeetingMarkdownTemplate() {
        guard let meeting = state.meetingCandidate else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdownTemplate, forType: .string)
        state.statusLine = "Meeting Markdown template copied"
    }

    func copyMeetingNotionTemplate() {
        guard let meeting = state.meetingCandidate else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.notionTemplate, forType: .string)
        state.statusLine = "Meeting Notion template copied"
    }

    func insertCurrentText() {
        guard !state.displayText.isEmpty else { return }

        if state.privacyPreview != nil {
            state.statusLine = "Approve privacy review before inserting"
            return
        }

        if state.requiresTranslationApproval && state.translationCandidate?.approved != true {
            state.statusLine = "Approve translation before inserting"
            return
        }

        if state.requiresMeetingApproval && state.meetingCandidate?.approved != true {
            state.statusLine = "Approve meeting notes before inserting"
            return
        }

        state.sessionState = .inserting
        let appName = state.focusTarget.appName ?? "Unknown App"
        let result = insertService.insert(text: state.displayText)
        state.lastInsertResult = result
        recordInsertStats(forApp: appName, result: result)

        if result.success {
            state.successfulInsertCount += 1
            if result.fallbackUsed {
                state.fallbackInsertCount += 1
            }
            state.statusLine = "Inserted"
            state.lastInsertedText = state.displayText
            state.sessionState = .idle
        } else {
            state.failedInsertCount += 1
            state.statusLine = "Insert failed. Copied to clipboard."
            copyCurrentText()
            state.sessionState = .review
        }
    }

    func approveTranslation() {
        guard var translation = state.translationCandidate else { return }
        guard !translation.approved else { return }
        translation.approved = true
        state.translationCandidate = translation
        state.approvedTranslationCount += 1
        state.statusLine = "Translation approved"
    }

    func approveMeetingNotes() {
        guard var meeting = state.meetingCandidate else { return }
        guard !meeting.approved else { return }
        meeting.approved = true
        state.meetingCandidate = meeting
        state.approvedMeetingCount += 1
        state.statusLine = "Meeting notes approved"
    }

    func approvePrivacyPreview(sendRaw: Bool) {
        guard let preview = state.privacyPreview,
              let pendingPrivacyOperation else {
            return
        }

        state.statusLine = sendRaw ? "Sending approved raw text to private API..." : "Sending redacted text to private API..."

        Task { @MainActor in
            do {
                try await continuePendingPrivacyOperation(
                    pendingPrivacyOperation,
                    consentToken: preview.token,
                    allowRaw: sendRaw
                )
                if sendRaw {
                    state.privacyApproveRawCount += 1
                } else {
                    state.privacyApproveRedactedCount += 1
                }
                state.privacyPreview = nil
                self.pendingPrivacyOperation = nil
            } catch {
                state.errorMessage = "Private API processing failed: \(error.localizedDescription)"
                state.sessionState = .error
                state.privacyPreview = nil
                self.pendingPrivacyOperation = nil
            }
        }
    }

    func cancelPrivacyPreview() {
        state.privacyPreview = nil
        pendingPrivacyOperation = nil
        state.statusLine = "Private API request cancelled"
        state.sessionState = .review
    }

    func selectCleanupMode(_ mode: CleanupMode) {
        state.selectedMode = mode
        if state.sessionState == .review {
            state.statusLine = "\(mode.displayName) mode selected"
        }
    }

    func selectToneStyle(_ tone: ToneStyle) {
        state.toneStyle = tone
        guard state.workflowMode == .dictation,
              let rawText = state.transcriptCandidate?.rawText,
              state.sessionState == .review else {
            return
        }

        Task { @MainActor in
            do {
                let lightText = try await BackendAPIClient.cleanup(
                    sessionID: "retone-\(sessionCounter)",
                    mode: .light,
                    inputText: rawText,
                    toneStyle: tone,
                    providerMode: .localOnly
                ).outputText

                let polishText = try await BackendAPIClient.cleanup(
                    sessionID: "retone-\(sessionCounter)",
                    mode: .polish,
                    inputText: rawText,
                    toneStyle: tone,
                    providerMode: .localOnly
                ).outputText

                state.transcriptCandidate = TranscriptCandidate(
                    rawText: rawText,
                    lightText: lightText,
                    polishText: polishText,
                    selectedMode: state.selectedMode
                )
                state.statusLine = "Tone: \(tone.displayName)"
            } catch {
                state.errorMessage = "Unable to apply tone: \(error.localizedDescription)"
            }
        }
    }

    func selectWorkflowMode(_ mode: WorkflowMode) {
        if mode == .translateEnToDe && !state.translationModeEnabled {
            state.statusLine = "Enable Experimental Translate Mode in Settings"
            return
        }

        state.workflowMode = mode
        state.transcriptCandidate = nil
        state.translationCandidate = nil
        state.meetingCandidate = nil
        state.privacyPreview = nil
        pendingPrivacyOperation = nil

        switch mode {
        case .dictation:
            state.statusLine = "Dictation mode active"
        case .translateEnToDe:
            state.statusLine = "Translate mode active (EN→DE)"
        case .meeting:
            state.statusLine = "Meeting mode active"
        }
    }

    func setTranslationModeEnabled(_ isEnabled: Bool) {
        state.translationModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: translationModeEnabledKey)

        if !isEnabled, state.workflowMode == .translateEnToDe {
            state.workflowMode = .dictation
        }

        state.statusLine = isEnabled
            ? "Translate mode enabled"
            : "Translate mode disabled"
    }

    func selectTranslationProfile(_ profile: TranslationProfile) {
        guard state.translationProfile != profile else { return }

        state.translationProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: translationProfileKey)

        restartBackendWithCurrentConfiguration(status: "Translate model: \(profile.displayName)")
    }

    func selectSTTBackend(_ backend: STTBackend) {
        guard state.sttBackend != backend else { return }
        state.sttBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: sttBackendKey)

        restartBackendWithCurrentConfiguration(status: "STT backend: \(backend.displayName)")
    }

    func updateLocalSpeechModels(voxtralModel: String, whisperModel: String) {
        let trimmedVoxtral = voxtralModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWhisper = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)

        state.localVoxtralModel = trimmedVoxtral.isEmpty ? "mistralai/Voxtral-Mini-3B-2507" : trimmedVoxtral
        state.localWhisperModel = trimmedWhisper.isEmpty ? "openai/whisper-small" : trimmedWhisper

        UserDefaults.standard.set(state.localVoxtralModel, forKey: sttModelKey)
        UserDefaults.standard.set(state.localWhisperModel, forKey: whisperModelKey)

        restartBackendWithCurrentConfiguration(status: "Local speech models updated")
    }

    func setVoxtralSafeModeEnabled(_ isEnabled: Bool) {
        guard state.voxtralSafeModeEnabled != isEnabled else { return }

        state.voxtralSafeModeEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: voxtralSafeModeKey)

        let status = isEnabled
            ? "Voxtral safe mode enabled (fallback-first)"
            : "Pure Voxtral primary enabled (may fail under memory pressure)"
        restartBackendWithCurrentConfiguration(status: status)
    }

    func selectProviderMode(_ mode: ProviderMode) {
        guard state.providerMode != mode else { return }
        state.providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: providerModeKey)

        if mode == .localOnly {
            state.privacyPreview = nil
            pendingPrivacyOperation = nil
        }

        restartBackendWithCurrentConfiguration(status: "Provider: \(mode.displayName)")
    }

    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        state.privateAPIBaseURL = trimmedBaseURL
        state.privateAPIModel = trimmedModel
        state.privateAPIKey = trimmedKey

        UserDefaults.standard.set(trimmedBaseURL, forKey: privateAPIBaseURLKey)
        UserDefaults.standard.set(trimmedModel, forKey: privateAPIModelKey)
        KeychainService.save(account: Self.keychainPrivateAPIKeyAccount, value: trimmedKey)

        restartBackendWithCurrentConfiguration(status: "Private API configuration updated")
    }

    func updateOpenAIConfig(
        baseURL: String,
        apiKey: String,
        sttModel: String,
        ttsModel: String,
        ttsVoice: String
    ) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSTTModel = sttModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSVoice = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)

        state.openAIBaseURL = trimmedBaseURL.isEmpty ? "https://api.openai.com" : trimmedBaseURL
        state.openAIAPIKey = trimmedAPIKey
        state.openAISTTModel = trimmedSTTModel.isEmpty ? "whisper-1" : trimmedSTTModel
        state.openAITTSModel = trimmedTTSModel.isEmpty ? "gpt-4o-mini-tts" : trimmedTTSModel
        state.openAITTSVoice = trimmedTTSVoice.isEmpty ? "alloy" : trimmedTTSVoice

        UserDefaults.standard.set(state.openAIBaseURL, forKey: openAIBaseURLKey)
        KeychainService.save(account: Self.keychainOpenAIAPIKeyAccount, value: state.openAIAPIKey)
        UserDefaults.standard.set(state.openAISTTModel, forKey: openAISTTModelKey)
        UserDefaults.standard.set(state.openAITTSModel, forKey: openAITTSModelKey)
        UserDefaults.standard.set(state.openAITTSVoice, forKey: openAITTSVoiceKey)

        restartBackendWithCurrentConfiguration(status: "OpenAI speech configuration updated")
    }

    func runTranslationBenchmark() async {
        guard !state.isBenchmarkRunning else { return }

        state.isBenchmarkRunning = true
        state.translationBenchmarkResults = []
        state.benchmarkStatusLine = "Starting translation benchmark..."

        let originalProfile = state.translationProfile
        let samples = benchmarkSamples()
        var results: [TranslationBenchmarkResult] = []

        for (index, profile) in TranslationProfile.allCases.enumerated() {
            state.benchmarkStatusLine = "Benchmarking \(profile.displayName) (\(index + 1)/\(TranslationProfile.allCases.count))"
            backendManager.restart(configuration: backendLaunchConfiguration(for: profile))
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            var latenciesMs: [Double] = []
            var placeholderDetected = false

            for (sampleIndex, sampleText) in samples.enumerated() {
                let started = CFAbsoluteTimeGetCurrent()

                do {
                    let response = try await BackendAPIClient.translate(
                        sessionID: "bench-\(profile.rawValue)-\(sampleIndex)",
                        sourceText: sampleText,
                        sourceLanguage: "en",
                        targetLanguage: "de",
                        providerMode: .localOnly
                    )
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1_000
                    latenciesMs.append(elapsedMs)

                    if response.translatedText.contains("[translation unavailable") {
                        placeholderDetected = true
                    }
                } catch {
                    placeholderDetected = true
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            let median = percentile(latenciesMs, p: 0.5)
            let p95 = percentile(latenciesMs, p: 0.95)

            results.append(
                TranslationBenchmarkResult(
                    profile: profile,
                    medianLatencyMs: Int(median.rounded()),
                    p95LatencyMs: Int(p95.rounded()),
                    runs: latenciesMs.count,
                    placeholderDetected: placeholderDetected
                )
            )
        }

        state.translationProfile = originalProfile
        backendManager.restart(configuration: currentBackendLaunchConfiguration())
        Task { await warmup() }

        state.translationBenchmarkResults = results
        updateBenchmarkHistory(with: results)

        let viable = results.filter { !$0.placeholderDetected && $0.runs > 0 }
        if let fastest = viable.min(by: { $0.medianLatencyMs < $1.medianLatencyMs }) {
            if let recommended = state.recommendedProfileFromHistory {
                state.benchmarkStatusLine = "Benchmark complete. Fastest run: \(fastest.profile.displayName). History recommends \(recommended.profile.displayName)."
            } else {
                state.benchmarkStatusLine = "Benchmark complete. Fastest: \(fastest.profile.displayName) (\(fastest.medianLatencyMs) ms median)."
            }
        } else {
            state.benchmarkStatusLine = "Benchmark complete, but profiles returned placeholder output. Download models and retry."
        }

        state.isBenchmarkRunning = false
    }

    func applyFastestBenchmarkProfile() {
        guard !state.isBenchmarkRunning else { return }
        let viable = state.translationBenchmarkResults.filter { !$0.placeholderDetected && $0.runs > 0 }
        if let fastest = viable.min(by: { $0.medianLatencyMs < $1.medianLatencyMs }) {
            selectTranslationProfile(fastest.profile)
            return
        }
        if let recommended = state.recommendedProfileFromHistory {
            selectTranslationProfile(recommended.profile)
        }
    }

    func openSettings() {
        state.showSettingsWindow = true
    }

    func clearError() {
        state.errorMessage = nil
    }

    func permissionSnapshot() -> PermissionSnapshot {
        permissionService.snapshot()
    }

    func requestMicrophonePermission() {
        permissionService.requestMicrophonePermission()
    }

    func requestAccessibilityPermission() {
        permissionService.promptAccessibilityPermission()
    }

    func startBackend() {
        backendManager.startIfNeeded(configuration: currentBackendLaunchConfiguration())
    }

    func stopBackend() {
        backendManager.stop()
    }

    func restartOnboardingCalibration() {
        state.calibrationItems = defaultCalibrationItems()
        state.activeCalibrationIndex = 0
        state.onboardingPhase = .calibrating
        state.sessionState = .onboarding
        state.statusLine = "Calibration mode: hold hotkey, say phrase, release"
    }

    func completeOnboardingManually() {
        state.onboardingPhase = .complete
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state.setIdle()
    }

    func resetDashboardMetrics() {
        state.resetDashboardMetrics()
        state.statusLine = "Dashboard metrics reset"
    }

    private func configureInitialState() {
        let defaults = UserDefaults.standard

        if let profileRawValue = defaults.string(forKey: translationProfileKey),
           let profile = TranslationProfile(rawValue: profileRawValue) {
            state.translationProfile = profile
        }

        if let sttRawValue = defaults.string(forKey: sttBackendKey),
           let sttBackend = STTBackend(rawValue: sttRawValue) {
            state.sttBackend = sttBackend
        } else {
            // Keep Voxtral as the product default when no valid preference is stored.
            state.sttBackend = .voxtral
        }

        if let providerRawValue = defaults.string(forKey: providerModeKey),
           let provider = ProviderMode(rawValue: providerRawValue) {
            state.providerMode = provider
        }

        state.localVoxtralModel = defaults.string(forKey: sttModelKey) ?? "mistralai/Voxtral-Mini-3B-2507"
        state.localWhisperModel = defaults.string(forKey: whisperModelKey) ?? "openai/whisper-small"
        if defaults.object(forKey: voxtralSafeModeKey) == nil {
            state.voxtralSafeModeEnabled = true
            defaults.set(true, forKey: voxtralSafeModeKey)
        } else {
            state.voxtralSafeModeEnabled = defaults.bool(forKey: voxtralSafeModeKey)
        }
        state.privateAPIBaseURL = defaults.string(forKey: privateAPIBaseURLKey) ?? ""
        state.privateAPIModel = defaults.string(forKey: privateAPIModelKey) ?? "gpt-4o-mini"
        state.privateAPIKey = KeychainService.load(account: Self.keychainPrivateAPIKeyAccount) ?? ""
        state.openAIBaseURL = defaults.string(forKey: openAIBaseURLKey) ?? "https://api.openai.com"
        state.openAIAPIKey = KeychainService.load(account: Self.keychainOpenAIAPIKeyAccount) ?? ""
        state.openAISTTModel = defaults.string(forKey: openAISTTModelKey) ?? "whisper-1"
        state.openAITTSModel = defaults.string(forKey: openAITTSModelKey) ?? "gpt-4o-mini-tts"
        state.openAITTSVoice = defaults.string(forKey: openAITTSVoiceKey) ?? "alloy"
        state.translationModeEnabled = defaults.bool(forKey: translationModeEnabledKey)

        let completed = defaults.bool(forKey: onboardingKey)
        if completed {
            state.onboardingPhase = .complete
            state.setIdle()
        } else {
            state.onboardingPhase = .calibrating
            state.sessionState = .onboarding
            state.calibrationItems = defaultCalibrationItems()
            state.activeCalibrationIndex = 0
            state.statusLine = "Calibration mode: hold hotkey, say phrase, release"
        }
    }

    private func restartBackendWithCurrentConfiguration(status: String) {
        let launchConfiguration = currentBackendLaunchConfiguration()
        if backendManager.isRunning {
            backendManager.restart(configuration: launchConfiguration)
        } else {
            backendManager.startIfNeeded(configuration: launchConfiguration)
        }

        state.statusLine = status
        Task { await warmup() }
    }

    private func currentBackendLaunchConfiguration() -> BackendLaunchConfiguration {
        backendLaunchConfiguration(for: state.translationProfile)
    }

    private func backendLaunchConfiguration(for profile: TranslationProfile) -> BackendLaunchConfiguration {
        BackendLaunchConfiguration(
            sttBackend: state.sttBackend.rawValue,
            sttModel: state.localVoxtralModel,
            whisperModel: state.localWhisperModel,
            voxtralSafeModeEnabled: state.voxtralSafeModeEnabled,
            translateModel: profile.modelID,
            translateBackend: profile.backendKind,
            privateAPIBaseURL: state.privateAPIBaseURL,
            privateAPIModel: state.privateAPIModel,
            privateAPIKey: state.privateAPIKey,
            openAIBaseURL: state.openAIBaseURL,
            openAIAPIKey: state.openAIAPIKey,
            openAISTTModel: state.openAISTTModel,
            openAITTSModel: state.openAITTSModel,
            openAITTSVoice: state.openAITTSVoice
        )
    }

    private func processDictation(sessionID: String, rawText: String) async throws {
        if state.providerMode == .privateAPI {
            try await requestPrivacyPreview(
                sessionID: sessionID,
                operation: .cleanup,
                inputText: rawText,
                pending: .dictationCleanup(sessionID: sessionID, rawText: rawText)
            )
            return
        }

        let lightText = try await BackendAPIClient.cleanup(
            sessionID: sessionID,
            mode: .light,
            inputText: rawText,
            toneStyle: state.toneStyle,
            providerMode: .localOnly
        ).outputText

        let polishResponse = try await BackendAPIClient.cleanup(
            sessionID: sessionID,
            mode: .polish,
            inputText: rawText,
            toneStyle: state.toneStyle,
            providerMode: .localOnly
        )

        let candidate = TranscriptCandidate(
            rawText: rawText,
            lightText: lightText,
            polishText: polishResponse.outputText,
            selectedMode: .raw
        )

        state.transcriptCandidate = candidate
        state.selectedMode = .raw
        state.sessionState = .review
        state.statusLine = "Review and insert"
        state.recordingDuration = 0
        sessionMemory.push(candidate: candidate)
    }

    private func processTranslation(sessionID: String, rawText: String) async throws {
        if state.providerMode == .privateAPI {
            try await requestPrivacyPreview(
                sessionID: sessionID,
                operation: .translate,
                inputText: rawText,
                pending: .translation(sessionID: sessionID, rawText: rawText)
            )
            return
        }

        let translation = try await BackendAPIClient.translate(
            sessionID: sessionID,
            sourceText: rawText,
            sourceLanguage: "en",
            targetLanguage: "de",
            providerMode: .localOnly
        )

        state.translationCandidate = TranslationCandidate(
            sourceEnglish: translation.sourceText,
            targetGerman: translation.translatedText,
            approved: false
        )
        state.sessionState = .review
        state.statusLine = "Approve translation before insert"
        state.recordingDuration = 0
    }

    private func processMeeting(sessionID: String, rawText: String) async throws {
        if state.providerMode == .privateAPI {
            try await requestPrivacyPreview(
                sessionID: sessionID,
                operation: .meeting,
                inputText: rawText,
                pending: .meetingSummary(sessionID: sessionID, rawText: rawText)
            )
            return
        }

        let meeting = try await BackendAPIClient.meetingSummarize(
            sessionID: sessionID,
            transcript: rawText,
            toneStyle: state.toneStyle,
            providerMode: .localOnly
        )

        state.meetingCandidate = MeetingCandidate(
            transcript: meeting.transcript,
            summary: meeting.summary,
            decisions: meeting.decisions,
            actionItems: meeting.actionItems,
            followUps: meeting.followUps,
            speakerSegments: meeting.speakerSegments.map {
                MeetingSpeakerSegment(
                    speaker: $0.speaker,
                    text: $0.text,
                    utteranceCount: max(1, $0.utteranceCount)
                )
            },
            taskOwners: meeting.taskOwners.map {
                MeetingTaskOwner(
                    task: $0.task,
                    owner: $0.owner,
                    confidence: min(1.0, max(0.0, $0.confidence))
                )
            },
            markdownExport: meeting.markdownExport,
            notionExport: meeting.notionExport,
            approved: false
        )
        state.sessionState = .review
        state.statusLine = "Review and approve meeting notes"
        state.recordingDuration = 0
    }

    private func requestPrivacyPreview(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String,
        pending: PendingPrivacyOperation
    ) async throws {
        let previewResponse = try await BackendAPIClient.privacyPreview(
            sessionID: sessionID,
            operation: operation,
            inputText: inputText
        )

        guard let op = PrivacyOperationKind(rawValue: previewResponse.operation) else {
            throw NSError(domain: "VoxFlow", code: 4001, userInfo: [NSLocalizedDescriptionKey: "Invalid privacy preview operation"])
        }

        state.privacyPreview = PrivacyPreview(
            operation: op,
            token: previewResponse.token,
            originalText: previewResponse.originalText,
            redactedText: previewResponse.redactedText
        )
        pendingPrivacyOperation = pending
        state.sessionState = .review
        state.statusLine = "Review privacy preview and approve request"
        state.recordingDuration = 0
    }

    private func continuePendingPrivacyOperation(
        _ operation: PendingPrivacyOperation,
        consentToken: String,
        allowRaw: Bool
    ) async throws {
        switch operation {
        case .dictationCleanup(let sessionID, let rawText):
            let lightText = try await BackendAPIClient.cleanup(
                sessionID: sessionID,
                mode: .light,
                inputText: rawText,
                toneStyle: state.toneStyle,
                providerMode: .privateAPI,
                consentToken: consentToken,
                allowRaw: allowRaw
            ).outputText

            let polish = try await BackendAPIClient.cleanup(
                sessionID: sessionID,
                mode: .polish,
                inputText: rawText,
                toneStyle: state.toneStyle,
                providerMode: .privateAPI,
                consentToken: consentToken,
                allowRaw: allowRaw
            ).outputText

            let candidate = TranscriptCandidate(
                rawText: rawText,
                lightText: lightText,
                polishText: polish,
                selectedMode: .raw
            )

            state.transcriptCandidate = candidate
            state.sessionState = .review
            state.selectedMode = .raw
            state.statusLine = allowRaw ? "Private API cleanup complete" : "Private API cleanup complete (redacted)"

        case .translation(let sessionID, let rawText):
            let translation = try await BackendAPIClient.translate(
                sessionID: sessionID,
                sourceText: rawText,
                sourceLanguage: "en",
                targetLanguage: "de",
                providerMode: .privateAPI,
                consentToken: consentToken,
                allowRaw: allowRaw
            )

            state.translationCandidate = TranslationCandidate(
                sourceEnglish: translation.sourceText,
                targetGerman: translation.translatedText,
                approved: false
            )
            state.sessionState = .review
            state.statusLine = allowRaw ? "Review translation before insert" : "Review redacted translation before insert"

        case .meetingSummary(let sessionID, let rawText):
            let meeting = try await BackendAPIClient.meetingSummarize(
                sessionID: sessionID,
                transcript: rawText,
                toneStyle: state.toneStyle,
                providerMode: .privateAPI,
                consentToken: consentToken,
                allowRaw: allowRaw
            )

            state.meetingCandidate = MeetingCandidate(
                transcript: meeting.transcript,
                summary: meeting.summary,
                decisions: meeting.decisions,
                actionItems: meeting.actionItems,
                followUps: meeting.followUps,
                speakerSegments: meeting.speakerSegments.map {
                    MeetingSpeakerSegment(
                        speaker: $0.speaker,
                        text: $0.text,
                        utteranceCount: max(1, $0.utteranceCount)
                    )
                },
                taskOwners: meeting.taskOwners.map {
                    MeetingTaskOwner(
                        task: $0.task,
                        owner: $0.owner,
                        confidence: min(1.0, max(0.0, $0.confidence))
                    )
                },
                markdownExport: meeting.markdownExport,
                notionExport: meeting.notionExport,
                approved: false
            )
            state.sessionState = .review
            state.statusLine = allowRaw ? "Review meeting notes" : "Review redacted meeting notes"
        }
    }

    private func benchmarkSamples() -> [String] {
        [
            "Please send the revised project timeline by tomorrow morning.",
            "I will join the meeting in ten minutes and share the latest status.",
            "Can you summarize the key decisions from today's workshop?"
        ]
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(1.0, max(0.0, p))
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        let weight = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1.0 - weight) + sorted[upperIndex] * weight
    }

    private func recordCaptureMetrics(
        latencyMs: Int,
        commandLane: Bool,
        onboardingCalibration: Bool
    ) {
        state.captureCount += 1
        state.totalTranscriptionLatencyMs += max(0, latencyMs)
        state.lastTranscriptionLatencyMs = max(0, latencyMs)

        if state.providerMode == .privateAPI {
            state.privateAPICaptureCount += 1
        } else {
            state.localCaptureCount += 1
        }

        guard !commandLane, !onboardingCalibration else { return }
        state.workflowCaptureCounts[state.workflowMode, default: 0] += 1
    }

    private func updateBenchmarkHistory(with results: [TranslationBenchmarkResult]) {
        for result in results {
            var stats = state.benchmarkHistoryByProfile[result.profile] ?? TranslationBenchmarkHistoryStats(
                profile: result.profile,
                benchmarkRuns: 0,
                successfulRuns: 0,
                placeholderRuns: 0,
                totalMedianLatencyMs: 0,
                totalP95LatencyMs: 0,
                lastMedianLatencyMs: nil,
                lastP95LatencyMs: nil
            )

            stats.benchmarkRuns += 1
            if result.placeholderDetected || result.runs == 0 {
                stats.placeholderRuns += 1
                stats.lastMedianLatencyMs = nil
                stats.lastP95LatencyMs = nil
            } else {
                stats.successfulRuns += 1
                stats.totalMedianLatencyMs += result.medianLatencyMs
                stats.totalP95LatencyMs += result.p95LatencyMs
                stats.lastMedianLatencyMs = result.medianLatencyMs
                stats.lastP95LatencyMs = result.p95LatencyMs
            }

            state.benchmarkHistoryByProfile[result.profile] = stats
        }
    }

    private func recordInsertStats(forApp appName: String, result: InsertResult) {
        var stats = state.insertStatsByApp[appName] ?? AppInsertStats(
            appName: appName,
            successCount: 0,
            fallbackCount: 0,
            failedCount: 0
        )

        if result.success {
            stats.successCount += 1
            if result.fallbackUsed {
                stats.fallbackCount += 1
            }
        } else {
            stats.failedCount += 1
        }

        state.insertStatsByApp[appName] = stats
    }

    private func executeCommandLane(rawText: String) {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            state.statusLine = "No command captured"
            state.sessionState = .idle
            return
        }

        guard let intent = parseCommandIntent(from: normalized) else {
            state.statusLine = "Unknown command: \(normalized)"
            state.sessionState = .idle
            return
        }

        switch intent {
        case .switchToDictation:
            selectWorkflowMode(.dictation)
        case .switchToTranslate:
            if !state.translationModeEnabled {
                state.translationModeEnabled = true
                UserDefaults.standard.set(true, forKey: translationModeEnabledKey)
            }
            selectWorkflowMode(.translateEnToDe)
        case .switchToMeeting:
            selectWorkflowMode(.meeting)
        case .switchToLocalProvider:
            selectProviderMode(.localOnly)
        case .switchToPrivateProvider:
            selectProviderMode(.privateAPI)
        case .switchToVoxtralSTT:
            selectSTTBackend(.voxtral)
        case .switchToWhisperSTT:
            selectSTTBackend(.whisper)
        case .switchToOpenAISTT:
            selectSTTBackend(.openAI)
        case .setTone(let tone):
            selectToneStyle(tone)
        case .approve:
            if state.privacyPreview != nil {
                approvePrivacyPreview(sendRaw: false)
            } else if state.workflowMode == .translateEnToDe {
                approveTranslation()
            } else if state.workflowMode == .meeting {
                approveMeetingNotes()
            }
        case .insert:
            insertCurrentText()
        case .copy:
            copyCurrentText()
        case .retry:
            retryLastCapture()
        case .undo:
            if insertService.triggerUndo() {
                state.statusLine = "Undo triggered"
            } else {
                state.statusLine = "Undo command failed"
            }
        case .runBenchmark:
            Task { @MainActor in
                await runTranslationBenchmark()
            }
        }

        if state.sessionState == .transcribing {
            state.sessionState = .idle
        }
    }

    private func parseCommandIntent(from rawText: String) -> CommandIntent? {
        let words = rawText.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        let joined = words.joined(separator: " ")

        let modePatterns: [(keywords: [String], intent: CommandIntent)] = [
            (["meeting", "mode"], .switchToMeeting),
            (["translate", "mode"], .switchToTranslate),
            (["translation", "mode"], .switchToTranslate),
            (["dictation", "mode"], .switchToDictation),
            (["normal", "mode"], .switchToDictation),
            (["local", "mode"], .switchToLocalProvider),
            (["local", "provider"], .switchToLocalProvider),
            (["api", "mode"], .switchToPrivateProvider),
            (["private", "api"], .switchToPrivateProvider),
            (["voxtral", "stt"], .switchToVoxtralSTT),
            (["voxtral", "speech"], .switchToVoxtralSTT),
            (["whisper", "stt"], .switchToWhisperSTT),
            (["whisper", "speech"], .switchToWhisperSTT),
            (["openai", "stt"], .switchToOpenAISTT),
            (["openai", "speech"], .switchToOpenAISTT),
            (["tone", "formal"], .setTone(.formal)),
            (["formal", "tone"], .setTone(.formal)),
            (["tone", "concise"], .setTone(.concise)),
            (["concise", "tone"], .setTone(.concise)),
            (["tone", "friendly"], .setTone(.friendly)),
            (["friendly", "tone"], .setTone(.friendly)),
            (["tone", "neutral"], .setTone(.neutral)),
            (["neutral", "tone"], .setTone(.neutral)),
        ]

        for (keywords, intent) in modePatterns {
            if keywords.allSatisfy({ words.contains($0) }) {
                return intent
            }
        }

        let singleWordCommands: [(String, CommandIntent)] = [
            ("approve", .approve),
            ("insert", .insert),
            ("copy", .copy),
            ("retry", .retry),
            ("undo", .undo),
            ("benchmark", .runBenchmark),
        ]

        for (keyword, intent) in singleWordCommands {
            if joined == keyword || joined.hasPrefix("\(keyword) ") || joined.hasSuffix(" \(keyword)") {
                return intent
            }
        }

        return nil
    }

    private enum PendingPrivacyOperation {
        case dictationCleanup(sessionID: String, rawText: String)
        case translation(sessionID: String, rawText: String)
        case meetingSummary(sessionID: String, rawText: String)
    }

    private enum CommandIntent {
        case switchToDictation
        case switchToTranslate
        case switchToMeeting
        case switchToLocalProvider
        case switchToPrivateProvider
        case switchToVoxtralSTT
        case switchToWhisperSTT
        case switchToOpenAISTT
        case setTone(ToneStyle)
        case approve
        case insert
        case copy
        case retry
        case undo
        case runBenchmark
    }

    private func defaultCalibrationItems() -> [CalibrationItem] {
        [
            CalibrationItem(expectedPhrase: "Schedule a team sync for Thursday at 2 PM."),
            CalibrationItem(expectedPhrase: "Please summarize today’s project updates in three bullets."),
            CalibrationItem(expectedPhrase: "Draft a follow-up email and keep it concise.")
        ]
    }

    private func handleCalibrationResult(rawText: String) {
        guard state.calibrationItems.indices.contains(state.activeCalibrationIndex) else {
            completeCalibrationFlow()
            return
        }

        let expected = state.calibrationItems[state.activeCalibrationIndex].expectedPhrase
        let similarity = TextSimilarityService.normalizedSimilarity(lhs: expected, rhs: rawText)

        state.calibrationItems[state.activeCalibrationIndex].heardPhrase = rawText
        state.calibrationItems[state.activeCalibrationIndex].score = similarity

        if state.activeCalibrationIndex + 1 < state.calibrationItems.count {
            state.activeCalibrationIndex += 1
            state.sessionState = .onboarding
            state.statusLine = "Calibration captured. Next phrase ready."
        } else {
            completeCalibrationFlow()
        }
    }

    private func completeCalibrationFlow() {
        state.onboardingPhase = .complete
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state.setIdle()
        state.statusLine = "Calibration complete. Dictation ready."
    }

    private func startFocusMonitoring() {
        focusMonitor.start { [weak self] snapshot in
            guard let self else { return }
            self.state.focusTarget = snapshot

            guard self.state.sessionState == .idle else { return }
            if self.state.onboardingPhase == .calibrating {
                self.state.statusLine = "Calibration mode: hold hotkey, say phrase, release"
                return
            }

            if self.state.canStartCaptureForDictation {
                let app = snapshot.appName ?? "active app"
                self.state.statusLine = "Ready in \(app). Hold hotkey to talk"
            } else {
                self.state.statusLine = "Focus a text field or cursor to enable dictation"
            }
        }
    }
}
