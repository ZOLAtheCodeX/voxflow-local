import SwiftUI

/// First-run setup as one checklist page: Microphone, Accessibility, Speech
/// engine, and optional Voice calibration, then a "Try it" line. The decisions
/// (which rows are done, the badge words, the health detail rows) live in
/// `SetupChecklist`; this view lays them out and keeps every action's call.
struct SetupWizardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var backendHealth: [String: String] = [:]
    @State private var isCheckingHealth = false
    @State private var healthMessage: String?
    @State private var didRunHealthCheck = false
    @State private var detailsExpanded = false
    @State private var permissionPollTimer: Timer?

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous)
    }

    private var engineReady: Bool {
        SetupChecklist.engineReady(readiness: state.backendReadiness)
    }

    private var progress: SetupProgress {
        SetupChecklist.progress(
            microphone: permissions.microphoneAuthorized,
            accessibility: permissions.accessibilityAuthorized,
            engineReady: engineReady,
            onboardingPhase: state.onboardingPhase)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingLarge) {
                header
                checklist
                tryIt
                footer
            }
            .padding(VF.spacingXLarge)
        }
        .background(VF.surfaceWindow)
        .onAppear {
            refreshPermissions()
            startPermissionPolling()
            Task { await runHealthCheckIfNeeded() }
        }
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        let progress = progress
        return HStack(alignment: .firstTextBaseline) {
            Text("Set up VoxFlow")
                .font(VF.displayFont)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(progress.doneCount) of \(progress.total) done")
                .font(VF.labelFont)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Checklist

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            microphoneRow
            Divider()
            accessibilityRow
            Divider()
            engineRow
            Divider()
            calibrationRow
        }
        .padding(.horizontal, VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: cardShape)
    }

    private var microphoneRow: some View {
        SetupRow(
            symbol: "mic.fill",
            title: "Microphone",
            purpose: "Lets VoxFlow hear you.",
            status: SetupChecklist.permissionStatus(permissions.microphoneAuthorized)
        ) {
            if !permissions.microphoneAuthorized {
                Button("Grant Access") {
                    coordinator.requestMicrophonePermission()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Grant microphone access")
            }
        }
    }

    private var accessibilityRow: some View {
        SetupRow(
            symbol: "hand.tap.fill",
            title: "Accessibility",
            purpose: "Lets VoxFlow type into other apps.",
            status: SetupChecklist.permissionStatus(permissions.accessibilityAuthorized)
        ) {
            if !permissions.accessibilityAuthorized {
                Button("Grant Access") {
                    coordinator.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Grant accessibility access")
            }
        } footer: {
            if !permissions.accessibilityAuthorized {
                Text("If you rebuild VoxFlow yourself, macOS may forget the Accessibility grant. Remove VoxFlow in System Settings → Privacy & Security → Accessibility and add it again.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var engineRow: some View {
        SetupRow(
            symbol: "cpu",
            title: "Speech engine",
            purpose: SetupChecklist.speechEnginePurpose(state.sttBackend),
            status: SetupChecklist.engineStatus(
                ready: engineReady, starting: state.backendReadiness.warmupInProgress)
        ) {
            if !engineReady {
                Button("Start Engine") {
                    coordinator.startBackend()
                    Task { await runHealthCheckAfterDelay() }
                }
                .buttonStyle(.borderedProminent)
            }
        } footer: {
            engineDetails
        }
    }

    private var engineDetails: some View {
        DisclosureGroup("Details", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                Text(healthMessage ?? "Not checked yet")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)

                if didRunHealthCheck {
                    VStack(alignment: .leading, spacing: VF.spacingXSmall) {
                        ForEach(SetupChecklist.detailRows(backendHealth), id: \.label) { row in
                            LabeledContent(row.label) {
                                Text(row.value)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .font(VF.captionFont)
                }

                Button {
                    Task { await runHealthCheck() }
                } label: {
                    HStack(spacing: VF.spacingSmall) {
                        if isCheckingHealth {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isCheckingHealth ? "Checking" : "Check Again")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingHealth)
            }
            .padding(.top, VF.spacingXSmall)
        }
        .font(VF.secondaryFont)
    }

    private var calibrationRow: some View {
        let phase = state.onboardingPhase
        return SetupRow(
            symbol: "waveform.badge.mic",
            title: "Voice calibration",
            purpose: "Optional. Can improve accuracy.",
            status: SetupChecklist.calibrationStatus(phase)
        ) {
            if phase != .calibrating {
                if phase == .complete {
                    Button("Recalibrate") {
                        coordinator.restartOnboardingCalibration()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Calibrate") {
                        coordinator.restartOnboardingCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } footer: {
            if phase == .calibrating {
                OnboardingCalibrationView(coordinator: coordinator, state: state)
            }
        }
    }

    // MARK: - Try it

    private var tryIt: some View {
        let status = SetupChecklist.tryIt(
            remainingRequired: progress.remainingRequired,
            canStartCapture: state.canStartCaptureForDictation,
            appName: state.focusTarget.appName)
        return HStack(alignment: .firstTextBaseline, spacing: VF.spacingMedium) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Try it: click into any text field.")
                    .font(VF.bodyEmphasizedFont)
                Text(VFCopy.hotkeyHint(
                    dictation: state.dictationHotkeyPreset, voiceControl: state.commandLaneHotkeyPreset))
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: VF.spacingSmall)
            VFStatusBadge(status: status)
        }
        .padding(VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: cardShape)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: VF.spacingSmall) {
            if state.onboardingPhase == .notStarted {
                Button("Skip Calibration") {
                    coordinator.completeOnboardingManually()
                }
                .buttonStyle(.bordered)
                .help("Skip the voice profile setup. You can run calibration later from Setup.")
            }
            Spacer()
            Button("Reset Setup") {
                coordinator.restartOnboardingCalibration()
                coordinator.startBackend()
                refreshPermissions()
                Task { await runHealthCheckAfterDelay() }
            }
            .buttonStyle(.bordered)
            .help("Restart calibration, restart the engine and check permissions again.")
        }
    }

    // MARK: - Permissions and health

    private func refreshPermissions() {
        permissions = coordinator.permissionSnapshot()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                permissions = coordinator.permissionSnapshot()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func runHealthCheckIfNeeded() async {
        guard !didRunHealthCheck else { return }
        await runHealthCheck()
    }

    private func runHealthCheckAfterDelay() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        await runHealthCheck()
    }

    private func runHealthCheck() async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        refreshPermissions()

        do {
            let readiness = try await BackendAPIClient.ready()
            backendHealth = [
                "service_status": readiness.serviceStatus,
                "ready_for_dictation": String(readiness.readyForDictation).lowercased(),
                "model_loaded": String(readiness.activeSttModelLoaded).lowercased(),
                "stt_backend": readiness.sttBackend,
                "active_stt_model": readiness.activeSttModel,
                "stt_fallback_active": String(readiness.sttFallbackActive).lowercased(),
                "offline_mode": String(readiness.offlineMode).lowercased(),
                "issues": readiness.issues.joined(separator: "; "),
            ]
            didRunHealthCheck = true
            healthMessage = SetupChecklist.healthMessage(
                reachable: true, ready: readiness.readyForDictation, firstIssue: readiness.issues.first)
        } catch {
            backendHealth = [:]
            didRunHealthCheck = true
            healthMessage = SetupChecklist.healthMessage(reachable: false, ready: false, firstIssue: nil)
        }
    }
}

/// One checklist row: identity symbol, title and purpose on the left; the
/// row's action and its status badge on the right; optional detail below.
private struct SetupRow<Actions: View, Footer: View>: View {
    let symbol: String
    let title: String
    let purpose: String
    let status: VFStatus
    @ViewBuilder var actions: Actions
    @ViewBuilder var footer: Footer

    init(
        symbol: String,
        title: String,
        purpose: String,
        status: VFStatus,
        @ViewBuilder actions: () -> Actions,
        @ViewBuilder footer: () -> Footer
    ) {
        self.symbol = symbol
        self.title = title
        self.purpose = purpose
        self.status = status
        self.actions = actions()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            HStack(spacing: VF.spacingMedium) {
                Image(systemName: symbol)
                    .font(VF.titleFont)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VF.bodyEmphasizedFont)
                    Text(purpose)
                        .font(VF.secondaryFont)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: VF.spacingSmall)
                actions
                VFStatusBadge(status: status)
                    .frame(minWidth: 84, alignment: .trailing)
            }
            footer
                .padding(.leading, 24 + VF.spacingMedium)
        }
        .padding(.vertical, VF.spacingMedium)
    }
}

extension SetupRow where Footer == EmptyView {
    init(
        symbol: String,
        title: String,
        purpose: String,
        status: VFStatus,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            symbol: symbol, title: title, purpose: purpose, status: status,
            actions: actions, footer: { EmptyView() })
    }
}
