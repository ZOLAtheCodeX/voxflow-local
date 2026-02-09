import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var onOpenDashboardWindow: () -> Void = {}
    @State private var activePanel: ActivePanel = .dashboard

    private enum ActivePanel: String, CaseIterable, Identifiable {
        case dashboard
        case capture
        case recent

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .dashboard:
                return "Dashboard"
            case .capture:
                return "Capture"
            case .recent:
                return "Recent"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if state.onboardingPhase == .calibrating {
                OnboardingCalibrationView(coordinator: coordinator, state: state)
            } else {
                mainDictationCard
            }

            if let error = state.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical, 12)
        .background(state.isCommandLaneActive ? Color.orange.opacity(0.08) : Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("VoxFlow Local")
                        .font(.system(size: 15, weight: .semibold))
                    if state.isCommandLaneActive {
                        Text("SYSTEM COMMAND")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(0.24))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                Text(state.statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("Dictate: Ctrl+Opt+Space · Commands: Fn+Cmd+Space")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(state.sessionState.rawValue.capitalized)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(sessionBadgeColor.opacity(0.22))
                .foregroundStyle(sessionBadgeColor)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
    }

    private var mainDictationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.canStartCaptureForDictation ? "Target Ready" : "No Text Target")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.canStartCaptureForDictation ? .green : .orange)
                Spacer()
                Text(state.focusTarget.appName ?? "No active app")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker("Panel", selection: $activePanel) {
                ForEach(ActivePanel.allCases) { panel in
                    Text(panel.displayName).tag(panel)
                }
            }
            .pickerStyle(.segmented)

            if activePanel == .dashboard {
                DashboardPanelView(coordinator: coordinator, state: state) {
                    activePanel = .capture
                } onOpenFullDashboard: {
                    onOpenDashboardWindow()
                }
            } else if activePanel == .recent {
                recentDictationsPanel
            } else {
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }

                Picker("Mode", selection: Binding(
                    get: { state.workflowMode },
                    set: { coordinator.selectWorkflowMode($0) }
                )) {
                    ForEach(WorkflowMode.allCases) { mode in
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
                    }
                }

                HStack(spacing: 10) {
                    Button("Insert") {
                        coordinator.insertCurrentText()
                    }
                    .buttonStyle(.borderedProminent)
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

                    Spacer()
                }
            }
        }
        .padding(16)
    }

    private func privacyReview(preview: PrivacyPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Privacy Review")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Original")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(preview.originalText)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .lineLimit(4)

            Text("Redacted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(preview.redactedText)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
            }
        }
    }

    private var dictationReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if state.displayText.isEmpty {
                    Text("Hold Ctrl+Opt+Space to dictate. Use Fn+Cmd+Space for command lane.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(state.displayText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(size: 14))
            .frame(minHeight: 92, maxHeight: 120)
            .padding(10)
            .background(Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                ForEach(CleanupMode.allCases) { mode in
                    ModeChip(mode: mode, selected: state.selectedMode == mode) {
                        coordinator.selectCleanupMode(mode)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Tone")
                    .font(.system(size: 12, weight: .semibold))
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
        }
    }

    private var translationReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let candidate = state.translationCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured English")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.sourceEnglish)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("German Output")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(candidate.targetGerman)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.green.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var meetingReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let meeting = state.meetingCandidate {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Captured Transcript")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(meeting.transcript)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .lineLimit(4)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Structured Notes")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(meeting.formattedNotes)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 100, maxHeight: 150)
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if !meeting.speakerSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Speaker Segments")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.speakerSegments) { segment in
                                Text("• \(segment.speaker) (\(segment.utteranceCount)): \(segment.text)")
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                if !meeting.taskOwners.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Task Owners")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(meeting.taskOwners) { owner in
                                let confidence = Int((owner.confidence * 100).rounded())
                                Text("• \(owner.task) -> \(owner.owner) (\(confidence)%)")
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var recentDictationsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.recentDictations.isEmpty {
                Text("No recent dictations this session.")
                    .font(.system(size: 13))
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
            }
        }
    }

    private func recentRow(_ candidate: TranscriptCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(candidate.rawText.prefix(80)) + (candidate.rawText.count > 80 ? "..." : ""))
                    .font(.system(size: 12))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(candidate.selectedMode.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(relativeTime(candidate.timestamp))
                        .font(.system(size: 10))
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
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
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
}
