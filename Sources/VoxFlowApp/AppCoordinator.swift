import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import os.log
import SwiftUI

extension Notification.Name {
    static let voxflowOpenDashboard = Notification.Name("voxflowOpenDashboard")
    static let voxflowOpenSetup = Notification.Name("voxflowOpenSetup")
    static let voxflowOpenCockpit = Notification.Name("voxflowOpenCockpit")
}

private final class CapturePipelineTraceBuilder {
    let sessionID: String
    let workflowMode: WorkflowMode
    let sttBackend: STTBackend
    let providerMode: ProviderMode
    let commandLane: Bool
    let recordedAt = Date()

    private let started = ContinuousClock.now
    private(set) var audioDurationMs: Int?
    private(set) var stageTimings: [PipelineStageTiming] = []

    init(
        sessionID: String,
        workflowMode: WorkflowMode,
        sttBackend: STTBackend,
        providerMode: ProviderMode,
        commandLane: Bool
    ) {
        self.sessionID = sessionID
        self.workflowMode = workflowMode
        self.sttBackend = sttBackend
        self.providerMode = providerMode
        self.commandLane = commandLane
    }

    func setAudioDuration(from audio: CapturedAudio) {
        audioDurationMs = Int((Double(audio.pcm.count) / (audio.sampleRate * 2.0)) * 1000.0)
    }

    func recordStage(_ name: String, startedAt: ContinuousClock.Instant, detail: String? = nil) {
        let elapsed = startedAt.elapsedMilliseconds()
        stageTimings.append(PipelineStageTiming(name: name, durationMs: elapsed, detail: detail))
    }

    func appendStage(name: String, durationMs: Int, detail: String? = nil) {
        stageTimings.append(PipelineStageTiming(name: name, durationMs: durationMs, detail: detail))
    }

    func build(statusLine: String, sessionState: SessionState) -> CapturePipelineTrace {
        CapturePipelineTrace(
            sessionID: sessionID,
            workflowMode: workflowMode,
            sttBackend: sttBackend,
            providerMode: providerMode,
            commandLane: commandLane,
            audioDurationMs: audioDurationMs,
            totalDurationMs: started.elapsedMilliseconds(),
            sessionState: sessionState,
            statusLine: statusLine,
            recordedAt: recordedAt,
            stageTimings: stageTimings
        )
    }

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
    private let cockpitHotkeyService = GlobalHotkeyService()
    private let cueSoundService = CaptureCueSoundService()
    private let permissionService = PermissionService()
    private let insertService = AccessibilityInsertService()
    private let sessionMemory = SessionMemoryStore(capacity: 20)
    private let whisperKitService = WhisperKitSTTService()
    private lazy var focusMonitor = FocusContextMonitor(insertService: insertService)

    private(set) var settings: SettingsCoordinating!
    private(set) lazy var onboarding: OnboardingCoordinating = OnboardingCoordinator(state: state)
    private(set) lazy var textInsertion: TextInsertionCoordinating = TextInsertionCoordinator(state: state, insertService: insertService)
    private(set) lazy var benchmark: TranslationBenchmarkCoordinating = TranslationBenchmarkCoordinator(state: state, backendManager: backendManager, settings: settings)
    private(set) lazy var privacy: PrivacyConsentCoordinating = PrivacyConsentCoordinator(state: state)
    private(set) lazy var translationWorkflow: TranslationWorkflowCoordinating = TranslationWorkflowCoordinator(state: state)
    private(set) lazy var promptWorkflow: PromptWorkflowCoordinating = PromptWorkflowCoordinator(state: state, textInsertion: textInsertion)
    private(set) lazy var dictationWorkflow: DictationWorkflowCoordinating = DictationWorkflowCoordinator(
        state: state,
        textInsertion: textInsertion,
        pushToSessionMemory: { [weak self] candidate in
            self?.pushToSessionMemory(candidate)
        }
    )

