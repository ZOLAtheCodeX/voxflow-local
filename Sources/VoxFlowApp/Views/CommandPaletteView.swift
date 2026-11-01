import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var receiptStore: InsertionReceiptStore
    var onOpenDashboardWindow: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    var onQuit: () -> Void = {}
    // Internal (not private) so the subviews in Views/Palette/ can reach them.
    @State var activePanel: ActivePanel = .capture
    @State var recordingBadgeAnimating = false
    @State var showClearHistoryAlert = false
    @State var showProfilePopover = false
    @State var transcribingElapsed: Int = 0

    /// Spelled out so the call sites' initializer stays exactly as it was
    /// while the view state above is internal.
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
        case capture
        case dashboard
        case recent

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .capture:
                return "Dictate"
            case .dashboard:
                return "Stats"
            case .recent:
                return "Recent"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            header

            if state.onboardingPhase == .calibrating {
                OnboardingCalibrationView(coordinator: coordinator, state: state)
            } else {
                contentCard
            }

            if let error = state.errorMessage {
                Text(error)
                    .font(VF.labelFont)
                    .foregroundStyle(VF.colorError)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            lastCaptureRow

            SkillProfileMenu(store: coordinator.skillProfiles)
                .font(VF.captionFont)
                .padding(.horizontal, VF.spacingLarge)
            VoiceActionModeMenu(settings: coordinator.computerActionSettings, selectMode: coordinator.selectVoiceActionMode)
                .font(VF.captionFont)
                .padding(.horizontal, VF.spacingLarge)

            Text("Automatic Enter: \(state.autoSubmitMode.displayName)")
                .font(VF.captionFont)
                .foregroundStyle(state.autoSubmitMode == .off ? .secondary : VF.colorWarning)
                .padding(.horizontal, VF.spacingLarge)

            footerBar
        }
        .padding(.vertical, VF.spacingMedium)
        .background(state.isCommandLaneActive ? VF.tintedBackground(VF.colorWarning, opacity: 0.08) : Color.clear)
        .animation(VF.animationStandard, value: activePanel)
        .animation(.smooth(duration: 0.3), value: state.sessionState)
        .onAppear {
            updateRecordingBadgeAnimation()
            receiptStore.refresh()
        }
        .onChange(of: state.sessionState) { _, _ in
            updateRecordingBadgeAnimation()
        }
        .onChange(of: state.captureCount) { _, _ in receiptStore.refresh() }
        .onChange(of: state.statusLine) { _, _ in receiptStore.refresh() }
    }

    private var contentCard: some View {
        Group {
            switch state.sessionState {
            case .recording:
                recordingStateCard
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .transcribing:
                transcribingStateCard
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            default:
                mainDictationCard
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    private var mainDictationCard: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            HStack {
                Text(state.canStartCaptureForDictation ? "Target Ready" : "No Text Target")
                    .font(VF.labelFont)
                    .foregroundStyle(state.canStartCaptureForDictation ? .green : .orange)
                Spacer()
                Text(state.focusTarget.appName ?? "No active app")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            Picker("Panel", selection: $activePanel) {
                ForEach(ActivePanel.allCases) { panel in
                    Text(panel.displayName).tag(panel)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch activePanel {
                case .dashboard:
                    DashboardPanelView(coordinator: coordinator, state: state) {
                        activePanel = .capture
                    } onOpenFullDashboard: {
                        onOpenDashboardWindow()
                    }
                case .recent:
                    recentDictationsPanel
                case .capture:
                    capturePanel
                }
            }
            .id(activePanel)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
    }
}
