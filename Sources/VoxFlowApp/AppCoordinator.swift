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

    private(set) lazy var settings: SettingsCoordinating = SettingsCoordinator(state: state, backendManager: backendManager)
    private(set) lazy var onboarding: OnboardingCoordinating = OnboardingCoordinator(state: state)
    private(set) lazy var textInsertion: TextInsertionCoordinating = TextInsertionCoordinator(state: state, insertService: insertService)
    private(set) lazy var benchmark: TranslationBenchmarkCoordinating = TranslationBenchmarkCoordinator(state: state, backendManager: backendManager, settings: settings)
    private(set) lazy var privacy: PrivacyConsentCoordinating = PrivacyConsentCoordinator(state: state)

    private var timer: Timer?
    private var sessionCounter: Int = 0

    private init() {
        let settingsCoordinator = SettingsCoordinator(state: state, backendManager: backendManager)
        settingsCoordinator.migrateAPIKeysToKeychain()
        settingsCoordinator.configureInitialState()
        self.settings = settingsCoordinator
        backendManager.startIfNeeded(configuration: settingsCoordinator.currentBackendLaunchConfiguration())
        configureHotkeys()
        startFocusMonitoring()
        Task { await warmup() }
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
        privacy.clearPendingOperation()

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
                onboarding.handleCalibrationResult(rawText: rawText)
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
        privacy.clearPendingOperation()
        state.isCommandLaneActive = false
        state.setIdle()
    }

    // MARK: - Text Insertion Forwarding

    func copyCurrentText() { textInsertion.copyCurrentText() }
    func copyMeetingMarkdownTemplate() { textInsertion.copyMeetingMarkdownTemplate() }
    func copyMeetingNotionTemplate() { textInsertion.copyMeetingNotionTemplate() }
    func insertCurrentText() { textInsertion.insertCurrentText() }

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

    // MARK: - Privacy Consent Forwarding

    func approvePrivacyPreview(sendRaw: Bool) { privacy.approvePrivacyPreview(sendRaw: sendRaw) }
    func cancelPrivacyPreview() { privacy.cancelPrivacyPreview() }

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
        privacy.clearPendingOperation()

        switch mode {
        case .dictation:
            state.statusLine = "Dictation mode active"
        case .translateEnToDe:
            state.statusLine = "Translate mode active (EN→DE)"
        case .meeting:
            state.statusLine = "Meeting mode active"
        }
    }

    // MARK: - Settings Forwarding

    func setTranslationModeEnabled(_ isEnabled: Bool) { settings.setTranslationModeEnabled(isEnabled) }
    func selectTranslationProfile(_ profile: TranslationProfile) { settings.selectTranslationProfile(profile) }
    func selectSTTBackend(_ backend: STTBackend) { settings.selectSTTBackend(backend) }
    func updateLocalSpeechModels(voxtralModel: String, whisperModel: String) { settings.updateLocalSpeechModels(voxtralModel: voxtralModel, whisperModel: whisperModel) }
    func setVoxtralSafeModeEnabled(_ isEnabled: Bool) { settings.setVoxtralSafeModeEnabled(isEnabled) }
    func selectProviderMode(_ mode: ProviderMode) {
        if mode == .localOnly {
            state.privacyPreview = nil
            privacy.clearPendingOperation()
        }
        settings.selectProviderMode(mode)
    }
    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String) { settings.updatePrivateAPIConfig(baseURL: baseURL, model: model, apiKey: apiKey) }
    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String, ttsModel: String, ttsVoice: String) { settings.updateOpenAIConfig(baseURL: baseURL, apiKey: apiKey, sttModel: sttModel, ttsModel: ttsModel, ttsVoice: ttsVoice) }

    // MARK: - Benchmark Forwarding

    func runTranslationBenchmark() async {
        await benchmark.runTranslationBenchmark()
        Task { await warmup() }
    }
    func applyFastestBenchmarkProfile() { benchmark.applyFastestBenchmarkProfile() }

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
        backendManager.startIfNeeded(configuration: settings.currentBackendLaunchConfiguration())
    }

    func stopBackend() {
        backendManager.stop()
    }

    // MARK: - Onboarding Forwarding

    func restartOnboardingCalibration() { onboarding.restartOnboardingCalibration() }
    func completeOnboardingManually() { onboarding.completeOnboardingManually() }

    func resetDashboardMetrics() {
        state.resetDashboardMetrics()
        state.statusLine = "Dashboard metrics reset"
    }


    private func processDictation(sessionID: String, rawText: String) async throws {
        if state.providerMode == .privateAPI {
            try await privacy.requestPrivacyPreview(
                sessionID: sessionID,
                operation: .cleanup,
                inputText: rawText
            ) { [weak self] consentToken, allowRaw in
                guard let self else { return }
                let lightText = try await BackendAPIClient.cleanup(
                    sessionID: sessionID,
                    mode: .light,
                    inputText: rawText,
                    toneStyle: self.state.toneStyle,
                    providerMode: .privateAPI,
                    consentToken: consentToken,
                    allowRaw: allowRaw
                ).outputText

                let polish = try await BackendAPIClient.cleanup(
                    sessionID: sessionID,
                    mode: .polish,
                    inputText: rawText,
                    toneStyle: self.state.toneStyle,
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

                self.state.transcriptCandidate = candidate
                self.state.sessionState = .review
                self.state.selectedMode = .raw
                self.state.statusLine = allowRaw ? "Private API cleanup complete" : "Private API cleanup complete (redacted)"
            }
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
            try await privacy.requestPrivacyPreview(
                sessionID: sessionID,
                operation: .translate,
                inputText: rawText
            ) { [weak self] consentToken, allowRaw in
                guard let self else { return }
                let translation = try await BackendAPIClient.translate(
                    sessionID: sessionID,
                    sourceText: rawText,
                    sourceLanguage: "en",
                    targetLanguage: "de",
                    providerMode: .privateAPI,
                    consentToken: consentToken,
                    allowRaw: allowRaw
                )

                self.state.translationCandidate = TranslationCandidate(
                    sourceEnglish: translation.sourceText,
                    targetGerman: translation.translatedText,
                    approved: false
                )
                self.state.sessionState = .review
                self.state.statusLine = allowRaw ? "Review translation before insert" : "Review redacted translation before insert"
            }
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
            try await privacy.requestPrivacyPreview(
                sessionID: sessionID,
                operation: .meeting,
                inputText: rawText
            ) { [weak self] consentToken, allowRaw in
                guard let self else { return }
                let meeting = try await BackendAPIClient.meetingSummarize(
                    sessionID: sessionID,
                    transcript: rawText,
                    toneStyle: self.state.toneStyle,
                    providerMode: .privateAPI,
                    consentToken: consentToken,
                    allowRaw: allowRaw
                )

                self.state.meetingCandidate = MeetingCandidate(
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
                self.state.sessionState = .review
                self.state.statusLine = allowRaw ? "Review meeting notes" : "Review redacted meeting notes"
            }
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



    private func executeCommandLane(rawText: String) {
        let normalized = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            state.statusLine = "No command captured"
            state.sessionState = .idle
            return
        }

        guard let intent = CommandParser.parse(from: normalized) else {
            state.statusLine = "Unknown command: \(normalized)"
            state.sessionState = .idle
            return
        }

        switch intent {
        case .switchToDictation:
            selectWorkflowMode(.dictation)
        case .switchToTranslate:
            if !state.translationModeEnabled {
                settings.setTranslationModeEnabled(true)
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