    // Cockpit Layer 0 — long-form workspace + smart actions.
    // Constructed lazily so the autoSaveDirectory is resolved relative to
    // Application Support at first access.
    private(set) lazy var cockpitSessionService: LongFormSessionService = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("VoxFlow/sessions", isDirectory: true)
        return LongFormSessionService(autoSaveDirectory: dir)
    }()
    private(set) lazy var cockpitActionService: SmartActionService = SmartActionService(backend: BackendAPISmartActionAdapter())
    private(set) lazy var cockpit: CockpitCoordinator = CockpitCoordinator(
        state: state,
        sessionService: cockpitSessionService,
        actionService: cockpitActionService,
        textInsertionCoordinator: textInsertion as? TextInsertionCoordinator
    )
    private(set) lazy var cockpitDictionary: DictionaryStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let base = appSupport.appendingPathComponent("VoxFlow", isDirectory: true)
        return DictionaryStore(fileURL: base.appendingPathComponent("dictionary.json"))
    }()
    private(set) lazy var cockpitCapture: CockpitCaptureCoordinator = CockpitCaptureCoordinator(
        capture: AudioCaptureService(),
        transcriber: whisperKitService,
        session: cockpitSessionService,
        dictionary: cockpitDictionary
    )

    private var timer: Timer?
    private var captureTimeoutTimer: Timer?
    private var sessionCounter: Int = 0
    private var hotkeysRegistered = false
    private var didFinishLaunching = false
    private var fnTriggeredCaptureInProgress = false
    private var capturedTargetApp: NSRunningApplication?
    private var lastTranscriptionConfidence: Double = 0.0
    private var cancellables = Set<AnyCancellable>()
    private static let maxCaptureDuration: TimeInterval = 60
    private static let minCaptureSamples: Int = 4800 // 0.3s at 16kHz mono PCM16 = 4800 samples = 9600 bytes
    private var warmupTask: Task<Void, Never>?
    private var selectToneStyleTask: Task<Void, Never>?
    private let mainWindowIdentifier = NSUserInterfaceItemIdentifier("VoxFlowMainWindow")
    private var mainWindowController: NSWindowController?
    private(set) var menuBarPanel: MenuBarPanelController?
    private var windowCloseObserver: Any?

    private init() {
        let settingsCoordinator = SettingsCoordinator(state: state, backendManager: backendManager)
        settingsCoordinator.migrateAPIKeysToKeychain()
        settingsCoordinator.configureInitialState()
        self.settings = settingsCoordinator
        startFocusMonitoring()
        beginWarmupMonitoring()
        state.$sessionState
            .removeDuplicates()
            .sink { [weak self] newState in
                if newState == .idle {
                    self?.capturedTargetApp = nil
                    self?.lastTranscriptionConfidence = 0.0
                    self?.focusMonitor.unfreeze()
                }
            }
            .store(in: &cancellables)

        // Defer panel setup until after the activation policy has settled.
        // WindowGroup auto-opens a window which triggers activateForWindow() →
        // setActivationPolicy(.regular). Creating the status item during that
        // window causes macOS to tear down its menu bar slot.
        //
        // Strategy: set a flag on didFinishLaunching, then let
        // checkAndRevertActivationPolicy() create the panel after reverting
        // to .accessory. If no window ever opens (cold start), a short
        // fallback timer sets it up directly.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidFinishLaunching()
            }
        }
    }

    func warmup() async {
        if state.sttBackend == .whisperKit {
            await loadWhisperKitModel()
        }

        let shouldPollBackend = state.backendShouldRun || state.backendReadiness.warmupInProgress
        guard shouldPollBackend else {
            await refreshBackendReadiness()
            return
        }

        if state.backendShouldRun && !backendManager.isRunning {
            state.backendReadiness.processRunning = true
            state.backendReadiness.warmupInProgress = true
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.statusSummary = "Backend starting — waiting for warmup"
            state.backendReadiness.activeSTTModel = ""
            backendManager.startIfNeededAsync(configuration: settings.currentBackendLaunchConfiguration())
        }

        for attempt in 0..<24 {
            guard !Task.isCancelled else { return }
            await refreshBackendReadiness()
            if state.backendReadiness.readyForDictation {
                return
            }
            if !state.backendShouldRun && !state.backendReadiness.warmupInProgress {
                return
            }
            let delay: UInt64 = attempt < 4 ? 2_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func loadWhisperKitModel() async {
        let modelsDir = ProcessInfo.processInfo.environment["VOXFLOW_MODELS_DIR"]
            ?? (ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"].map { $0 + "/models" })
            ?? Bundle.main.resourcePath.map { $0 + "/models" }
            ?? "./models"
        let modelName = "openai_whisper-small.en"
        let modelFolder = WhisperKitSTTService.resolveModelFolder(modelsDir: modelsDir, modelName: modelName)

        state.statusLine = "Loading WhisperKit model..."
        do {
            try await whisperKitService.load(modelFolder: modelFolder)
            state.backendReadiness.whisperKitReady = true
            state.statusLine = "WhisperKit ready"
        } catch {
            state.backendReadiness.whisperKitReady = false
            state.statusLine = "WhisperKit failed: \(error.localizedDescription)"
            log.error("WhisperKit load failed: \(error.localizedDescription)")
        }
    }

    func refreshReadiness() {
        Task { await refreshBackendReadiness() }
    }

    func appDidBecomeActive() {
        configureHotkeysIfNeeded()
        scheduleRuntimeWarmupIfNeeded()
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

    private func scheduleRuntimeWarmupIfNeeded() {
        guard state.backendShouldRun || state.backendReadiness.warmupInProgress || (state.sttBackend == .whisperKit && !state.backendReadiness.whisperKitReady) else {
            return
        }
        beginWarmupMonitoring()
    }

    private func refreshBackendReadiness() async {
        let startupIssue = backendManager.lastStartupFailureReason
        let backendRunning = backendManager.isRunning
        state.backendReadiness.processRunning = backendRunning

        if !backendRunning && !state.backendShouldRun && !state.backendReadiness.warmupInProgress {
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.activeSTTModel = state.sttBackend == .whisperKit ? "whisperkit (in-app)" : ""
            state.backendReadiness.statusSummary = "Backend idle — current workflow runs in app"
            return
        }

        do {
            let readiness = try await BackendAPIClient.ready()
            state.backendReadiness.readyForDictation = readiness.readyForDictation
            state.backendReadiness.warmupInProgress = false
            state.backendReadiness.readinessIssue = readiness.issues.first
            state.backendReadiness.activeSTTModel = readiness.activeSttModel
            state.backendReadiness.ollamaAvailable = readiness.ollamaAvailable
            state.backendReadiness.statusSummary = readiness.readyForDictation
                ? "Backend ready (\(readiness.activeSttModel))"
                : "Backend not ready: \(readiness.issues.first ?? "unknown issue")"
            if shouldSurfaceBackendStatusInStatusLine(),
               !readiness.readyForDictation,
               let firstIssue = readiness.issues.first {
                state.statusLine = "Backend not ready: \(firstIssue)"
            }
        } catch {
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.activeSTTModel = ""
            if let startupIssue {
                state.backendReadiness.warmupInProgress = false
                state.backendReadiness.readinessIssue = startupIssue
                state.backendReadiness.statusSummary = "Backend startup issue: \(startupIssue)"
                if shouldSurfaceBackendStatusInStatusLine() {
                    state.statusLine = "Backend startup issue: \(startupIssue)"
                }
            } else if backendRunning || state.backendReadiness.warmupInProgress {
                state.backendReadiness.warmupInProgress = true
                state.backendReadiness.readinessIssue = nil
                state.backendReadiness.statusSummary = "Backend starting — waiting for warmup"
                if shouldSurfaceBackendStatusInStatusLine() {
                    state.statusLine = "Backend starting — wait for warmup"
                }
            } else {
                state.backendReadiness.warmupInProgress = false
                state.backendReadiness.readinessIssue = "Backend offline"
                state.backendReadiness.statusSummary = "Backend offline"
                if shouldSurfaceBackendStatusInStatusLine() {
                    state.statusLine = "Backend offline. Start backend in Settings."
                }
            }
        }
    }

    private func shouldSurfaceBackendStatusInStatusLine() -> Bool {
        guard state.sessionState == .idle || state.sessionState == .onboarding else {
            return false
        }
        if state.workflowNeedsBackend {
            return true
        }
        return state.sttBackend != .whisperKit || !state.backendReadiness.whisperKitReady
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

            try cockpitHotkeyService.register(
                configuration: HotkeyConfiguration(keyCode: 9, modifiers: UInt32(optionKey) | UInt32(cmdKey)),
                onPress: {
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)
                    }
                },
                onRelease: {}
            )
            hotkeysRegistered = true
            state.errorMessage = nil
            log.info("Hotkeys registered")
        } catch {
            hotkeyService.unregister()
            fnHoldHotkeyService.unregister()
            commandHotkeyService.unregister()
            cockpitHotkeyService.unregister()
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
        selectToneStyleTask?.cancel()
        selectToneStyleTask = nil
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

        let canTranscribe = state.canUseSelectedSTTBackend
        if !canTranscribe {
            let backendReady = state.backendReadiness.readyForDictation
            let whisperReady = state.backendReadiness.whisperKitReady
            log.warning("startCapture blocked: no STT backend ready (backend=\(backendReady), whisperKit=\(whisperReady))")
            state.statusLine = state.sttBackend == .whisperKit
                ? "WhisperKit not ready — wait for model load"
                : "Backend not ready — wait for model warmup"
            return
        }

        // Some workflows still depend on backend services even when STT is local.
        if state.workflowNeedsBackend && !state.backendReadiness.readyForDictation {
            let modeName = state.workflowMode.displayName
            log.warning("startCapture blocked: \(modeName) requires backend but backend not ready")
            state.statusLine = "\(modeName) requires backend — wait for model warmup"
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
                    await self.finishCaptureAndTranscribe(commandLane: commandLane)
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
        prepareForTranscription(commandLane: commandLane)
        let sessionID = "session-\(sessionCounter)"
        let trace = CapturePipelineTraceBuilder(
            sessionID: sessionID,
            workflowMode: state.workflowMode,
            sttBackend: state.sttBackend,
            providerMode: state.providerMode,
            commandLane: commandLane
        )

        do {
            let captureFinalizeStarted = ContinuousClock.now
            guard let capturedAudio = try stopAndValidateAudio() else {
                trace.recordStage("capture_finalize", startedAt: captureFinalizeStarted, detail: state.statusLine)
                finalizeCaptureTrace(trace)
                return
            }
            trace.setAudioDuration(from: capturedAudio)
            trace.recordStage(
                "capture_finalize",
                startedAt: captureFinalizeStarted,
                detail: "samples=\(capturedAudio.pcm.count / MemoryLayout<Int16>.size)"
            )

            let transcriptionStarted = ContinuousClock.now
            let transcription = try await transcribeAudio(capturedAudio, sessionID: sessionID)
            let transcriptionDetail: String
            if state.sttBackend == .whisperKit {
                transcriptionDetail = "reported=\(transcription.processingTimeMs)ms"
            } else {
                let coldStartSuffix = (transcription.coldStart ?? false) ? ", cold_start=true" : ""
                transcriptionDetail = "server=\(transcription.processingTimeMs)ms, response=\(transcription.latencyMs)ms\(coldStartSuffix)"
            }
            trace.recordStage("stt", startedAt: transcriptionStarted, detail: transcriptionDetail)
            appendTranscriptionDiagnostics(transcription, to: trace)

            recordCaptureMetrics(
                latencyMs: transcription.latencyMs,
                commandLane: commandLane,
                onboardingCalibration: state.onboardingPhase == .calibrating
            )

            try await handleTranscriptionResult(
                transcription,
                capturedAudio: capturedAudio,
                sessionID: sessionID,
                commandLane: commandLane,
                trace: trace
            )
            finalizeCaptureTrace(trace)

        } catch {
            handleCaptureError(error)
            finalizeCaptureTrace(trace)
        }
    }

    private func prepareForTranscription(commandLane: Bool) {
        if !commandLane {
            fnTriggeredCaptureInProgress = false
            cueSoundService.playStopCue()
        }

        timer?.invalidate()
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        state.sessionState = .transcribing
        state.statusLine = commandLane ? "Interpreting command..." : "Transcribing..."
    }

    private func stopAndValidateAudio() throws -> CapturedAudio? {
        let capturedAudio = try audioCapture.stopCapture()
        // Guard: discard very short captures (< 0.3s) that cause Whisper hallucination
        let minBytes = Int(capturedAudio.sampleRate * 0.3) * MemoryLayout<Int16>.size

        if capturedAudio.pcm.count < minBytes {
            log.info("Audio too short (\(capturedAudio.pcm.count) bytes, need \(minBytes)) — discarding")
            state.sessionState = .idle
            state.statusLine = "Too short — hold longer to dictate"
            state.recordingDuration = 0
            return nil
        }

        if capturedAudio.isSilent {
            log.info("Audio is silence (RMS \(String(format: "%.4f", capturedAudio.rmsEnergy))) — discarding")
            state.sessionState = .idle
            state.statusLine = "No speech detected — try again"
            state.recordingDuration = 0
            return nil
        }
        return capturedAudio
    }

    private func transcribeAudio(_ capturedAudio: CapturedAudio, sessionID: String) async throws -> TranscribeResponse {
        if state.sttBackend == .whisperKit {
            return try await whisperKitService.transcribe(capturedAudio)
        } else {
            return try await BackendAPIClient.transcribe(
                sessionID: sessionID,
                audioPCM: capturedAudio.pcm,
                sampleRate: Int(capturedAudio.sampleRate),
                chunkIndex: 0,
                languageHint: "en"
            )
        }
    }

    private func handleTranscriptionResult(
        _ transcription: TranscribeResponse,
        capturedAudio: CapturedAudio,
        sessionID: String,
        commandLane: Bool,
        trace: CapturePipelineTraceBuilder
    ) async throws {
        let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscriptionConfidence = transcription.confidenceEstimate
        #if DEBUG
        log.info("Transcription: '\(rawText.prefix(100))' (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #else
        log.info("Transcription: \(rawText.count) chars (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #endif

        if rawText.isEmpty || rawText.hasPrefix("[transcription") {
            log.info("Empty or placeholder transcription — discarding")
            state.sessionState = .idle
            state.statusLine = rawText.isEmpty ? "No speech detected — try again" : rawText
            state.recordingDuration = 0
            return
        }

        // Discard low-confidence short text — likely silence/noise hallucinations.
        // Single-word results are checked at any duration (Whisper often hallucinates
        // a lone "hello" on long silent/noisy clips). Two-word results only on short audio.
        let wordCount = rawText.split(whereSeparator: \.isWhitespace).count
        let audioDurationSec = Double(capturedAudio.pcm.count) / (capturedAudio.sampleRate * Double(MemoryLayout<Int16>.size))
        let isShortAudio = audioDurationSec < 3.0
        let isSuspect = (wordCount == 1 && transcription.confidenceEstimate < 0.15)
            || (isShortAudio && wordCount <= 2 && transcription.confidenceEstimate < 0.08)
        if isSuspect {
            log.info("Low confidence (\(String(format: "%.2f", transcription.confidenceEstimate))) \(wordCount)-word text (duration=\(String(format: "%.1f", audioDurationSec))s) — discarding as likely hallucination")
            state.sessionState = .idle
            state.statusLine = "No speech detected — try again"
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

        try await processWorkflow(sessionID: sessionID, rawText: rawText, trace: trace)
    }

    private func appendTranscriptionDiagnostics(_ transcription: TranscribeResponse, to trace: CapturePipelineTraceBuilder) {
        guard let stageTimings = transcription.stageTimingsMs, !stageTimings.isEmpty else { return }

        let preferredOrder = [
            "request_decode",
            "model_load",
            "pcm_to_float",
            "wav_encode",
            "stt_request",
            "stt_inference",
        ]

        let orderedKeys = preferredOrder.filter { stageTimings[$0] != nil }
        let remainingKeys = stageTimings.keys
            .filter { !preferredOrder.contains($0) }
            .sorted()

        for key in orderedKeys + remainingKeys {
            guard let duration = stageTimings[key] else { continue }
            trace.appendStage(name: "stt.\(key)", durationMs: duration)
        }
    }

    private func processWorkflow(sessionID: String, rawText: String, trace: CapturePipelineTraceBuilder) async throws {
        switch state.workflowMode {
        case .translateEnToDe:
            try await processTranslation(sessionID: sessionID, rawText: rawText, trace: trace)
        case .meeting:
            try await processMeeting(sessionID: sessionID, rawText: rawText, trace: trace)
        case .dictation:
            try await processDictation(sessionID: sessionID, rawText: rawText, trace: trace)
        case .prompt:
            try await processPrompt(sessionID: sessionID, rawText: rawText, trace: trace)
        }
    }

    private func handleCaptureError(_ error: Error) {
        log.error("Transcription failed: \(error.localizedDescription)")
        state.sessionState = .error
        state.errorMessage = "Transcription failed: \(error.localizedDescription)"
        state.statusLine = "Error. Retry capture."
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
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil

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
    func insertCurrentText() { Task { await textInsertion.insertCurrentText(targetApp: capturedTargetApp) } }

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

        selectToneStyleTask?.cancel()
        selectToneStyleTask = Task { @MainActor in
            do {
                try Task.checkCancellation()
                // Local retone for WhisperKit
                if self.state.sttBackend == .whisperKit {
                    let lightText = TextCleanupService.cleanup(rawText, mode: .light, tone: tone)
                    let polishText = TextCleanupService.cleanup(rawText, mode: .polish, tone: tone)
                    try Task.checkCancellation()
                    state.transcriptCandidate = TranscriptCandidate(
                        rawText: rawText, lightText: lightText,
                        polishText: polishText, selectedMode: state.selectedMode,
                        confidence: state.transcriptCandidate?.confidence ?? 0.0
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
                try Task.checkCancellation()

                let polishText = try await BackendAPIClient.cleanup(
                    sessionID: "retone-\(sessionCounter)",
                    mode: .polish,
                    inputText: rawText,
                    toneStyle: tone,
                    providerMode: .localOnly
                ).outputText
                try Task.checkCancellation()

                state.transcriptCandidate = TranscriptCandidate(
                    rawText: rawText,
                    lightText: lightText,
                    polishText: polishText,
                    selectedMode: state.selectedMode,
                    confidence: state.transcriptCandidate?.confidence ?? 0.0
                )
                state.statusLine = "Tone: \(tone.displayName)"
            } catch {
                guard !Task.isCancelled else { return }
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

        settings.restartBackendWithCurrentConfiguration(status: state.statusLine)
        scheduleRuntimeWarmupIfNeeded()
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
    func selectTranslationProfile(_ profile: TranslationProfile) {
        settings.selectTranslationProfile(profile)
        scheduleRuntimeWarmupIfNeeded()
    }
    func selectSTTBackend(_ backend: STTBackend) {
        settings.selectSTTBackend(backend)
        scheduleRuntimeWarmupIfNeeded()
    }
    func updateLocalWhisperModel(whisperModel: String) {
        settings.updateLocalWhisperModel(whisperModel: whisperModel)
        scheduleRuntimeWarmupIfNeeded()
    }
    func selectProviderMode(_ mode: ProviderMode) {
        if mode == .localOnly {
            state.privacyPreview = nil
            privacy.clearPendingOperation()
        }
        settings.selectProviderMode(mode)
        scheduleRuntimeWarmupIfNeeded()
    }
    func updatePrivateAPIConfig(baseURL: String, model: String, apiKey: String) {
        settings.updatePrivateAPIConfig(baseURL: baseURL, model: model, apiKey: apiKey)
        scheduleRuntimeWarmupIfNeeded()
    }
    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String, ttsModel: String, ttsVoice: String) {
        settings.updateOpenAIConfig(baseURL: baseURL, apiKey: apiKey, sttModel: sttModel, ttsModel: ttsModel, ttsVoice: ttsVoice)
        scheduleRuntimeWarmupIfNeeded()
    }

    // MARK: - Benchmark Forwarding

    func runTranslationBenchmark() async {
        await benchmark.runTranslationBenchmark()
        settings.restartBackendWithCurrentConfiguration(status: state.statusLine)
        scheduleRuntimeWarmupIfNeeded()
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

    func handleAutomationCommand(
        _ command: AppAutomationCommand,
        openWindow: (String) -> Void
    ) {
        log.info("Automation command received: \(String(describing: command), privacy: .public)")

        switch command {
        case .openWindow(let target):
            switch target {
            case .main:
                showMainWindow()
            case .dashboard:
                openWindow("dashboard")
            case .setup:
                openWindow("setup")
            case .settings:
                openSettings()
            }
        case .selectWorkflow(let mode, let enableIfNeeded):
            if enableIfNeeded {
                enableWorkflowModeIfNeeded(mode)
            }
            selectWorkflowMode(mode)
        case .backend(let action):
            switch action {
            case .start:
                state.statusLine = "Backend start requested"
                startBackend()
            case .stop:
                stopBackend()
            case .recheck:
                state.statusLine = "Refreshing backend readiness"
                refreshReadiness()
            }
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
        state.backendReadiness.processRunning = true
        state.backendReadiness.warmupInProgress = true
        state.backendReadiness.readyForDictation = false
        state.backendReadiness.readinessIssue = nil
        state.backendReadiness.statusSummary = "Backend starting — waiting for warmup"
        backendManager.startIfNeededAsync(configuration: settings.currentBackendLaunchConfiguration())
        beginWarmupMonitoring()
    }

    func stopBackend() {
        warmupTask?.cancel()
        backendManager.stopAsync()
        state.backendReadiness.processRunning = false
        state.backendReadiness.warmupInProgress = false
        state.backendReadiness.readyForDictation = false
        state.backendReadiness.activeSTTModel = ""
        state.backendReadiness.readinessIssue = "Backend stopped"
        state.backendReadiness.statusSummary = "Backend stopped"
    }

    private func enableWorkflowModeIfNeeded(_ mode: WorkflowMode) {
        switch mode {
        case .dictation:
            return
        case .translateEnToDe:
            if !state.translationModeEnabled {
                settings.setTranslationModeEnabled(true)
            }
        case .meeting:
            if !state.meetingModeEnabled {
                settings.setMeetingModeEnabled(true)
            }
        case .prompt:
            if !state.promptModeEnabled {
                settings.setPromptModeEnabled(true)
            }
        }
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

    private func finalizeCaptureTrace(_ trace: CapturePipelineTraceBuilder) {
        let snapshot = trace.build(statusLine: state.statusLine, sessionState: state.sessionState)
        state.lastPipelineTrace = snapshot
        let audioDetail = snapshot.audioDurationMs.map { ", audio=\($0)ms" } ?? ""
        let modeDetail = snapshot.commandLane ? ", commandLane=true" : ""
        log.info(
            "Capture trace [\(snapshot.sessionID)] workflow=\(snapshot.workflowMode.rawValue), stt=\(snapshot.sttBackend.rawValue), provider=\(snapshot.providerMode.rawValue)\(modeDetail), total=\(snapshot.totalDurationMs)ms\(audioDetail), sessionState=\(snapshot.sessionState.rawValue), status='\(snapshot.statusLine)' :: \(snapshot.stageSummary)"
        )
    }

    func insertRecentDictation(_ candidate: TranscriptCandidate) {
        let text = candidate.text(for: candidate.selectedMode)
        let appLabel = state.focusTarget.appName ?? "app"
        Task {
            if await textInsertion.insertText(text, statusSuffix: "Re-inserted — \(appLabel)") {
                state.sessionState = .idle
            }
        }
    }

    private func resolveEffectiveProfile() -> AppProfile? {
        let bundleID = capturedTargetApp?.bundleIdentifier
            ?? state.focusTarget.bundleID
            ?? ""
        return state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
    }

    private func processWithPrivacyGate(
        sessionID: String,
        operation: PrivacyOperationKind,
        inputText: String,
        trace: CapturePipelineTraceBuilder,
        process: @escaping @MainActor (ProviderMode, String?, Bool) async throws -> Void
    ) async throws {
        if state.providerMode == .privateAPI {
            let previewStarted = ContinuousClock.now
            try await privacy.requestPrivacyPreview(
                sessionID: sessionID,
                operation: operation,
                inputText: inputText
            ) { consentToken, allowRaw in
                try await process(.privateAPI, consentToken, allowRaw)
            }
            trace.recordStage("privacy_preview", startedAt: previewStarted)
            return
        }
        try await process(.localOnly, nil, false)
        state.recordingDuration = 0
    }

    private func processDictation(
        sessionID: String,
        rawText: String,
        trace: CapturePipelineTraceBuilder
    ) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .cleanup, inputText: rawText, trace: trace
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let profile = self.resolveEffectiveProfile()
            let effectiveTone = profile?.tone ?? self.state.toneStyle
            let effectiveInsert = profile?.insertBehavior ?? self.state.insertBehavior

            let request = DictationWorkflowRequest(
                sessionID: sessionID,
                rawText: rawText,
                providerMode: providerMode,
                consentToken: consentToken,
                allowRaw: allowRaw,
                toneStyle: effectiveTone,
                insertBehavior: effectiveInsert,
                sttBackend: self.state.sttBackend,
                lastTranscriptionConfidence: self.lastTranscriptionConfidence,
                targetApp: self.capturedTargetApp
            )

            try await self.dictationWorkflow.processDictation(request) { name, startedAt, detail in
                trace.recordStage(name, startedAt: startedAt, detail: detail)
            }
        }
    }

    private func processPrompt(
        sessionID: String,
        rawText: String,
        trace: CapturePipelineTraceBuilder
    ) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .cleanup, inputText: rawText, trace: trace
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let profile = self.resolveEffectiveProfile()
            let request = PromptWorkflowRequest(
                sessionID: sessionID,
                rawText: rawText,
                providerMode: providerMode,
                consentToken: consentToken,
                allowRaw: allowRaw,
                toneStyle: profile?.tone ?? self.state.toneStyle,
                insertBehavior: profile?.insertBehavior ?? self.state.insertBehavior,
                sttBackend: self.state.sttBackend,
                targetApp: self.capturedTargetApp
            )
            try await self.promptWorkflow.processPrompt(request) { name, startedAt, detail in
                trace.recordStage(name, startedAt: startedAt, detail: detail)
            }
        }
    }

    private func processTranslation(
        sessionID: String,
        rawText: String,
        trace: CapturePipelineTraceBuilder
    ) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .translate, inputText: rawText, trace: trace
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let request = TranslationWorkflowRequest(
                sessionID: sessionID,
                rawText: rawText,
                sourceLanguage: "en",
                targetLanguage: "de",
                providerMode: providerMode,
                consentToken: consentToken,
                allowRaw: allowRaw
            )
            try await self.translationWorkflow.processTranslation(request) { name, startedAt, detail in
                trace.recordStage(name, startedAt: startedAt, detail: detail)
            }
        }
    }

    private func processMeeting(
        sessionID: String,
        rawText: String,
        trace: CapturePipelineTraceBuilder
    ) async throws {
        try await processWithPrivacyGate(
            sessionID: sessionID, operation: .meeting, inputText: rawText, trace: trace
        ) { [weak self] providerMode, consentToken, allowRaw in
            guard let self else { return }
            let profile = self.resolveEffectiveProfile()
            let effectiveTone = profile?.tone ?? self.state.toneStyle
            let summaryStarted = ContinuousClock.now
            let response = try await BackendAPIClient.meetingSummarize(
                sessionID: sessionID, transcript: rawText,
                toneStyle: effectiveTone, providerMode: providerMode,
                consentToken: consentToken, allowRaw: allowRaw
            )
            trace.recordStage("meeting_summary", startedAt: summaryStarted, detail: "provider=\(providerMode.rawValue)")
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

        // Observe sessionState and commandLane for icon updates + auto-open on review
        state.$sessionState
            .combineLatest(state.$isCommandLaneActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] newState, _ in
                guard let self else { return }
                self.menuBarPanel?.updateIcon(systemName: self.iconName(for: self.state))
                // Auto-open panel when entering review state so user sees the review card
                if newState == .review, !(self.menuBarPanel?.isOpen ?? true) {
                    self.menuBarPanel?.open()
                }
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
            Task { @MainActor [weak self] in
                self?.checkAndRevertActivationPolicy()
            }
        }
    }

    private func handleAppDidFinishLaunching() {
        didFinishLaunching = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await MainActor.run {
                guard let self, self.menuBarPanel == nil else { return }
                self.setupMenuBarPanel()
                self.log.info("Menu bar panel setup (cold start fallback)")
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
            if menuBarPanel == nil && didFinishLaunching {
                // First revert after launch — create the panel now that
                // the activation policy has settled to .accessory.
                setupMenuBarPanel()
                log.info("Menu bar panel setup (after policy revert)")
            } else {
                // Re-register status item — the .regular -> .accessory round-trip
                // may have invalidated its menu bar slot.
                menuBarPanel?.refreshStatusItem()
            }
            if let observer = windowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                windowCloseObserver = nil
            }
        }
    }

    /// Called from AppDelegate.applicationWillTerminate to cleanly stop the backend.
    func shutdownBackend() {
        backendManager.stop()
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
