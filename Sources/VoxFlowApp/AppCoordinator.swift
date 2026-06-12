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
    // R4.1: floating recording pill — feedback lives on screen, not in the
    // menu bar panel, while the user dictates into another app.
    private lazy var recordingOverlay = RecordingOverlayController(state: state) { [weak self] in
        self?.cancelActiveCapture()
    }

    private(set) var settings: SettingsCoordinating!
    private(set) lazy var onboarding: OnboardingCoordinating = OnboardingCoordinator(state: state)
    private(set) lazy var insertionAudit = InsertionAuditLog()
    // R5.4: experimental assistant handoff — transcript via STDIN to a
    // user-configured CLI, preview-gated, never auto-executed.
    private(set) lazy var assistantHandoff = AssistantHandoffService(
        isEnabled: { [weak self] in self?.state.assistantHandoffEnabled ?? false },
        command: { [weak self] in self?.state.assistantHandoffCommand ?? "" }
    )
    private(set) lazy var textInsertion: TextInsertionCoordinating = TextInsertionCoordinator(state: state, insertService: insertService, audit: insertionAudit)
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
        textInsertionCoordinator: textInsertion as? TextInsertionCoordinator,
        snippetStore: cockpitSnippets
    )
    private(set) lazy var cockpitDictionary: DictionaryStore = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let base = appSupport.appendingPathComponent("VoxFlow", isDirectory: true)
        return DictionaryStore(fileURL: base.appendingPathComponent("dictionary.json"))
    }()
    private(set) lazy var cockpitSnippets: SnippetStore = SnippetStore(fileURL: SnippetStore.defaultFileURL)
    // BYOM (R3.6): providers.json store — shared file the backend registry
    // reads at launch. Mutations are followed by a backend restart so chains
    // take effect (SettingsView calls applyProviderChanges()).
    private(set) lazy var providerConfig: ProviderConfigStore = ProviderConfigStore()
    // Cockpit Layer 1 — Phase E workflow chains. Store mirrors cockpitSnippets;
    // the executor reuses the existing smart-action + text-insertion seams and
    // sources its frozen target from the cockpit session (the app the user was
    // dictating into), not capturedTargetApp.
    private(set) lazy var cockpitChains: ChainStore = ChainStore(fileURL: ChainStore.defaultFileURL)
    // The executor does NOT participate in cockpit undo, so it gets its OWN
    // SmartActionService instance. Sharing `cockpitActionService` would push a
    // chain's `.action` step onto the cockpit's per-instance undo history while
    // the output is inserted into the frozen target (never the cockpit
    // transcript) — a subsequent cockpit ⌘Z would then pop that entry and
    // overwrite the visible transcript with a value the user never saw applied.
    private lazy var chainActionService: SmartActionService = SmartActionService(backend: BackendAPISmartActionAdapter())
    private(set) lazy var chainExecutor: ChainExecutor = ChainExecutor(
        actionService: chainActionService,
        textInsertion: textInsertion,
        currentTranscript: { [weak self] in self?.cockpitSessionService.currentSession?.transcript },
        frozenTarget: { [weak self] in
            self?.cockpitSessionService.currentSession?.targetApp?.processIdentifier
                .flatMap { NSRunningApplication(processIdentifier: $0) }
        },
        performAppStep: { [weak self] step in
            self?.performChainAppStep(step) ?? false
        })
    private(set) lazy var cockpitCapture: CockpitCaptureCoordinator = CockpitCaptureCoordinator(
        capture: AudioCaptureService(),
        transcriber: whisperKitService,
        session: cockpitSessionService,
        dictionary: cockpitDictionary,
        audit: insertionAudit
    )

    private var timer: Timer?
    private var captureTimeoutTimer: Timer?
    private var sessionCounter: Int = 0
    private var hotkeysRegistered = false
    private var didFinishLaunching = false
    private var fnTriggeredCaptureInProgress = false
    private var isRunningChain = false
    private var capturedTargetApp: NSRunningApplication?
    private var lastTranscriptionConfidence: Double = 0.0
    /// In-flight transcription pipeline, cancellable from cancelActiveCapture
    /// while the session is .transcribing.
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private static let maxCaptureDuration: TimeInterval = 60
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
        settingsCoordinator.providerKeysResolver = { [weak self] in
            self?.providerConfig.keychainBackedKeys() ?? [:]
        }
        self.settings = settingsCoordinator
        startFocusMonitoring()
        beginWarmupMonitoring()
        state.$sessionState
            .removeDuplicates()
            .sink { [weak self] newState in
                self?.recordingOverlay.sessionStateChanged(newState)
                if newState == .idle {
                    self?.capturedTargetApp = nil
                    self?.lastTranscriptionConfidence = 0.0
                    self?.state.recordingDuration = 0
                    self?.focusMonitor.unfreeze()
                }
            }
            .store(in: &cancellables)

        cockpit.onHandoffRequested = { [weak self] in self?.requestAssistantHandoff() }

        // Stale-backend hardening (2026-06-12): an open cockpit makes
        // backendShouldRun true (smart actions need the backend); spawn +
        // warmup-poll it through the existing machinery.
        cockpit.onCockpitOpened = { [weak self] in self?.scheduleRuntimeWarmupIfNeeded() }

        // R5.6: cockpit review can trigger protocols (gated inside the
        // coordinator on state.protocolCommandsEnabled + strict grammar).
        cockpit.chainProvider = { [weak self] name in self?.cockpitChains.chain(named: name) }
        cockpit.onProtocolTriggered = { [weak self] chain in
            Task { await self?.runChain(chain) }
        }

        // R5.1: the personal dictionary biases WhisperKit recognition.
        // Feed terms now and on every dictionary change.
        whisperKitService.vocabularyTerms = VocabularyBiasing.terms(from: cockpitDictionary.entries)
        cockpitDictionary.$entries
            .sink { [weak self] entries in
                self?.whisperKitService.vocabularyTerms = VocabularyBiasing.terms(from: entries)
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

    /// Run a workflow chain (Phase E). Invoked from the cockpit ⌘K palette by
    /// name. Delegates to the executor and surfaces the outcome on the status
    /// line so failures at `.capture`/`.action` (which never touch the insert
    /// coordinator) aren't silent. A single-flight guard prevents two rapid
    /// ⌘K dispatches from interleaving duplicate inserts into the target app
    /// (MainActor serialization makes the flag race-free).
    func runChain(_ chain: WorkflowChain) async {
        guard !isRunningChain else { return }
        isRunningChain = true
        defer { isRunningChain = false }

        let result = await chainExecutor.run(chain)
        if result.error == nil {
            state.statusLine = "Chain '\(chain.name)' complete"
        } else {
            let stepNumber = result.failedStepIndex.map { $0 + 1 } ?? 0
            state.statusLine = "Chain '\(chain.name)' failed at step \(stepNumber)"
        }
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

    /// Dev escape hatch for the stale-listener checks: pair the app with a
    /// manually launched backend (`run_backend.sh`) instead of killing it.
    /// Also forced on under XCTest: AppCoordinator is a singleton whose init
    /// starts warmup, so any test touching `.shared` would otherwise probe
    /// the REAL port 8765 with a stamp no live backend can match — and
    /// SIGTERM the developer's running backend (the exact test-side-effect
    /// class behind the ghost-hello and squatter incidents).
    private static let adoptForeignBackendOverride =
        ProcessInfo.processInfo.environment["VOXFLOW_ADOPT_FOREIGN_BACKEND"] == "1"
        || NSClassFromString("XCTestCase") != nil

    /// Launch-time identity probe (stale-backend hardening, 2026-06-12).
    /// The idle early-return below is the ONLY readiness path in WhisperKit
    /// dictation mode, so a squatter on our port must be caught here — the
    /// R4.7 in-poll check never executes while `backendShouldRun` is false,
    /// yet smart actions still POST to whatever listens on 8765.
    /// Returns true when a stale listener was terminated.
    private func reapStaleIdleListenerIfNeeded() async -> Bool {
        // The override must gate BOTH kill paths below (identity terminate
        // and PID-file reap), so short-circuit before probing at all.
        guard !Self.adoptForeignBackendOverride else { return false }
        var listenerResponded = false
        var reportedStamp: String?
        do {
            let readiness = try await BackendAPIClient.readyProbe()
            listenerResponded = true
            reportedStamp = readiness.instanceStamp
        } catch {
            // Connection refused / timeout / non-JSON responder: nothing we
            // recognise is listening. A wedged or draining stray from a
            // crashed run can still hold the port though — reap it via the
            // PID file (self-guarding: no-op unless the file records a live
            // child we previously spawned; atexit misses SIGKILL/crash).
            BackendProcessManager.killStaleBackend()
        }
        guard BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: listenerResponded,
            reportedStamp: reportedStamp,
            expectedStamp: backendManager.instanceStamp,
            adoptForeignOverride: Self.adoptForeignBackendOverride
        ) else { return false }
        log.warning("Stale backend on port 8765 (missing/foreign stamp, idle mode) — terminating")
        backendManager.terminateForeignListenerAsync()
        return true
    }

    private func refreshBackendReadiness() async {
        let startupIssue = backendManager.lastStartupFailureReason
        let backendRunning = backendManager.isRunning
        state.backendReadiness.processRunning = backendRunning

        if !backendRunning && !state.backendShouldRun && !state.backendReadiness.warmupInProgress {
            let reaped = await reapStaleIdleListenerIfNeeded()
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.activeSTTModel = state.sttBackend == .whisperKit ? "whisperkit (in-app)" : ""
            state.backendReadiness.statusSummary = reaped
                ? "Stale backend on port 8765 removed — backend idle"
                : "Backend idle — current workflow runs in app"
            return
        }

        do {
            let readiness = try await BackendAPIClient.ready()
            // R4.7: a healthy port answered by a backend we didn't launch is
            // stale/foreign — replace it instead of silently trusting it.
            if !Self.adoptForeignBackendOverride,
               BackendProcessManager.isForeignBackend(
                reportedStamp: readiness.instanceStamp,
                expectedStamp: backendManager.instanceStamp,
                managerOwnsProcess: backendManager.isRunning
            ) {
                log.warning("Foreign/stale backend on port 8765 (stamp mismatch) — terminating")
                backendManager.terminateForeignListenerAsync()
                state.backendReadiness.readyForDictation = false
                state.backendReadiness.statusSummary = "Stale backend replaced — restarting"
                if state.backendShouldRun {
                    backendManager.startIfNeededAsync(configuration: settings.currentBackendLaunchConfiguration())
                }
                return
            }
            state.backendReadiness.readyForDictation = readiness.readyForDictation
            state.backendReadiness.warmupInProgress = false
            state.backendReadiness.readinessIssue = readiness.issues.first
            state.backendReadiness.activeSTTModel = readiness.activeSttModel
            state.backendReadiness.ollamaAvailable = readiness.ollamaAvailable
            state.backendReadiness.activePolishProvider = readiness.activePolishProvider
            state.backendReadiness.activePolishModel = readiness.activePolishModel
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

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runTranscriptionPipeline(sessionID: sessionID, commandLane: commandLane, trace: trace)
        }
        transcriptionTask = task
        await task.value
        if transcriptionTask == task { transcriptionTask = nil }
    }

    private func runTranscriptionPipeline(
        sessionID: String,
        commandLane: Bool,
        trace: CapturePipelineTraceBuilder
    ) async {
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
            try Task.checkCancellation()
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
        // Guard: discard very short captures that cause Whisper hallucination
        let minBytes = Int(capturedAudio.sampleRate * TranscriptGate.minAudioSeconds) * MemoryLayout<Int16>.size

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
        // R5.1: dictionary post-correction now applies on the quick path too
        // (it was cockpit-only). Biasing improves recognition; this catches
        // what biasing missed.
        let rawText = cockpitDictionary.apply(
            to: transcription.text.trimmingCharacters(in: .whitespacesAndNewlines))
        lastTranscriptionConfidence = transcription.confidenceEstimate
        #if DEBUG
        log.info("Transcription: '\(rawText.prefix(100))' (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #else
        log.info("Transcription: \(rawText.count) chars (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #endif

        let audioDurationSec = Double(capturedAudio.pcm.count) / (capturedAudio.sampleRate * Double(MemoryLayout<Int16>.size))

        // Single ingress gate: empty/placeholder, hallucination filter, and the
        // low-confidence rules live in TranscriptGate so every transcript path
        // (quick dictation, cockpit chunks, command lane) applies them identically.
        if case .rejected(let reason) = TranscriptGate.evaluate(
            text: rawText,
            confidence: transcription.confidenceEstimate,
            audioDurationSeconds: audioDurationSec
        ) {
            log.info("TranscriptGate rejected transcript (\(reason), confidence=\(String(format: "%.2f", transcription.confidenceEstimate)), duration=\(String(format: "%.1f", audioDurationSec))s) — discarding")
            insertionAudit.recordRejection(
                text: rawText,
                reason: reason,
                confidence: transcription.confidenceEstimate,
                durationSeconds: audioDurationSec,
                source: commandLane ? "command_lane" : "quick_dictation"
            )
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

        // Personal voice snippets (quick-dictation surface). A snippet is verbatim
        // local user text: insert the expansion into the frozen target and short-
        // circuit before cleanup/polish/privacy-gate — it must NOT be polished or
        // sent through the provider. `.snippets` is read live (on the main actor)
        // so Settings edits take effect immediately; reserved/action-word
        // precedence is guaranteed by resolveSnippet.
        if let snippet = VoiceCommandRouter.resolveSnippet(
            rawText, snippets: cockpitSnippets.snippets, context: .quickOnly) {
            let appLabel = state.focusTarget.appName ?? "app"
            // insertText sets the status line in both cases — success suffix on
            // success, "Auto-insert failed — copied to clipboard" on failure (it
            // also copies to clipboard). Either way the snippet path returns to
            // .idle: no TranscriptCandidate is built, so .review would show an
            // empty, unactionable card. Don't branch sessionState on the result.
            _ = await textInsertion.insertText(
                snippet.text,
                statusSuffix: "Snippet '\(snippet.keyword)' inserted — \(appLabel)",
                targetApp: capturedTargetApp
            )
            state.recordingDuration = 0
            state.sessionState = .idle
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
        if error is CancellationError {
            log.info("Transcription pipeline canceled by user")
            return
        }
        if let captureError = error as? AudioCaptureError, captureError == .deviceChanged {
            log.warning("Capture invalidated by audio device change")
            state.setIdle()
            state.recordingDuration = 0
            state.statusLine = "Audio device changed — try again"
            return
        }
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

        if state.sessionState == .transcribing {
            transcriptionTask?.cancel()
            transcriptionTask = nil
            state.isCommandLaneActive = false
            fnTriggeredCaptureInProgress = false
            state.setIdle()
            capturedTargetApp = nil
            state.recordingDuration = 0
            state.statusLine = "Transcription canceled"
            return
        }

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
    func updateOpenAIConfig(baseURL: String, apiKey: String, sttModel: String) {
        settings.updateOpenAIConfig(baseURL: baseURL, apiKey: apiKey, sttModel: sttModel)
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

    // MARK: - App-lifetime window-open routing

    private var windowOpenHandler: ((String) -> Void)?
    private var windowNotificationTokens: [NSObjectProtocol] = []

    /// Bridges the window-open notifications (⌥⌘V hotkey, menu-panel
    /// buttons, voice commands, protocol `.openWindow` steps) to SwiftUI's
    /// `openWindow`. Installed once from the App scene's `.task` and
    /// retained for the app's lifetime — the original view-bound
    /// `.onReceive` listeners lived on WelcomeView, so closing the Welcome
    /// window silently killed the cockpit hotkey (2026-06-12 user report).
    func installWindowOpenHandler(_ handler: @escaping (String) -> Void) {
        windowOpenHandler = handler
        guard windowNotificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        // queue nil → blocks run synchronously on the posting thread; every
        // post site is @MainActor (hotkey/voice/protocol/UI), so the
        // assumeIsolated hop is sound.
        windowNotificationTokens.append(center.addObserver(forName: .voxflowOpenCockpit, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let coordinator = AppCoordinator.shared
                coordinator.cockpit.open()
                coordinator.windowOpenHandler?("cockpit")
            }
        })
        windowNotificationTokens.append(center.addObserver(forName: .voxflowOpenDashboard, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                AppCoordinator.shared.windowOpenHandler?("dashboard")
            }
        })
        windowNotificationTokens.append(center.addObserver(forName: .voxflowOpenSetup, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                AppCoordinator.shared.windowOpenHandler?("setup")
            }
        })
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
            case .cockpit:
                cockpit.open()
                openWindow("cockpit")
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
            let host = NSHostingController(rootView: WelcomeView(coordinator: self, state: state))
            let window = NSWindow(contentViewController: host)
            window.identifier = mainWindowIdentifier
            window.title = "VoxFlow"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 540))
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
        // Resolve the ORIGINAL capture target stored on the candidate —
        // resolving frontmost at click time targets VoxFlow's own panel
        // (audit S7). If the app has quit, fall back to the focus snapshot
        // path inside insertText.
        let originalTarget = candidate.targetProcessIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        let appLabel = originalTarget?.localizedName ?? state.focusTarget.appName ?? "app"
        Task {
            if await textInsertion.insertText(text, statusSuffix: "Re-inserted — \(appLabel)", targetApp: originalTarget) {
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
        case .openCockpit:
            NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)
            state.statusLine = "Cockpit opened"
        case .openDashboard:
            NotificationCenter.default.post(name: .voxflowOpenDashboard, object: nil)
            state.statusLine = "Dashboard opened"
        case .runProtocol(let name):
            runProtocolCommand(named: name)
        }

        if state.sessionState == .transcribing {
            state.sessionState = .idle
        }
    }

    /// R5.6 — voice-triggered protocols. Defense in depth on top of the
    /// strict full-utterance grammar: the feature is off by default, and a
    /// low-confidence transcription never fires a macro (the ghost-hello
    /// lesson applied forward — hallucinated audio must not run automations).
    // MARK: - Assistant handoff (R5.4)

    /// Stage the payload for explicit approval — the preview card is the
    /// gate; nothing leaves the app until confirmAssistantHandoff().
    func requestAssistantHandoff() {
        guard state.assistantHandoffEnabled else {
            state.statusLine = "Assistant handoff is disabled (Settings ▸ Advanced)"
            return
        }
        guard let transcript = cockpitSessionService.currentSession?.transcript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.statusLine = "Nothing to hand off — transcript is empty"
            return
        }
        state.handoffPreview = transcript
    }

    func confirmAssistantHandoff() {
        guard let payload = state.handoffPreview else { return }
        state.handoffPreview = nil
        state.handoffInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let result = await self.assistantHandoff.run(transcript: payload)
            self.state.handoffInFlight = false
            switch result {
            case .success(let output):
                self.state.handoffResult = output
                self.state.statusLine = "Assistant responded"
            case .failure(let error):
                self.state.statusLine = "Handoff failed: \(String(describing: error))"
            }
        }
    }

    func dismissAssistantHandoff() {
        state.handoffPreview = nil
        state.handoffResult = nil
    }

    /// R5.6: app-level chain steps. Returns false (stopping the chain) for
    /// unknown values so a typo'd protocol fails loudly instead of half-running.
    private func performChainAppStep(_ step: ChainStep) -> Bool {
        switch step {
        case .setMode(let mode):
            guard let workflowMode = WorkflowMode(rawValue: mode) else { return false }
            selectWorkflowMode(workflowMode)
            return true
        case .setTone(let tone):
            guard let toneStyle = ToneStyle(rawValue: tone) else { return false }
            selectToneStyle(toneStyle)
            return true
        case .openWindow(let window):
            switch window {
            case "cockpit": NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)
            case "dashboard": NotificationCenter.default.post(name: .voxflowOpenDashboard, object: nil)
            case "setup": NotificationCenter.default.post(name: .voxflowOpenSetup, object: nil)
            default: return false
            }
            return true
        default:
            return false
        }
    }

    private func runProtocolCommand(named name: String) {
        guard state.protocolCommandsEnabled else {
            state.statusLine = "Protocol commands are disabled (Settings ▸ Advanced)"
            return
        }
        guard lastTranscriptionConfidence >= 0.3 else {
            log.warning("Protocol trigger '\(name)' rejected: confidence \(self.lastTranscriptionConfidence) below floor")
            state.statusLine = "Protocol not run — low transcription confidence"
            return
        }
        guard let chain = cockpitChains.chain(named: name) else {
            state.statusLine = "No protocol named '\(name)'"
            return
        }
        state.statusLine = "Running protocol: \(chain.name)"
        Task { await runChain(chain) }
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

        menuBarPanel = MenuBarPanelController(content: panelContent)
        menuBarPanel?.updateIcon(state: Self.menuBarIconState(for: state.sessionState, commandLane: state.isCommandLaneActive))

        // Observe sessionState and commandLane for icon updates + auto-open on review
        state.$sessionState
            .combineLatest(state.$isCommandLaneActive)
            .receive(on: RunLoop.main)
            .sink { [weak self] newState, _ in
                guard let self else { return }
                self.menuBarPanel?.updateIcon(state: Self.menuBarIconState(for: self.state.sessionState, commandLane: self.state.isCommandLaneActive))
                // Auto-open panel when entering review state so user sees the review card
                if newState == .review, !(self.menuBarPanel?.isOpen ?? true) {
                    self.menuBarPanel?.open()
                }
            }
            .store(in: &cancellables)
    }

    static func menuBarIconState(for sessionState: SessionState, commandLane: Bool) -> MenuBarIconState {
        if commandLane { return .symbol("terminal.fill") }
        switch sessionState {
        case .idle: return .idle
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .review: return .symbol("checkmark.bubble.fill")
        case .inserting: return .symbol("square.and.arrow.down.fill")
        case .onboarding: return .symbol("sparkles")
        case .error: return .symbol("exclamationmark.triangle.fill")
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
