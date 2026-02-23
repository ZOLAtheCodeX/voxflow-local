import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var onOpenDashboardWindow: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var activePanel: ActivePanel = .capture
    @State private var recordingBadgeAnimating = false
    @State private var showClearHistoryAlert = false
    @State private var showProfilePopover = false
    @State private var transcribingElapsed: Int = 0
    @State private var transcribingTimer: Timer?

    private enum ActivePanel: String, CaseIterable, Identifiable {
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
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            footerBar
        }
        .padding(.vertical, VF.spacingMedium)
        .background(state.isCommandLaneActive ? Color.orange.opacity(0.08) : Color.clear)
        .animation(.smooth(duration: 0.25), value: activePanel)
        .animation(.smooth(duration: 0.3), value: state.sessionState)
        .onAppear { updateRecordingBadgeAnimation() }
        .onChange(of: state.sessionState) { _, _ in
            updateRecordingBadgeAnimation()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: VF.spacingSmall) {
                    Text("VoxFlow Local")
                        .font(VF.titleFont)
                    if state.isCommandLaneActive {
                        Text("SYSTEM COMMAND")
                            .font(VF.captionFont.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.24))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                Text(state.statusLine)
                    .font(VF.labelFont)
                    .foregroundStyle(.secondary)

                Text("Dictate: \(state.dictationHotkeyPreset.displayName) · Commands: \(state.commandLaneHotkeyPreset.displayName)")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(state.backendReadyForDictation ? "Ready" : "Not Ready")
                    .font(VF.captionFont.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(readinessBadgeColor.opacity(0.22))
                    .foregroundStyle(readinessBadgeColor)
                    .clipShape(Capsule())

                Text(state.sessionState.rawValue.capitalized)
                    .font(VF.captionFont.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(sessionBadgeColor.opacity(0.22))
                    .foregroundStyle(sessionBadgeColor)
                    .clipShape(Capsule())
                    .scaleEffect(state.sessionState == .recording && recordingBadgeAnimating ? 1.08 : 1.0)
                    .animation(
                        state.sessionState == .recording
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: recordingBadgeAnimating
                    )
            }
        }
        .padding(.horizontal, 16)
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

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Picker("Provider", selection: Binding(
                get: { state.providerMode },
                set: { coordinator.selectProviderMode($0) }
            )) {
                ForEach(ProviderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if state.providerMode == .privateAPI && (state.privateAPIBaseURL.isEmpty || state.privateAPIModel.isEmpty || state.privateAPIKey.isEmpty) {
                Text("Private API mode needs Base URL, Model, and API key in Settings.")
                    .font(VF.captionFont.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Picker("Mode", selection: Binding(
                get: { state.workflowMode },
                set: { coordinator.selectWorkflowMode($0) }
            )) {
                ForEach(state.availableWorkflowModes) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if let privacyPreview = state.privacyPreview {
                privacyReview(preview: privacyPreview)
            } else {
                switch state.workflowMode {
                case .translateEnToDe:
                    translationReview
                case .meeting:
                    meetingReview
                case .dictation:
                    dictationReview
                case .prompt:
                    dictationReview // TODO: Task 5 — prompt-specific review if needed
                }
            }

            HStack(spacing: 10) {
                Button("Insert") {
                    coordinator.insertCurrentText()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(insertDisabled)

                Button("Copy") {
                    coordinator.copyCurrentText()
                }
                .buttonStyle(.bordered)
                .disabled(state.displayText.isEmpty)

                Button("Retry") {
                    coordinator.retryLastCapture()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: [.command])

                Spacer()
            }
        }
    }

    private func privacyReview(preview: PrivacyPreview) -> some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Text("Privacy Review")
                .font(VF.labelFont.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("Original")
                .font(VF.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.originalText)
                .font(VF.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                .lineLimit(4)

            Text("Redacted")
                .font(VF.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.redactedText)
                .font(VF.bodyFont)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: VF.cornerMedium)
                        .fill(.ultraThinMaterial)
                        .overlay(Color.blue.opacity(0.08))
                }
                .lineLimit(4)

            HStack(spacing: 8) {
                Button("Approve Redacted") {
                    coordinator.approvePrivacyPreview(sendRaw: false)
                }
                .buttonStyle(.borderedProminent)

                Button("Approve Raw") {
                    coordinator.approvePrivacyPreview(sendRaw: true)
                }
                .buttonStyle(.bordered)

                Button("Cancel") {
                    coordinator.cancelPrivacyPreview()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    private var dictationReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            Group {
                if state.displayText.isEmpty {
                    Text("Hold \(state.dictationHotkeyPreset.displayName) to dictate. Use \(state.commandLaneHotkeyPreset.displayName) for command lane.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(state.displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(VF.bodyFont)
            .frame(minHeight: 92, maxHeight: 120)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))

            HStack(spacing: 8) {
                ForEach(CleanupMode.allCases) { mode in
                    ModeChip(mode: mode, selected: state.selectedMode == mode) {
                        coordinator.selectCleanupMode(mode)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Tone")
                    .font(VF.labelFont.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(ToneStyle.allCases) { tone in
                    Button(tone.displayName) {
                        coordinator.selectToneStyle(tone)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(state.toneStyle == tone ? .accentColor : .gray)
                }
            }

            if let bundleID = state.focusTarget.bundleID, let appName = state.focusTarget.appName {
                Divider()
                HStack(spacing: 6) {
                    Button {
                        showProfilePopover.toggle()
                    } label: {
                        Label("Profile: \(appName)", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .popover(isPresented: $showProfilePopover) {
                        appProfilePopover(bundleID: bundleID, appName: appName)
                    }

                    if state.appProfiles[bundleID] != nil {
                        Text("Custom")
                            .font(VF.captionFont.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    private var translationReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let candidate = state.translationCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured English")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.sourceEnglish)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("German Output")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.targetGerman)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: VF.cornerMedium)
                                .fill(.ultraThinMaterial)
                                .overlay(Color.green.opacity(0.08))
                        }
                }

                if !candidate.approved {
                    Button {
                        coordinator.approveTranslation()
                    } label: {
                        Label("Approve Translation", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } else {
                Text("Hold hotkey, speak in English, release to produce German text.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
            }
        }
    }

    private var meetingReview: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if let meeting = state.meetingCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured Transcript")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(meeting.transcript)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                        .lineLimit(4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Structured Notes")
                        .font(VF.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(meeting.formattedNotes)
                            .font(VF.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 150)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: VF.cornerMedium)
                            .fill(.ultraThinMaterial)
                            .overlay(Color.blue.opacity(0.08))
                    }
                }

                if !meeting.speakerSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Speaker Segments")
                            .font(VF.captionFont.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.speakerSegments) { segment in
                                Text("• \(segment.speaker) (\(segment.utteranceCount)): \(segment.text)")
                                    .font(VF.labelFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
                    }
                }

                if !meeting.taskOwners.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Task Owners")
                            .font(VF.captionFont.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.taskOwners) { owner in
                                let confidence = Int((owner.confidence * 100).rounded())
                                Text("• \(owner.task) -> \(owner.owner) (\(confidence)%)")
                                    .font(VF.labelFont)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: VF.cornerMedium)
                                .fill(.ultraThinMaterial)
                                .overlay(Color.green.opacity(0.08))
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Copy Markdown Template") {
                        coordinator.copyMeetingMarkdownTemplate()
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Notion Template") {
                        coordinator.copyMeetingNotionTemplate()
                    }
                    .buttonStyle(.bordered)
                }

                if !meeting.approved {
                    Button {
                        coordinator.approveMeetingNotes()
                    } label: {
                        Label("Approve Meeting Notes", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } else {
                Text("Meeting mode: hold hotkey to capture, then review summary, decisions, actions, and follow-ups.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
            }
        }
    }

    private var recentDictationsPanel: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if state.recentDictations.isEmpty {
                Text("No recent dictations this session.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.recentDictations) { candidate in
                            recentRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 200)

                Button("Clear History") {
                    showClearHistoryAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Clear History", isPresented: $showClearHistoryAlert) {
                    Button("Clear All", role: .destructive) {
                        coordinator.clearSessionHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Clear all recent dictations? This cannot be undone.")
                }
            }
        }
    }

    private func recentRow(_ candidate: TranscriptCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(candidate.rawText.prefix(80)) + (candidate.rawText.count > 80 ? "..." : ""))
                    .font(VF.labelFont)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(candidate.selectedMode.displayName)
                        .font(VF.captionFont.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(relativeTime(candidate.timestamp))
                        .font(VF.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(spacing: 4) {
                Button("Insert") {
                    coordinator.insertRecentDictation(candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(candidate.text(for: candidate.selectedMode), forType: .string)
                    state.statusLine = "Copied to clipboard"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: VF.cornerSmall))
    }

    private var recordingStateCard: some View {
        VStack(alignment: .center, spacing: VF.spacingMedium) {
            TimelineView(.animation(minimumInterval: 0.08)) { context in
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.red.gradient)
                            .frame(width: 8, height: waveformHeight(index: index, time: context.date.timeIntervalSinceReferenceDate))
                    }
                }
                .frame(height: 54)
            }

            Text(String(format: "%.1f", state.recordingDuration))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)

            Text("Release hotkey to transcribe")
                .font(VF.captionFont)
                .foregroundStyle(.secondary)

            Button("Cancel Capture") {
                coordinator.cancelActiveCapture()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
    }

    private var transcribingStateCard: some View {
        VStack(spacing: VF.spacingMedium) {
            ProgressView()
                .controlSize(.regular)
            Text("Processing… \(transcribingElapsed)s")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)
            if transcribingElapsed > 90 {
                Text("Taking longer than expected…")
                    .font(VF.captionFont)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
        .onAppear { startTranscribingTimer() }
        .onDisappear { stopTranscribingTimer() }
    }

    private func startTranscribingTimer() {
        transcribingElapsed = 0
        transcribingTimer?.invalidate()
        transcribingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                transcribingElapsed += 1
            }
        }
    }

    private func stopTranscribingTimer() {
        transcribingTimer?.invalidate()
        transcribingTimer = nil
        transcribingElapsed = 0
    }

    private var footerBar: some View {
        HStack(spacing: VF.spacingSmall) {
            Button {
                onOpenSetup()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Open Setup Wizard")
            .help("Open Setup Wizard")
            .buttonStyle(.bordered)
            .keyboardShortcut("1", modifiers: [.command])

            Button {
                onOpenDashboardWindow()
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .accessibilityLabel("Open Dashboard")
            .help("Open Dashboard")
            .buttonStyle(.bordered)
            .keyboardShortcut("2", modifiers: [.command])

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Open Settings")
            .help("Open Settings")
            .keyboardShortcut(",", modifiers: [.command])

            Spacer()

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("Quit VoxFlow")
            .help("Quit VoxFlow")
            .buttonStyle(.bordered)
            .keyboardShortcut("q", modifiers: [.command])
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .padding(.horizontal, 16)
    }

    private func appProfilePopover(bundleID: String, appName: String) -> some View {
        let current = state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
            ?? AppProfile(tone: state.toneStyle, cleanupMode: state.selectedMode, insertBehavior: state.insertBehavior)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Profile for \(appName)")
                .font(VF.labelFont.weight(.semibold))

            Picker("Tone", selection: Binding(
                get: { current.tone },
                set: { newTone in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: newTone, cleanupMode: current.cleanupMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
            }

            Picker("Cleanup", selection: Binding(
                get: { current.cleanupMode },
                set: { newMode in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: newMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
            }

            Picker("Insert", selection: Binding(
                get: { current.insertBehavior },
                set: { newBehavior in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: current.cleanupMode, insertBehavior: newBehavior))
                }
            )) {
                ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
            }

            if state.appProfiles[bundleID] != nil {
                Button("Reset to Default") {
                    coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                    showProfilePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }

    private func waveformHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = (time * 3.2) + (Double(index) * 0.9)
        let value = abs(sin(phase))
        return 12 + CGFloat(value * 36)
    }

    private func updateRecordingBadgeAnimation() {
        recordingBadgeAnimating = state.sessionState == .recording
    }

    private var insertDisabled: Bool {
        if state.privacyPreview != nil {
            return true
        }

        if state.displayText.isEmpty {
            return true
        }

        if state.workflowMode == .translateEnToDe {
            return state.translationCandidate?.approved != true
        }

        if state.workflowMode == .meeting {
            return state.meetingCandidate?.approved != true
        }

        return false
    }

    private var sessionBadgeColor: Color {
        if state.isCommandLaneActive {
            return .orange
        }

        switch state.sessionState {
        case .idle, .review:
            return .blue
        case .recording:
            return .orange
        case .transcribing, .inserting:
            return .purple
        case .onboarding:
            return .mint
        case .error:
            return .red
        }
    }

    private var readinessBadgeColor: Color {
        state.backendReadyForDictation ? .green : .orange
    }
}
