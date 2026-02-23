import AppKit
import Combine
import Foundation
import os.log
import SwiftUI

extension Notification.Name {
    static let voxflowOpenDashboard = Notification.Name("voxflowOpenDashboard")
    static let voxflowOpenSetup = Notification.Name("voxflowOpenSetup")
}

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()
    private let log = Logger(subsystem: "local.voxflow.app", category: "AppCoordinator")

    @Published var state = AppState()

    private let backendManager = BackendProcessManager()
    private let audioCapture = AudioCaptureService()
    private let hotkeyService = GlobalHotkeyService()
    private let fnHoldHotkeyService = FnHoldHotkeyService()
    private let commandHotkeyService = GlobalHotkeyService()
    private let cueSoundService = CaptureCueSoundService()
    private let permissionService = PermissionService()
    private let insertService = AccessibilityInsertService()
    private let sessionMemory = SessionMemoryStore(capacity: 20)
    private let whisperKitService = WhisperKitSTTService()
    private lazy var focusMonitor = FocusContextMonitor(insertService: insertService)

    private(set) lazy var settings: SettingsCoordinating = SettingsCoordinator(state: state, backendManager: backendManager)
    private(set) lazy var onboarding: OnboardingCoordinating = OnboardingCoordinator(state: state)
    private(set) lazy var textInsertion: TextInsertionCoordinating = TextInsertionCoordinator(state: state, insertService: insertService)
    private(set) lazy var benchmark: TranslationBenchmarkCoordinating = TranslationBenchmarkCoordinator(state: state, backendManager: backendManager, settings: settings)
    private(set) lazy var privacy: PrivacyConsentCoordinating = PrivacyConsentCoordinator(state: state)

    private var timer: Timer?
    private var captureTimeoutTimer: Timer?
    private var sessionCounter: Int = 0
    private var hotkeysRegistered = false
    private var fnTriggeredCaptureInProgress = false
    private var capturedTargetApp: NSRunningApplication?
    private var cancellables = Set<AnyCancellable>()
    private static let maxCaptureDuration: TimeInterval = 60
    private static let minCaptureSamples: Int = 4800 // 0.3s at 16kHz mono PCM16 = 4800 samples = 9600 bytes
    private var warmupTask: Task<Void, Never>?
    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("VoxFlowMainWindow")
    private var mainWindowController: NSWindowController?
    private(set) var menuBarPanel: MenuBarPanelController?
    private var windowCloseObserver: Any?

    private init() {
        let settingsCoordinator = SettingsCoordinator(state: state, backendManager: backendManager)
        settingsCoordinator.migrateAPIKeysToKeychain()
        settingsCoordinator.configureInitialState()
        self.settings = settingsCoordinator
        backendManager.startIfNeededAsync(configuration: settingsCoordinator.currentBackendLaunchConfiguration())
        startFocusMonitoring()
        beginWarmupMonitoring()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showMainWindow()
        }
        state.$sessionState
            .removeDuplicates()
            .sink { [weak self] newState in
                if newState == .idle {
                    self?.capturedTargetApp = nil
                    self?.focusMonitor.unfreeze()
                }
            }
            .store(in: &cancellables)

        setupMenuBarPanel()
    }

    func warmup() async {
        // Load WhisperKit model if selected
        if state.sttBackend == .whisperKit {
            await loadWhisperKitModel()
        }

        // Always poll backend readiness (still needed for cleanup/translation)
        for attempt in 0..<24 {
            guard !Task.isCancelled else { return }
            await refreshBackendReadiness()
            if state.backendReadyForDictation {
                return
            }
            // If WhisperKit is ready, we can dictate even without backend
            if state.sttBackend == .whisperKit && state.whisperKitReady {
                return
            }
            let delay: UInt64 = attempt < 4 ? 2_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func loadWhisperKitModel() async {
        let modelsDir = ProcessInfo.processInfo.environment["VOXFLOW_MODELS_DIR"]
            ?? (ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"].map { $0 + "/models" })
            ?? "./models"
        let modelName = "openai_whisper-small.en"
        let modelFolder = WhisperKitSTTService.resolveModelFolder(modelsDir: modelsDir, modelName: modelName)

        state.statusLine = "Loading WhisperKit model..."
        do {
            try await whisperKitService.load(modelFolder: modelFolder)
            state.whisperKitReady = true
            state.statusLine = "WhisperKit ready"
        } catch {
            state.whisperKitReady = false
            state.statusLine = "WhisperKit failed: \(error.localizedDescription)"
            log.error("WhisperKit load failed: \(error.localizedDescription)")
        }
    }

    func refreshReadiness() {
        Task { await refreshBackendReadiness() }
    }

    func appDidBecomeActive() {
        showMainWindowIfNeeded()
        configureHotkeysIfNeeded()
        if !state.backendReadyForDictation {
            beginWarmupMonitoring()
        }
    }

    func showMainWindow() {
        showMainWindowIfNeeded(force: true)
    }

    private func beginWarmupMonitoring() {
        warmupTask?.cancel()
        warmupTask = Task { [weak self] in
            await self?.warmup()
        }
    }

    private func refreshBackendReadiness() async {
        do {
            let readiness = try await BackendAPIClient.ready()
            state.backendReadyForDictation = readiness.readyForDictation
            state.backendReadinessIssue = readiness.issues.first
            if !readiness.readyForDictation, let firstIssue = readiness.issues.first {
                state.statusLine = "Backend not ready: \(firstIssue)"
            }
        } catch {
            state.backendReadyForDictation = false
            let startupIssue = backendManager.lastStartupFailureReason
            state.backendReadinessIssue = startupIssue ?? "Backend offline"
            if let startupIssue {
                state.statusLine = "Backend startup issue: \(startupIssue)"
            } else {
                state.statusLine = "Backend offline. Start backend in Settings."
            }
        }
    }

    func configureHotkeysIfNeeded() {
        configureHotkeys(force: false)
    }

    func configureHotkeys(force: Bool = true) {
        if !force && hotkeysRegistered {
            return
        }
        do {
            if state.dictationHotkeyPreset.usesFlagsMonitor {
                hotkeyService.unregister()
                fnHoldHotkeyService.register(onPress: { [weak self] in
                    Task { @MainActor in self?.handleFnHoldPress() }
                }, onRelease: { [weak self] in
                    Task { @MainActor in await self?.handleFnHoldRelease() }
                })
            } else {
                fnHoldHotkeyService.unregister()
                try hotkeyService.register(configuration: state.dictationHotkeyPreset.configuration, onPress: { [weak self] in
                    Task { @MainActor in self?.startCapture() }
                }, onRelease: { [weak self] in
                    Task { @MainActor in await self?.finishCaptureAndTranscribe() }
                })
            }

            try commandHotkeyService.register(configuration: state.commandLaneHotkeyPreset.configuration, onPress: { [weak self] in
                Task { @MainActor in self?.startCapture(commandLane: true) }
            }, onRelease: { [weak self] in
                Task { @MainActor in await self?.finishCaptureAndTranscribe(commandLane: true) }
            })
            hotkeysRegistered = true
            state.errorMessage = nil
            log.info("Hotkeys registered")
        } catch {
            hotkeyService.unregister()
            fnHoldHotkeyService.unregister()
            commandHotkeyService.unregister()
            hotkeysRegistered = false
            log.error("Failed to register hotkey: \(error.localizedDescription)")
            state.errorMessage = "Failed to register hotkey. Check accessibility permissions."
        }
    }

    private func handleFnHoldPress() {
        startCapture()
        fnTriggeredCaptureInProgress = state.sessionState == .recording
    }

    private func handleFnHoldRelease() async {
        guard fnTriggeredCaptureInProgress else { return }
        fnTriggeredCaptureInProgress = false
        await finishCaptureAndTranscribe()
    }

    func startCapture(commandLane: Bool = false) {
        guard state.sessionState == .idle || state.sessionState == .review || state.sessionState == .error || state.sessionState == .onboarding else {
            let blockedState = state.sessionState
            log.warning("startCapture blocked: sessionState=\(String(describing: blockedState))")
            return
        }

        let permissions = permissionService.snapshot()
        if !permissions.microphoneAuthorized {
            log.warning("startCapture blocked: microphone not authorized")
            state.statusLine = "Microphone permission required — grant in System Settings"
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !permissions.accessibilityAuthorized {
            log.warning("startCapture blocked: accessibility not authorized")
            state.statusLine = "Accessibility permission required — grant in System Settings"
            return
        }

        let canTranscribe = state.backendReadyForDictation
            || (state.sttBackend == .whisperKit && state.whisperKitReady)
        if !canTranscribe {
            let backendReady = state.backendReadyForDictation
            let whisperReady = state.whisperKitReady
            log.warning("startCapture blocked: no STT backend ready (backend=\(backendReady), whisperKit=\(whisperReady))")
            state.statusLine = state.sttBackend == .whisperKit
                ? "WhisperKit not ready — wait for model load"
                : "Backend not ready — wait for model warmup"
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !state.canStartCaptureForDictation {
            let canStart = state.canStartCaptureForDictation
            log.warning("startCapture blocked: no focused text target (canStart=\(canStart))")
            state.statusLine = "Focus a text field or place cursor before dictating"
            return
        }

        state.resetForNewCapture()
        capturedTargetApp = NSWorkspace.shared.frontmostApplication
        focusMonitor.freeze()
        sessionCounter += 1
        state.isCommandLaneActive = commandLane
        if commandLane {
            fnTriggeredCaptureInProgress = false
        }
        privacy.clearPendingOperation()

        do {
            try audioCapture.startCapture()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.state.recordingDuration += 0.1
                }
            }
            captureTimeoutTimer?.invalidate()
            captureTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.maxCaptureDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state.sessionState == .recording else { return }
                    self.log.warning("Capture timeout reached (\(Self.maxCaptureDuration)s) — auto-stopping")
                    await self.finishCaptureAndTranscribe()
                }
            }
            if !commandLane {
                cueSoundService.playStartCue()
            }
        } catch {
            state.sessionState = .error
            state.errorMessage = "Microphone access failed: \(error.localizedDescription)"
            state.isCommandLaneActive = false
            fnTriggeredCaptureInProgress = false
        }
    }

    func finishCaptureAndTranscribe(commandLane: Bool = false) async {
        guard state.sessionState == .recording else {
            let blockedState = state.sessionState
            log.warning("finishCapture blocked: sessionState=\(String(describing: blockedState)), expected .recording")
            return
        }
        defer { state.isCommandLaneActive = false }
        if !commandLane {
            fnTriggeredCaptureInProgress = false
            cueSoundService.playStopCue()
        }

        timer?.invalidate()
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        state.sessionState = .transcribing
        state.statusLine = commandLane ? "Interpreting command..." : "Transcribing..."

        do {
            let capturedAudio = try audioCapture.stopCapture()

            // Guard: discard very short captures (< 0.3s) that cause Whisper hallucination
            let minBytes = Int(capturedAudio.sampleRate * 0.3) * MemoryLayout<Int16>.size
            if capturedAudio.pcm.count < minBytes {
                log.info("Audio too short (\(capturedAudio.pcm.count) bytes, need \(minBytes)) — discarding")
                state.sessionState = .idle
                state.statusLine = "Too short — hold longer to dictate"
                state.recordingDuration = 0
                return
            }

            let sessionID = "session-\(sessionCounter)"
            let transcription: TranscribeResponse
            if state.sttBackend == .whisperKit {
                transcription = try await whisperKitService.transcribe(capturedAudio)
            } else {
                transcription = try await BackendAPIClient.transcribe(
                    sessionID: sessionID,
                    audioPCM: capturedAudio.pcm,
                    sampleRate: Int(capturedAudio.sampleRate),
                    chunkIndex: 0,
                    languageHint: "en"
                )
            }
            let isCalibrationCapture = state.onboardingPhase == .calibrating
            recordCaptureMetrics(
                latencyMs: transcription.latencyMs,
                commandLane: commandLane,
                onboardingCalibration: isCalibrationCapture
            )

            let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("Transcription: '\(rawText.prefix(100))' (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")

            if rawText.isEmpty || rawText.hasPrefix("[transcription") {
                log.info("Empty or placeholder transcription — discarding")
                state.sessionState = .idle
                state.statusLine = rawText.isEmpty ? "No speech detected — try again" : rawText
                state.recordingDuration = 0
                return
            }

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
            case .prompt:
                try await processPrompt(sessionID: sessionID, rawText: rawText)
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
        fnTriggeredCaptureInProgress = false
        state.setIdle()
        capturedTargetApp = nil
    }

    func cancelActiveCapture() {
        timer?.invalidate()

        if state.sessionState == .recording {
            _ = try? audioCapture.stopCapture()
            state.isCommandLaneActive = false
            fnTriggeredCaptureInProgress = false
            state.setIdle()
            capturedTargetApp = nil
            state.statusLine = "Capture canceled"
            return
        }

        if state.privacyPreview != nil {
            cancelPrivacyPreview()
            return
        }

        if state.sessionState == .review || state.sessionState == .error {
            retryLastCapture()
            return
        }
    }

    // MARK: - Text Insertion Forwarding

    func copyCurrentText() { textInsertion.copyCurrentText() }
    func copyMeetingMarkdownTemplate() { textInsertion.copyMeetingMarkdownTemplate() }
    func copyMeetingNotionTemplate() { textInsertion.copyMeetingNotionTemplate() }
    func insertCurrentText() { textInsertion.insertCurrentText(targetApp: capturedTargetApp) }

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
                // Local retone for WhisperKit
                if self.state.sttBackend == .whisperKit {
                    let lightText = TextCleanupService.cleanup(rawText, mode: .light, tone: tone)
                    let polishText = TextCleanupService.cleanup(rawText, mode: .polish, tone: tone)
                    state.transcriptCandidate = TranscriptCandidate(
                        rawText: rawText, lightText: lightText,
                        polishText: polishText, selectedMode: state.selectedMode
                    )
                    state.statusLine = "Tone: \(tone.displayName)"
                    return
                }

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

        if mode == .meeting && !state.meetingModeEnabled {
            state.statusLine = "Enable Experimental Meeting Mode in Settings"
            return
        }

        if mode == .prompt && !state.promptModeEnabled {
            state.statusLine = "Enable Experimental Prompt Mode in Settings"
            return
        }

        state.workflowMode = mode
        state.transcriptCandidate = nil
        state.translationCandidate = nil
        state.meetingCandidate = nil
        state.promptCandidate = nil
        state.privacyPreview = nil
        privacy.clearPendingOperation()

        switch mode {
        case .dictation:
            state.statusLine = "Dictation mode active"
        case .translateEnToDe:
            state.statusLine = "Translate mode active (EN→DE)"
        case .meeting:
            state.statusLine = "Meeting mode active"
        case .prompt:
            state.statusLine = "Prompt mode active"
        }
    }

    // MARK: - Settings Forwarding

    func selectInsertBehavior(_ behavior: InsertBehavior) { settings.selectInsertBehavior(behavior) }
    func updateAppProfile(bundleID: String, profile: AppProfile?) { settings.updateAppProfile(bundleID: bundleID, profile: profile) }
    func setTranslationModeEnabled(_ isEnabled: Bool) { settings.setTranslationModeEnabled(isEnabled) }
    func setMeetingModeEnabled(_ isEnabled: Bool) { settings.setMeetingModeEnabled(isEnabled) }
    func setPromptModeEnabled(_ isEnabled: Bool) { settings.setPromptModeEnabled(isEnabled) }
    func setDictationHotkeyPreset(_ preset: DictationHotkeyPreset) {
        settings.setDictationHotkeyPreset(preset)
        configureHotkeys(force: true)
    }
    func setCommandLaneHotkeyPreset(_ preset: CommandLaneHotkeyPreset) {
        settings.setCommandLaneHotkeyPreset(preset)
        configureHotkeys(force: true)
    }
    func selectTranslationProfile(_ profile: TranslationProfile) { settings.selectTranslationProfile(profile) }
    func selectSTTBackend(_ backend: STTBackend) { settings.selectSTTBackend(backend) }
    func updateLocalWhisperModel(whisperModel: String) { settings.updateLocalWhisperModel(whisperModel: whisperModel) }
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
        activateForWindow()
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !opened {
            log.error("Unable to open Settings window from coordinator")
            state.statusLine = "Unable to open Settings window"
        }
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
        backendManager.restartAsync(configuration: settings.currentBackendLaunchConfiguration())
        beginWarmupMonitoring()
    }

    func stopBackend() {
        warmupTask?.cancel()
        backendManager.stopAsync()
        state.backendReadyForDictation = false
        state.backendReadinessIssue = "Backend stopped"
    }

    private func showMainWindowIfNeeded(force: Bool = false) {
        if let mainWindow = NSApp.windows.first(where: {
            ($0.identifier == mainWindowIdentifier || $0.title == "VoxFlow") && !$0.isMiniaturized
        }) {
            mainWindow.makeKeyAndOrderFront(nil)
            if force {
                activateForWindow()
            }
            return
        }

        if let managedWindow = mainWindowController?.window {
            managedWindow.makeKeyAndOrderFront(nil)
            if force {
                activateForWindow()
            }
            return
        }

        if mainWindowController == nil {
            let host = NSHostingController(rootView: MainWindowView(coordinator: self, state: state))
            let window = NSWindow(contentViewController: host)
            window.identifier = mainWindowIdentifier
            window.title = "VoxFlow"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 700))
            window.center()
            window.isReleasedWhenClosed = false
            mainWindowController = NSWindowController(window: window)
        }

        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        activateForWindow()
    }

    // MARK: - Onboarding Forwarding

    func restartOnboardingCalibration() { onboarding.restartOnboardingCalibration() }
    func completeOnboardingManually() { onboarding.completeOnboardingManually() }

    func resetDashboardMetrics() {
        state.resetDashboardMetrics()
        state.statusLine = "Dashboard metrics reset"
    }

    func clearSessionHistory() {
        sessionMemory.clear()
        state.recentDictations = []
        state.statusLine = "History cleared"
    }


    private func pushToSessionMemory(_ candidate: TranscriptCandidate) {
        sessionMemory.push(candidate: candidate)
        state.recentDictations = sessionMemory.recent()
    }

    func insertRecentDictation(_ candidate: TranscriptCandidate) {
        let text = candidate.text(for: candidate.selectedMode)
        let appLabel = state.focusTarget.appName ?? "app"
        if textInsertion.insertText(text, statusSuffix: "Re-inserted — \(appLabel)") {
            state.sessionState = .idle
        }
    }

    private func resolveEffectiveProfile() -> AppProfile? {
        let bundleID = state.focusTarget.bundleID ?? ""
        return state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
    }

    private func processWithPrivacyGate(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String,
        process: @escaping @MainActor (ProviderMode, String?, Bool) async throws -> Void
    ) async throws {
        if state.providerMode == .privateAPI {
            try await privacy.requestPrivacyPreview(
                sessionID: sessionID,
                operation: operation,
                inputText: inputText
            ) { consentToken, allowRaw in
                try await process(.privateAPI, consentToken, allowRaw)
            }
            return
        }
        try await process(.localOnly, nil, false)
        state.recordingDuration = 0
    }

    private func processDictation(sessionID: String, rawText: String) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .cleanup, inputText: rawText
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let profile = self.resolveEffectiveProfile()
            let effectiveTone = profile?.tone ?? self.state.toneStyle
            let effectiveInsert = profile?.insertBehavior ?? self.state.insertBehavior

            // Auto-insert raw skips cleanup entirely
            if effectiveInsert == .autoInsertRaw && providerMode == .localOnly {
                let candidate = TranscriptCandidate(
                    rawText: rawText, lightText: rawText,
                    polishText: rawText, selectedMode: .raw,
                    timestamp: Date()
                )
                self.state.transcriptCandidate = candidate
                self.pushToSessionMemory(candidate)
                let appLabel = self.state.focusTarget.appName ?? "app"
                if self.textInsertion.insertText(rawText, statusSuffix: "Inserted (raw — \(appLabel))", targetApp: self.capturedTargetApp) {
                    self.state.sessionState = .idle
                } else {
                    self.state.sessionState = .review
                }
                return
            }

            // Local cleanup for WhisperKit — no backend needed
            if providerMode == .localOnly && self.state.sttBackend == .whisperKit {
                let lightText = TextCleanupService.cleanup(rawText, mode: .light, tone: effectiveTone)
                let polishText = TextCleanupService.cleanup(rawText, mode: .polish, tone: effectiveTone)
                let candidate = TranscriptCandidate(
                    rawText: rawText, lightText: lightText,
                    polishText: polishText, selectedMode: .raw,
                    timestamp: Date()
                )
                self.state.transcriptCandidate = candidate
                self.state.selectedMode = .raw
                self.pushToSessionMemory(candidate)

                // Auto-insert light/polish
                if let autoMode = effectiveInsert.cleanupMode {
                    let text = candidate.text(for: autoMode)
                    let toneLabel = effectiveTone != self.state.toneStyle ? ", \(effectiveTone.displayName)" : ""
                    let appLabel = self.state.focusTarget.appName ?? "app"
                    if self.textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel) — \(appLabel))", targetApp: self.capturedTargetApp) {
                        self.state.sessionState = .idle
                    } else {
                        self.state.sessionState = .review
                        self.state.statusLine = "Auto-insert failed — review and retry"
                    }
                    return
                }

                self.state.sessionState = .review
                self.state.statusLine = "Review and insert"
                return
            }

            let lightText = try await BackendAPIClient.cleanup(
                sessionID: sessionID, mode: .light, inputText: rawText,
                toneStyle: effectiveTone, providerMode: providerMode,
                consentToken: consentToken, allowRaw: allowRaw
            ).outputText
            let polishText = try await BackendAPIClient.cleanup(
                sessionID: sessionID, mode: .polish, inputText: rawText,
                toneStyle: effectiveTone, providerMode: providerMode,
                consentToken: consentToken, allowRaw: allowRaw
            ).outputText
            let candidate = TranscriptCandidate(
                rawText: rawText, lightText: lightText,
                polishText: polishText, selectedMode: .raw,
                timestamp: Date()
            )
            self.state.transcriptCandidate = candidate
            self.state.selectedMode = .raw
            if providerMode == .localOnly { self.pushToSessionMemory(candidate) }

            // Auto-insert light/polish
            if let autoMode = effectiveInsert.cleanupMode, providerMode == .localOnly {
                let text = candidate.text(for: autoMode)
                let toneLabel = effectiveTone != self.state.toneStyle ? ", \(effectiveTone.displayName)" : ""
                let appLabel = self.state.focusTarget.appName ?? "app"
                if self.textInsertion.insertText(text, statusSuffix: "Inserted (\(autoMode.displayName.lowercased())\(toneLabel) — \(appLabel))", targetApp: self.capturedTargetApp) {
                    self.state.sessionState = .idle
                } else {
                    self.state.sessionState = .review
                    self.state.statusLine = "Auto-insert failed — review and retry"
                }
                return
            }

            self.state.sessionState = .review
            self.state.statusLine = providerMode == .privateAPI
                ? (allowRaw ? "Private API cleanup complete" : "Private API cleanup complete (redacted)")
                : "Review and insert"
        }
    }

    private func processPrompt(sessionID: String, rawText: String) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .cleanup, inputText: rawText
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let profile = self.resolveEffectiveProfile()
            let effectiveTone = profile?.tone ?? self.state.toneStyle
            let effectiveInsert = profile?.insertBehavior ?? self.state.insertBehavior

            let cleanedText: String
            if providerMode == .localOnly && self.state.sttBackend == .whisperKit {
                cleanedText = TextCleanupService.cleanup(rawText, mode: .polish, tone: effectiveTone)
            } else {
                let cleanupResponse = try await BackendAPIClient.cleanup(
                    sessionID: sessionID, mode: .polish, inputText: rawText,
                    toneStyle: effectiveTone, providerMode: providerMode,
                    consentToken: consentToken, allowRaw: allowRaw
                )
                cleanedText = cleanupResponse.outputText
            }

            let intent = PromptFramingService.detectIntent(cleanedText)
            let framedPrompt = PromptFramingService.frame(cleanedText, intent: intent)

            let candidate = PromptCandidate(
                sessionID: sessionID,
                rawText: rawText,
                cleanedText: cleanedText,
                framedPrompt: framedPrompt,
                detectedIntent: intent
            )
            self.state.promptCandidate = candidate

            if let _ = effectiveInsert.cleanupMode, providerMode == .localOnly {
                let appLabel = self.state.focusTarget.appName ?? "app"
                if self.textInsertion.insertText(framedPrompt, statusSuffix: "Prompt inserted (\(intent.displayName) — \(appLabel))", targetApp: self.capturedTargetApp) {
                    self.state.sessionState = .idle
                } else {
                    self.state.sessionState = .review
                }
            } else {
                self.state.sessionState = .review
                self.state.statusLine = "Review prompt and insert"
            }
        }
    }

    private func processTranslation(sessionID: String, rawText: String) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .translate, inputText: rawText
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let translation = try await BackendAPIClient.translate(
                sessionID: sessionID, sourceText: rawText,
                sourceLanguage: "en", targetLanguage: "de",
                providerMode: providerMode, consentToken: consentToken, allowRaw: allowRaw
            )
            self.state.translationCandidate = TranslationCandidate(
                sourceEnglish: translation.sourceText,
                targetGerman: translation.translatedText, approved: false
            )
            self.state.sessionState = .review
            self.state.statusLine = providerMode == .privateAPI
                ? (allowRaw ? "Review translation before insert" : "Review redacted translation before insert")
                : "Approve translation before insert"
        }
    }

    private func processMeeting(sessionID: String, rawText: String) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .meeting, inputText: rawText
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let response = try await BackendAPIClient.meetingSummarize(
                sessionID: sessionID, transcript: rawText,
                toneStyle: self.state.toneStyle, providerMode: providerMode,
                consentToken: consentToken, allowRaw: allowRaw
            )
            self.state.meetingCandidate = MeetingCandidate(from: response)
            self.state.sessionState = .review
            self.state.statusLine = providerMode == .privateAPI
                ? (allowRaw ? "Review meeting notes" : "Review redacted meeting notes")
                : "Review and approve meeting notes"
        }
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
            selectWorkflowMode(.translateEnToDe)
        case .switchToMeeting:
            selectWorkflowMode(.meeting)
        case .switchToPromptMode:
            selectWorkflowMode(.prompt)
        case .switchToLocalProvider:
            selectProviderMode(.localOnly)
        case .switchToPrivateProvider:
            selectProviderMode(.privateAPI)
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

    private func setupMenuBarPanel() {
        let panelContent = CommandPaletteView(
            coordinator: self,
            state: state,
            onOpenDashboardWindow: {
                NotificationCenter.default.post(name: .voxflowOpenDashboard, object: nil)
            },
            onOpenSetup: {
                NotificationCenter.default.post(name: .voxflowOpenSetup, object: nil)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        .frame(width: 430)

        menuBarPanel = MenuBarPanelController(
            content: panelContent,
            iconName: iconName(for: state)
        )

        // Observe sessionState and commandLane for icon updates
        state.$sessionState
            .combineLatest(state.$isCommandLaneActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.menuBarPanel?.updateIcon(systemName: self.iconName(for: self.state))
            }
            .store(in: &cancellables)
    }

    private func iconName(for state: AppState) -> String {
        if state.isCommandLaneActive { return "terminal.fill" }
        switch state.sessionState {
        case .idle: return "mic.fill"
        case .recording: return "record.circle.fill"
        case .transcribing: return "waveform"
        case .review: return "checkmark.bubble.fill"
        case .inserting: return "square.and.arrow.down.fill"
        case .onboarding: return "sparkles"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Activation Policy

    /// Activate app and show in Dock when opening a managed window.
    func activateForWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installWindowCloseObserver()
    }

    /// Revert to accessory (menu-bar-only) when all managed windows close.
    private func installWindowCloseObserver() {
        guard windowCloseObserver == nil else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkAndRevertActivationPolicy()
            }
        }
    }

    private func checkAndRevertActivationPolicy() {
        let hasManagedWindows = NSApp.windows.contains { window in
            window.isVisible
            && window.level == .normal
            && window.className != "NSStatusBarWindow"
        }
        if !hasManagedWindows {
            NSApp.setActivationPolicy(.accessory)
            if let observer = windowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                windowCloseObserver = nil
            }
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
