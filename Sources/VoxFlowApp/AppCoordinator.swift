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
        audioDurationMs = Int(audio.durationSeconds * 1000.0)
    }

    /// Pipeline origin for total-latency receipts (session 32).
    var startedAt: ContinuousClock.Instant { started }

    func durationMs(of stageName: String) -> Int? {
        stageTimings.first { $0.name == stageName }?.durationMs
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
    /// Read-only receipts view for the pipeline viewer (palette + dashboard).
    private(set) lazy var receiptStore = InsertionReceiptStore()
    /// Bounded WAV ring for rejected captures — the audio is the evidence the
    /// empty-decode investigation was missing, and the user's lost dictation
    /// (session 29). VOXFLOW_KEEP_REJECTED_AUDIO=0 disables.
    private lazy var rejectedAudio = RejectedAudioStore()
    // R5.4: experimental assistant handoff — transcript via STDIN to a
    // user-configured CLI, preview-gated, never auto-executed.
    private(set) lazy var assistantHandoff = AssistantHandoffService(
        isEnabled: { [weak self] in self?.state.assistantHandoffEnabled ?? false },
        command: { [weak self] in self?.state.assistantHandoffCommand ?? "" }
    )
    /// In-flight handoff, so a new run (or a dismiss) cancels the previous one
    /// instead of orphaning its child process.
    private var handoffTask: Task<Void, Never>?
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
    private(set) lazy var skillProfiles = SkillProfileStore()
    private(set) lazy var computerActionSettings = ComputerActionSettings()
    private lazy var computerActions = ComputerActionService(
        preparer: PythonComputerActionPreparer(), bridge: NativeComputerActionBridge())
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
        audit: insertionAudit,
        rejectedAudio: rejectedAudio,
        // Same first-buffer cue gating as the palette path — ⌘R otherwise
        // invites speech ~150 ms before the engine delivers, clipping the
        // first word of the session.
        onCaptureLive: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, case .recording = self.cockpitSessionService.state else { return }
                self.cueSoundService.playStartCue()
            }
        }
    )

    private var timer: Timer?
    private var captureTimeoutTimer: Timer?
    /// Surfaces the start-but-no-buffers failure mode the buffer-gated cue
    /// would otherwise hide (see startCapture).
    private let captureLiveWatchdog = CaptureLiveWatchdog()
    /// Receipts show first-buffer latency around 150 ms on a cold engine —
    /// 3 s is a 20x margin before declaring the input device dead.
    static let captureLiveStallTimeout: TimeInterval = 3.0
    private var sessionCounter: Int = 0
    private var hotkeysRegistered = false
    private var didFinishLaunching = false
    private var fnTriggeredCaptureInProgress = false
    private var isRunningChain = false
    private var capturedTargetApp: NSRunningApplication?
    private var capturedSkillMatcher: SpokenSkillMatcher?
    private var capturedVoiceActions: CapturedVoiceActions?
    private var capturedAutoSubmitMode: AutoSubmitMode = .off
    private var capturedInsertionFocus: CapturedInsertionFocus?
    private var lastTranscriptionConfidence: Double = 0.0
    /// Audio stats of the last decoded capture (true input level, pre-gain),
    /// threaded onto the workflow request → candidate → insert receipt so
    /// partial decodes are detectable on successful inserts (session 29).
    private var lastCaptureAudioStats:
        (audioSeconds: Double, rmsEnergy: Double, peakAmplitude: Double?, tailGapSeconds: Double?)?
    /// Wall-clock of the last decode, to record idle gap on rejects — tests the
    /// "healthy-level miss after the pipeline's been idle" (cold) hypothesis.
    private var lastDecodeAt: Date?
    /// In-flight transcription pipeline, cancellable from cancelActiveCapture
    /// while the session is .transcribing.
    private var transcriptionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private static let maxCaptureDuration: TimeInterval = 60
    /// Mid-capture buffer-stall cutoff: CoreAudio delivers ~12 buffers/s, so
    /// 2 s of nothing means the device stopped, not that the user paused.
    private static let midCaptureStallTimeout: TimeInterval = 2.0
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
                    self?.capturedSkillMatcher = nil
                    self?.capturedVoiceActions = nil
                    self?.capturedAutoSubmitMode = .off
                    self?.capturedInsertionFocus = nil
                    self?.lastTranscriptionConfidence = 0.0
                    self?.state.recordingDuration = 0
                    self?.focusMonitor.unfreeze()
                }
            }
            .store(in: &cancellables)

        Self.observeSkillProfileChanges(in: skillProfiles,
            capturedPermission: { [weak self] in self?.capturedVoiceActions },
            revokeSubmission: { [weak self] in self?.capturedInsertionFocus?.revokeSubmission() })
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
        // Spawn the backend FIRST — it is independent of WhisperKit STT, and the
        // model load below can take tens of seconds; gating the spawn on it
        // leaves the backend cold (first dictation on the regex floor) for the
        // whole load. startIfNeededAsync is fire-and-forget, so it survives this
        // task being cancelled and restarted by a later warmup trigger.
        if state.backendShouldRun && !backendManager.isRunning {
            state.backendReadiness.processRunning = true
            state.backendReadiness.warmupInProgress = true
            state.backendReadiness.readyForDictation = false
            state.backendReadiness.readinessIssue = nil
            state.backendReadiness.statusSummary = "Backend starting — waiting for warmup"
            state.backendReadiness.activeSTTModel = ""
            backendManager.startIfNeededAsync(configuration: settings.currentBackendLaunchConfiguration())
        }

        if state.sttBackend == .whisperKit {
            await loadWhisperKitModel()
        }

        let shouldPollBackend = state.backendShouldRun || state.backendReadiness.warmupInProgress
        guard shouldPollBackend else {
            await refreshBackendReadiness()
            return
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
        guard state.wantsRuntimeWarmup else { return }
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
        log.warning("Stale backend on port \(BackendEndpoint.resolved().port) (missing/foreign stamp, idle mode) — terminating")
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
                ? "Stale backend on port \(BackendEndpoint.resolved().port) removed — backend idle"
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
                log.warning("Foreign/stale backend on port \(BackendEndpoint.resolved().port) (stamp mismatch) — terminating")
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

    /// Fn pressed while the previous capture is still transcribing: queue a
    /// restart instead of dropping the press. The old drop stranded the user
    /// — fn held, speaking, no capture, and the eventual release a no-op —
    /// losing the remainder of the utterance (session 29). The queued press
    /// fires the moment the pipeline settles (WhisperKit p50 ~0.7 s), and is
    /// cleared if fn comes up first.
    private var pendingFnCaptureRestart = false

    private func handleFnHoldPress() {
        let wasTranscribing = state.sessionState == .transcribing
        startCapture()
        fnTriggeredCaptureInProgress = state.sessionState == .recording
        if wasTranscribing, !fnTriggeredCaptureInProgress {
            pendingFnCaptureRestart = true
            log.info("Fn press during transcription — queued capture restart")
        }
    }

    private func handleFnHoldRelease() async {
        // Fn came up: whatever was queued is moot.
        pendingFnCaptureRestart = false
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
            // Post-crash-cap honesty (session 29 review): "wait for model
            // warmup" is a lie when the backend gave up restarting — waiting
            // cannot help. Surface the real reason when the manager has one.
            if state.sttBackend == .whisperKit {
                state.statusLine = "WhisperKit not ready — wait for model load"
            } else if let failure = backendManager.lastStartupFailureReason {
                state.statusLine = "Backend unavailable: \(failure)"
            } else {
                state.statusLine = "Backend not ready — wait for model warmup"
            }
            return
        }

        // Some workflows still depend on backend services even when STT is local.
        if state.workflowNeedsBackend && !state.backendReadiness.readyForDictation {
            let modeName = state.workflowMode.displayName
            log.warning("startCapture blocked: \(modeName) requires backend but backend not ready")
            state.statusLine = backendManager.lastStartupFailureReason
                .map { "\(modeName) requires backend — \($0)" }
                ?? "\(modeName) requires backend — wait for model warmup"
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !state.canStartCaptureForDictation {
            let canStart = state.canStartCaptureForDictation
            log.warning("startCapture blocked: no focused text target (canStart=\(canStart))")
            state.statusLine = "Focus a text field or place cursor before dictating"
            return
        }

        state.resetForNewCapture()
        // A backend crash-respawn (python + torch import) must not land while
        // audio is flowing — the manager defers it until this clears.
        backendManager.setCaptureActive(true)
        capturedTargetApp = NSWorkspace.shared.frontmostApplication
        capturedVoiceActions = commandLane ? nil : computerActionSettings.snapshot()
        capturedSkillMatcher = capturedVoiceActions?.mode.includesCustomPrompts == true ? skillProfiles.activeMatcher : nil
        capturedAutoSubmitMode = commandLane ? .off : state.autoSubmitMode
        capturedInsertionFocus = commandLane ? nil : CapturedInsertionFocus.capture(for: capturedTargetApp)
        focusMonitor.freeze()
        sessionCounter += 1
        state.isCommandLaneActive = commandLane
        if commandLane {
            fnTriggeredCaptureInProgress = false
        }
        privacy.clearPendingOperation()

        do {
            // Gate the "speak now" cue on the FIRST real audio buffer rather
            // than on engine.start() returning. The engine takes ~150 ms to
            // deliver its first buffer; playing the cue immediately told the
            // user to speak before the mic was live, clipping the front of
            // every utterance (and emptying short ones). The mic is still live
            // ONLY during capture — privacy posture is unchanged.
            //
            // Very short press-and-release captures can finish before the
            // first-buffer Task runs; the .recording guard then skips the
            // START cue by design (playing "speak now" after the capture ended
            // would mislead) — the user still gets the STOP cue from
            // prepareForTranscription as feedback.
            let playCue = !commandLane
            let onCaptureLive: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureLiveWatchdog.markLive()
                    guard playCue, self.state.sessionState == .recording else { return }
                    self.cueSoundService.playStartCue()
                }
            }
            try audioCapture.startCapture(onCaptureLive: onCaptureLive)
            // With the cue gated on the first buffer, a device that starts but
            // never delivers would hang in armed silence — no cue, no error —
            // until the capture timeout. The watchdog surfaces that promptly.
            captureLiveWatchdog.arm(timeout: Self.captureLiveStallTimeout) { [weak self] in
                self?.handleCaptureStalled()
            }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.state.recordingDuration += 0.1
                    // Mid-capture stall: buffers stopped flowing while the UI
                    // says "recording" (device died without a configuration-
                    // change notification). Stop now and transcribe what DID
                    // arrive instead of letting the user speak into a dead
                    // engine until the 60 s timeout (session 29). The first-
                    // buffer phase is the CaptureLiveWatchdog's job — this
                    // readout is nil until a buffer has arrived.
                    if self.state.sessionState == .recording,
                       let stall = self.audioCapture.secondsSinceLastBuffer,
                       stall > Self.midCaptureStallTimeout {
                        self.log.error("No audio buffer for \(String(format: "%.1f", stall))s mid-capture — stopping and transcribing what arrived")
                        await self.finishCaptureAndTranscribe(commandLane: commandLane)
                    }
                }
            }
            captureTimeoutTimer?.invalidate()
            captureTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.maxCaptureDuration, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state.sessionState == .recording else { return }
                    self.log.warning("Capture timeout reached (\(Self.maxCaptureDuration)s) — auto-stopping")
                    await self.finishCaptureAndTranscribe(commandLane: commandLane)
                    // The stop cue mid-speech is easy to miss; without this
                    // note the insert LOOKS complete while everything after
                    // the cutoff vanished (session 29 review). Appended after
                    // the pipeline so the insert/review message stays first.
                    self.state.statusLine += String(
                        format: " — %.0f s limit reached; speech after the cutoff was not captured",
                        Self.maxCaptureDuration)
                }
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
        backendManager.setCaptureActive(false)

        // A fn press queued during this pipeline (user still holding fn and
        // speaking) restarts capture now that the state machine has settled.
        if pendingFnCaptureRestart {
            pendingFnCaptureRestart = false
            handleFnHoldPress()
        }
    }

    private func runTranscriptionPipeline(
        sessionID: String,
        commandLane: Bool,
        trace: CapturePipelineTraceBuilder
    ) async {
        do {
            let captureFinalizeStarted = ContinuousClock.now
            guard let capturedAudio = try stopAndValidateAudio(commandLane: commandLane) else {
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
            // NOTE: the stop cue plays in stopAndValidateAudio, AFTER the tap
            // is removed — played here it raced the still-recording engine
            // and its onset could land in the capture tail through the
            // speakers (session 29 review).
        }

        captureLiveWatchdog.cancel()
        timer?.invalidate()
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        state.sessionState = .transcribing
        state.statusLine = commandLane ? "Interpreting command..." : "Transcribing..."
    }

    /// Audit-log source label for the quick-capture lanes. Single source of
    /// truth so the silence and gate-rejection receipts can't drift apart.
    private static func captureSourceLabel(commandLane: Bool) -> String {
        commandLane ? "command_lane" : "quick_dictation"
    }

    private func stopAndValidateAudio(commandLane: Bool) throws -> CapturedAudio? {
        let capturedAudio = try audioCapture.stopCapture()
        // Cue AFTER the tap is gone: played any earlier, the Basso onset can
        // bleed into the capture tail via the speakers. The pipeline Task
        // starts immediately after the user's stop, so the delay is ~ms.
        if !commandLane {
            cueSoundService.playStopCue()
        }
        let source = Self.captureSourceLabel(commandLane: commandLane)
        let durationSec = capturedAudio.durationSeconds
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
            let rms = capturedAudio.rmsEnergy
            log.info("Audio is silence (RMS \(String(format: "%.4f", rms))) — discarding")
            // Record it: a fully dead mic (RMS ~0) otherwise leaves no trace,
            // so "I spoke and nothing happened" becomes diagnosable from the log.
            insertionAudit.recordRejection(
                text: "",
                reason: TranscriptGate.Rejection.silence.rawValue,
                confidence: 0,
                durationSeconds: durationSec,
                source: source,
                rmsEnergy: rms,
                leadingSilenceSeconds: capturedAudio.leadingSilenceSeconds,
                firstBufferLatencyMs: capturedAudio.firstBufferLatencyMs
            )
            state.sessionState = .idle
            // Dead-air silence is the strongest "check your input" case — give the
            // actionable mic hint, not the generic "no speech" message.
            state.statusLine = CaptureFeedback.rejectionStatus(reason: .silence, rmsEnergy: rms)
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
        let recognizedText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSkill: SpokenSkill? = state.workflowMode == .dictation && !commandLane
            && state.onboardingPhase != .calibrating
            ? capturedSkillMatcher?.resolve(recognizedText, targetBundleID: capturedTargetApp?.bundleIdentifier)
            : nil
        let resolvedAction: ComputerAction? = state.workflowMode == .dictation && !commandLane
            && state.onboardingPhase != .calibrating && resolvedSkill == nil
            && capturedVoiceActions?.mode.includesComputerActions == true
            ? computerActionSettings.catalog.resolve(recognizedText,
                enabledIDs: capturedVoiceActions?.enabledIDs ?? [],
                requiresPrefix: capturedVoiceActions?.requiresPrefix ?? true)
            : nil
        // A recognized skill passes the same gate on its original utterance;
        // dictionary corrections cannot turn its name into a different command.
        let rawText = resolvedSkill == nil && resolvedAction == nil ? cockpitDictionary.apply(to: recognizedText) : recognizedText
        lastTranscriptionConfidence = transcription.confidenceEstimate
        lastCaptureAudioStats = (
            audioSeconds: capturedAudio.durationSeconds,
            rmsEnergy: capturedAudio.rmsEnergy,
            peakAmplitude: transcription.peakAmplitude,
            tailGapSeconds: transcription.speechTailGapSeconds
        )
        // Idle gap since the previous decode (for the cold-pipeline hypothesis);
        // updated every decode so the value on a reject = gap since last capture.
        let secondsSinceLastCapture = lastDecodeAt.map { Date().timeIntervalSince($0) }
        lastDecodeAt = Date()
        #if DEBUG
        log.info("Transcription: '\(rawText.prefix(100))' (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #else
        log.info("Transcription: \(rawText.count) chars (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
        #endif

        let audioDurationSec = capturedAudio.durationSeconds

        // Single ingress gate: empty/placeholder, hallucination filter, and the
        // low-confidence rules live in TranscriptGate so every transcript path
        // (quick dictation, cockpit chunks, command lane) applies them identically.
        if case .rejected(let reason) = TranscriptGate.evaluate(
            text: rawText,
            confidence: transcription.confidenceEstimate,
            audioDurationSeconds: audioDurationSec
        ) {
            let rms = capturedAudio.rmsEnergy
            log.info("TranscriptGate rejected transcript (\(reason.rawValue), confidence=\(String(format: "%.2f", transcription.confidenceEstimate)), duration=\(String(format: "%.1f", audioDurationSec))s, rms=\(String(format: "%.4f", rms))) — discarding")
            // Retain the capture BEFORE it goes out of scope: the WAV is both
            // the diagnostic evidence (gappy? garbled? quiet?) and the user's
            // only path to recovering a rejected dictation (session 29).
            let retainedAudio = rejectedAudio.store(
                pcm: capturedAudio.pcm,
                sampleRate: capturedAudio.sampleRate,
                reason: reason.rawValue
            )
            insertionAudit.recordRejection(
                text: rawText,
                reason: reason.rawValue,
                confidence: transcription.confidenceEstimate,
                durationSeconds: audioDurationSec,
                source: Self.captureSourceLabel(commandLane: commandLane),
                rmsEnergy: rms,
                leadingSilenceSeconds: capturedAudio.leadingSilenceSeconds,
                firstBufferLatencyMs: capturedAudio.firstBufferLatencyMs,
                secondsSinceLastCapture: secondsSinceLastCapture,
                appliedGainDB: transcription.appliedGainDB,
                meanNoSpeechProb: transcription.meanNoSpeechProb,
                segmentCount: transcription.segmentCount,
                peakAmplitude: transcription.peakAmplitude,
                audioFile: retainedAudio?.path,
                expectedAudioSeconds: capturedAudio.expectedDurationSeconds
            )
            state.sessionState = .idle
            var rejectionStatus = CaptureFeedback.rejectionStatus(reason: reason, rmsEnergy: rms)
            // R6: for an EMPTY capture, ask the backend's Silero VAD whether
            // speech was actually present — "too quiet" vs "background noise
            // only" beats the RMS guess. Fail-quiet: a cold backend refuses
            // the connection fast (the call never triggers a spawn) and the
            // RMS-based message above stands.
            if reason == .empty,
               let diagnosis = try? await BackendAPIClient.diagnoseAudio(
                   sessionID: sessionID,
                   audioPCM: capturedAudio.pcm,
                   sampleRate: Int(capturedAudio.sampleRate)
               ) {
                rejectionStatus = CaptureFeedback.refinedRejectionStatus(
                    reason: reason, rmsEnergy: rms, diagnosis: diagnosis)
            }
            // Recovery is only real if the user knows the clip exists.
            if retainedAudio != nil { rejectionStatus += " (audio kept)" }
            state.statusLine = rejectionStatus
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

        // Match the accepted original utterance before personal corrections can
        // rename a skill. Both the profile and target were frozen at capture start.
        if resolvedSkill != nil || resolvedAction != nil, capturedVoiceActions?.revoked == true {
            state.statusLine = "Voice action canceled — settings changed"
            state.sessionState = .idle
            return
        }
        if let action = resolvedAction, let permissions = capturedVoiceActions {
            let started = ContinuousClock.now
            let target = capturedTargetApp
            let destination = action.operation == .openApplication ? action.argument : target?.localizedName
            let status: String
            do {
                let outcome = try await computerActions.execute(action, permissions: permissions,
                    target: target, focus: capturedInsertionFocus)
                status = "\(action.name) — \(outcome.label)"
                insertionAudit.recordComputerAction(id: action.id, name: action.name, outcome: outcome.rawValue,
                    targetApp: destination, durationMs: started.elapsedMilliseconds())
            } catch {
                let canceled = Self.isUserCancellation(error)
                status = canceled ? "Voice action canceled" : error.localizedDescription
                insertionAudit.recordComputerAction(id: action.id, name: action.name, outcome: canceled ? "canceled" : "failed",
                    targetApp: destination, durationMs: started.elapsedMilliseconds())
            }
            // LaunchServices may finish an already dispatched open after cancel.
            // Keep its receipt, but never reset a newer capture's UI to idle.
            guard !Task.isCancelled else { return }
            state.statusLine = status
            state.recordingDuration = 0
            state.sessionState = .idle
            return
        }
        if let skill = resolvedSkill {
            try Task.checkCancellation()
            _ = await textInsertion.insertText(
                skill.command, statusSuffix: "Skill ‘\(skill.name)’ inserted",
                targetApp: capturedTargetApp,
                timing: InsertTimingContext(pipelineStartedAt: trace.startedAt,
                                            sttMs: transcription.processingTimeMs, cleanupMs: 0),
                policy: .verbatim.withSubmission(capturedAutoSubmitMode.includes(voiceActionPrompt: true))
                    .withCapturedFocus(capturedInsertionFocus).withVoiceActionPermission(capturedVoiceActions))
            state.recordingDuration = 0
            state.sessionState = .idle
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
            // Final cancellation gate: a snippet is built after STT, so a cancel
            // (or superseding capture) between transcription and this insert must
            // NOT insert. Propagates to handleCaptureError, which treats
            // CancellationError as a quiet user cancel.
            try Task.checkCancellation()
            // insertText sets the status line in both cases — success suffix on
            // success, "Auto-insert failed — copied to clipboard" on failure (it
            // also copies to clipboard). Either way the snippet path returns to
            // .idle: no TranscriptCandidate is built, so .review would show an
            // empty, unactionable card. Don't branch sessionState on the result.
            _ = await textInsertion.insertText(
                snippet.text,
                statusSuffix: "Snippet '\(snippet.keyword)' inserted — \(appLabel)",
                targetApp: capturedTargetApp, timing: nil,
                policy: .prose.withSubmission(capturedAutoSubmitMode.includes(voiceActionPrompt: false))
                    .withCapturedFocus(capturedInsertionFocus)
            )
            state.recordingDuration = 0
            state.sessionState = .idle
            return
        }

        try await processWorkflow(sessionID: sessionID, rawText: rawText, trace: trace)

        // Capture-quality warnings, appended AFTER the workflow set its own
        // status so the insert/review message stays first and the user learns
        // words may be missing instead of trusting a silently-truncated insert.
        // Tail gap = the DECODER stopped early (session 29 tail-loss class);
        // coverage shortfall = the DEVICE dropped audio mid-capture.
        if let gap = transcription.speechTailGapSeconds {
            state.statusLine += String(
                format: " — may be incomplete (last ~%.0f s not transcribed)", gap)
        }
        if let coverageWarning = CaptureFeedback.coverageWarning(
            durationSeconds: capturedAudio.durationSeconds,
            expectedSeconds: capturedAudio.expectedDurationSeconds
        ) {
            state.statusLine += coverageWarning
        }
        if capturedAudio.bufferLimitReached {
            state.statusLine += " — capture length limit reached; later audio was dropped"
        }
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

    /// User/system cancellation, classified quietly (no error banner): a
    /// structured-concurrency cancel OR a cancelled URLSession request (e.g. a
    /// superseded backend/STT call surfacing as URLError.cancelled). Genuine
    /// network failures are NOT cancellation and still surface.
    nonisolated static func isUserCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Audit reason for a capture-pipeline error that silently DISCARDS a
    /// dictation. deviceChanged is the one such case today: the capture is
    /// invalidated wholesale with only a transient status line, which made the
    /// loss mode invisible in insertions.jsonl (session 29). Cancellations are
    /// deliberate (no receipt); generic failures already surface as .error
    /// state the user must acknowledge.
    nonisolated static func captureErrorAuditReason(_ error: Error) -> String? {
        (error as? AudioCaptureError) == .deviceChanged ? "device_changed" : nil
    }

    private func handleCaptureError(_ error: Error) {
        if Self.isUserCancellation(error) {
            log.info("Transcription pipeline canceled by user")
            return
        }
        if let reason = Self.captureErrorAuditReason(error) {
            log.warning("Capture invalidated by audio device change")
            insertionAudit.recordRejection(
                text: "",
                reason: reason,
                confidence: 0,
                durationSeconds: 0,
                source: "capture_error"
            )
            state.setIdle()
            state.recordingDuration = 0
            state.statusLine = "Audio device changed — try again"
            return
        }
        log.error("Transcription failed: \(error.localizedDescription)")
        state.sessionState = .error
        state.errorMessage = "Transcription failed: \(error.localizedDescription)"
        state.statusLine = "Error. Retry capture."

        // Connection-level failure = the backend died AFTER the bounded
        // warmup polling window closed, so the cached readiness is stale-true
        // and every retry would loop into the same dead socket (session 29
        // review). Refresh now so the next attempt sees reality (and the
        // warmup path can respawn if configured to run).
        if let urlError = error as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .timedOut].contains(urlError.code) {
            Task { @MainActor [weak self] in
                await self?.refreshBackendReadiness()
            }
        }
    }

    /// The engine started but no audio buffer arrived within the stall
    /// timeout — the input device is delivering nothing (wedged CoreAudio,
    /// zero-input aggregate device). Stop the armed-but-dead capture and tell
    /// the user now instead of letting it sit silent until the capture
    /// timeout. The "capture_stalled" receipt keeps the failure diagnosable
    /// from insertions.jsonl.
    private func handleCaptureStalled() {
        guard state.sessionState == .recording else { return }
        log.error("No audio buffer within \(Self.captureLiveStallTimeout)s of engine start — stopping stalled capture")
        _ = try? audioCapture.stopCapture()
        timer?.invalidate()
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        state.isCommandLaneActive = false
        fnTriggeredCaptureInProgress = false
        cueSoundService.playStopCue()
        insertionAudit.recordRejection(
            text: "",
            reason: "capture_stalled",
            confidence: 0,
            durationSeconds: 0,
            source: "watchdog"
        )
        state.setIdle()
        state.statusLine = "Microphone delivered no audio — check the input device"
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
        captureLiveWatchdog.cancel()
        timer?.invalidate()
        captureTimeoutTimer?.invalidate()
        captureTimeoutTimer = nil
        // An explicit cancel voids any fn-press restart queued during the
        // pipeline — the user asked for silence, not a fresh capture.
        pendingFnCaptureRestart = false
        backendManager.setCaptureActive(false)

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
                // WhisperKit STT can still use backend-backed local-model cleanup;
                // only retone purely in Swift when the backend is idle. On a
                // genuine backend failure RetoneResolver degrades to the in-app
                // cleanup pipeline (matching the dictation path); only
                // cancellation propagates.
                let useBackend = !(self.state.sttBackend == .whisperKit
                    && !self.state.backendReadiness.readyForDictation)
                let retoned = try await RetoneResolver.resolve(
                    rawText: rawText, tone: tone, useBackend: useBackend
                ) { mode in
                    try await BackendAPIClient.cleanup(
                        sessionID: "retone-\(self.sessionCounter)",
                        mode: mode,
                        inputText: rawText,
                        toneStyle: tone,
                        providerMode: .localOnly
                    ).outputText
                }
                try Task.checkCancellation()

                state.transcriptCandidate = TranscriptCandidate(
                    rawText: rawText,
                    lightText: retoned.light,
                    polishText: retoned.polish,
                    selectedMode: state.selectedMode,
                    confidence: state.transcriptCandidate?.confidence ?? 0.0,
                    // Retone reuses the original capture — keep its audio stats
                    // so a later insert receipt still reflects the true capture.
                    audioSeconds: state.transcriptCandidate?.audioSeconds,
                    rmsEnergy: state.transcriptCandidate?.rmsEnergy,
                    peakAmplitude: state.transcriptCandidate?.peakAmplitude
                )
                state.statusLine = "Tone: \(tone.displayName)"
            } catch {
                // Only cancellation reaches here — RetoneResolver rethrows just
                // that and falls back internally on genuine failures. A
                // superseded retone aborts silently rather than overwriting the
                // newer selection.
                return
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
    func selectAutoSubmitMode(_ mode: AutoSubmitMode) {
        if mode != state.autoSubmitMode { capturedInsertionFocus?.revokeSubmission() }
        settings.selectAutoSubmitMode(mode)
    }
    /// Shared with the wiring tests: no coordinator singleton, microphone, or
    /// keyboard services are needed to exercise real store notifications.
    static func observeSkillProfileChanges(
        in store: SkillProfileStore,
        capturedPermission: @escaping () -> CapturedVoiceActions?,
        revokeSubmission: @escaping () -> Void
    ) -> AnyCancellable {
        store.$profiles.combineLatest(store.$activeProfileID)
            .map { profiles, activeID in profiles.first { $0.id == activeID } }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                // Store mutations publish synchronously on MainActor, only after
                // saving succeeds. Ignore inactive-profile edits and no-op saves.
                guard let permission = capturedPermission(), permission.mode.includesCustomPrompts else { return }
                permission.revoke()
                revokeSubmission()
                // Keep the captured matcher: clearing it would turn a canceled
                // command into ordinary dictation, potentially followed by Enter.
            }
    }

    func selectVoiceActionMode(_ mode: VoiceActionMode) {
        if mode != computerActionSettings.mode {
            capturedVoiceActions?.revoke()
            capturedInsertionFocus?.revokeSubmission()
        }
        computerActionSettings.setMode(mode)
        state.statusLine = "Voice actions: \(mode.displayName)"
    }
    func setComputerActionEnabled(_ enabled: Bool, id: String) {
        if computerActionSettings.enabledIDs.contains(id) != enabled { capturedVoiceActions?.revoke() }
        computerActionSettings.setEnabled(enabled, id: id)
    }
    func setComputerActionRequiresPrefix(_ required: Bool) {
        if computerActionSettings.requiresPrefix != required { capturedVoiceActions?.revoke() }
        computerActionSettings.setRequiresPrefix(required)
    }
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

            var request = DictationWorkflowRequest(
                sessionID: sessionID,
                rawText: rawText,
                providerMode: providerMode,
                consentToken: consentToken,
                allowRaw: allowRaw,
                toneStyle: effectiveTone,
                insertBehavior: effectiveInsert,
                sttBackend: self.state.sttBackend,
                lastTranscriptionConfidence: self.lastTranscriptionConfidence,
                targetApp: self.capturedTargetApp,
                audioSeconds: self.lastCaptureAudioStats?.audioSeconds,
                rmsEnergy: self.lastCaptureAudioStats?.rmsEnergy,
                peakAmplitude: self.lastCaptureAudioStats?.peakAmplitude,
                tailGapSeconds: self.lastCaptureAudioStats?.tailGapSeconds
            )
            // Latency receipt: total runs from hotkey release; STT ms is the
            // stage the pipeline already recorded before handing off here.
            request.pipelineStartedAt = trace.startedAt
            request.sttMs = trace.durationMs(of: "stt")
            request.autoSubmit = self.capturedAutoSubmitMode.includes(voiceActionPrompt: false)
            request.insertionFocus = self.capturedInsertionFocus

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
        // Replace, don't orphan: cancel any in-flight handoff (the service
        // terminates its child process on cancellation) before starting a new one.
        handoffTask?.cancel()
        state.handoffInFlight = true
        handoffTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.assistantHandoff.run(transcript: payload)
            // A cancelled/replaced run must not clobber the newer run's state.
            if Task.isCancelled { return }
            self.state.handoffInFlight = false
            switch result {
            case .success(let output):
                self.state.handoffResult = output
                self.state.statusLine = "Assistant responded"
            case .failure(.cancelled):
                // User replaced/dismissed it — stay quiet.
                break
            case .failure(let error):
                self.state.statusLine = "Handoff failed: \(String(describing: error))"
            }
        }
    }

    func dismissAssistantHandoff() {
        // Cancel an in-flight handoff so its child process is terminated, not orphaned.
        handoffTask?.cancel()
        handoffTask = nil
        state.handoffInFlight = false
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
            receiptStore: receiptStore,
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
            // Keep this deferred (Published emits before the properties update),
            // but deliver through the main dispatch executor. A live release
            // capture exposed a crash in the CF run-loop executor's isolation
            // check when entering this MainActor-isolated sink.
            .receive(on: DispatchQueue.main)
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
