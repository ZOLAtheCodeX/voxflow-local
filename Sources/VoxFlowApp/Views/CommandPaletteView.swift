import SwiftUI

/// The menu-bar palette: status, the last result (or the live capture), one
/// options row and a footer. A shell over the views in `Views/Palette/`;
/// every control calls the coordinator method it called before the UI
/// refresh.
struct CommandPaletteView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var receiptStore: InsertionReceiptStore
    var onOpenDashboardWindow: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var activePanel: ActivePanel = .dictate
    /// Required setup steps still open (microphone, Accessibility), read
    /// from the coordinator's permission snapshot.
    @State private var setupStepsLeft = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Spelled out so the call sites' initializer stays exactly as it was.
    init(
        coordinator: AppCoordinator,
        state: AppState,
        receiptStore: InsertionReceiptStore,
        onOpenDashboardWindow: @escaping () -> Void = {},
        onOpenSetup: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.state = state
        self.receiptStore = receiptStore
        self.onOpenDashboardWindow = onOpenDashboardWindow
        self.onOpenSetup = onOpenSetup
        self.onQuit = onQuit
    }

    enum ActivePanel: String, CaseIterable, Identifiable {
        case dictate
        case recent

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dictate: return "Dictate"
            case .recent: return "Recent"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            PaletteHeaderView(
                status: status,
                targetAppName: state.focusTarget.appName,
                isVoiceControlActive: state.isCommandLaneActive,
                secondLine: secondLine,
                errorMessage: state.errorMessage)
                .padding(.horizontal, VF.spacingLarge)

            if setupStepsLeft > 0 {
                VFBanner(kind: .warning, message: setupBannerText, actionTitle: "Open", action: onOpenSetup)
                    .padding(.horizontal, VF.spacingLarge)
            }

            if state.onboardingPhase == .calibrating {
                OnboardingCalibrationView(coordinator: coordinator, state: state)
            } else {
                mainSection
            }

            PaletteOptionsRow(coordinator: coordinator, state: state, onOpenSetup: onOpenSetup)
                .padding(.horizontal, VF.spacingLarge)

            Divider()

            PaletteFooter(
                state: state,
                onOpenDashboard: onOpenDashboardWindow,
                onOpenSetup: onOpenSetup,
                onQuit: onQuit)
                .padding(.horizontal, VF.spacingLarge)
        }
        .padding(.vertical, VF.spacingMedium)
        .background(state.isCommandLaneActive ? VF.tintedBackground(VF.colorVoiceControl, opacity: 0.08) : Color.clear)
        .animation(VF.animationStandard, value: activePanel)
        .animation(VF.animationStandard, value: state.sessionState)
        .onAppear {
            receiptStore.refresh()
            refreshSetupProgress()
        }
        .onChange(of: state.sessionState) { _, newState in
            // A capture or a review always lands on the Dictate tab, so a
            // review that opens the panel is never hidden behind Recent.
            if newState != .idle { activePanel = .dictate }
            refreshSetupProgress()
        }
        .onChange(of: state.captureCount) { _, _ in receiptStore.refresh() }
        .onChange(of: state.statusLine) { _, _ in receiptStore.refresh() }
    }

    // MARK: - Main card

    @ViewBuilder private var mainSection: some View {
        switch state.sessionState {
        case .recording:
            PaletteRecordingCard(
                duration: state.recordingDuration,
                targetAppName: state.focusTarget.appName,
                isVoiceControl: state.isCommandLaneActive,
                onCancel: { coordinator.cancelActiveCapture() })
                .padding(.horizontal, VF.spacingMedium)
                .transition(.vfStateChange(reduceMotion: reduceMotion))
        case .transcribing, .inserting:
            PaletteProgressCard()
                .padding(.horizontal, VF.spacingMedium)
                .transition(.vfStateChange(reduceMotion: reduceMotion))
        default:
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                Picker("Panel", selection: $activePanel) {
                    ForEach(ActivePanel.allCases) { panel in
                        Text(panel.displayName).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, VF.spacingLarge)

                Group {
                    switch activePanel {
                    case .recent:
                        PaletteRecentList(coordinator: coordinator, state: state)
                    case .dictate:
                        dictateCard
                    }
                }
                .id(activePanel)
                .padding(.horizontal, VF.spacingMedium)
                .transition(.vfStateChange(reduceMotion: reduceMotion))
            }
            .transition(.vfStateChange(reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder private var dictateCard: some View {
        if state.sessionState == .review || state.privacyPreview != nil {
            PaletteReviewCard(coordinator: coordinator, state: state)
        } else {
            let latest = receiptStore.latest
            PaletteLastResultCard(
                row: latest.map { CaptureReceiptRowModel(receipt: $0) },
                // SessionMemoryStore.recent() lists newest first.
                canReinsert: PaletteLastResult.canReinsert(latest: latest, newest: state.recentDictations.first),
                onInsertAgain: {
                    if let newest = state.recentDictations.first {
                        coordinator.insertRecentDictation(newest)
                    }
                },
                onCopy: {
                    if let newest = state.recentDictations.first {
                        PaletteRecentCopy.copy(newest, state: state)
                    }
                },
                onDetails: onOpenDashboardWindow)
        }
    }

    // MARK: - Status

    private var dictationReady: Bool {
        state.canUseSelectedSTTBackend && (!state.workflowNeedsBackend || state.backendReadiness.readyForDictation)
    }

    private var status: VFStatus {
        VFStatus.palette(
            sessionState: state.sessionState,
            isCommandLaneActive: state.isCommandLaneActive,
            dictationReady: dictationReady,
            isWarmingUp: state.backendReadiness.warmupInProgress,
            hasTextTarget: state.canStartCaptureForDictation)
    }

    private var secondLine: String {
        VFCopy.paletteSecondLine(
            status: status,
            hint: VFCopy.hotkeyHint(dictation: state.dictationHotkeyPreset, voiceControl: state.commandLaneHotkeyPreset),
            statusLine: state.statusLine)
    }

    // MARK: - Setup

    private var setupBannerText: String {
        setupStepsLeft == 1 ? "Finish setup: 1 step left" : "Finish setup: \(setupStepsLeft) steps left"
    }

    private func refreshSetupProgress() {
        let permissions = coordinator.permissionSnapshot()
        let progress = SetupProgress(
            microphone: permissions.microphoneAuthorized,
            accessibility: permissions.accessibilityAuthorized,
            engine: dictationReady,
            calibration: state.onboardingPhase == .complete)
        setupStepsLeft = progress.remainingRequired
    }
}
