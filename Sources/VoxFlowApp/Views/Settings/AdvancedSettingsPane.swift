import SwiftUI

/// Settings > Advanced: experimental workflows, translate profile, backend control, onboarding.
struct AdvancedSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Workflow") {
                Toggle("Protocol commands (experimental)", isOn: Binding(
                    get: { state.protocolCommandsEnabled },
                    set: { coordinator.settings.setProtocolCommandsEnabled($0) }
                ))
                Text("Say \u{201C}run <name> protocol\u{201D} in the voice-control lane or cockpit review to run a workflow chain by voice. The whole phrase must match exactly; low-confidence transcriptions never trigger.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)

                Toggle("Assistant handoff (experimental)", isOn: Binding(
                    get: { state.assistantHandoffEnabled },
                    set: { coordinator.settings.setAssistantHandoffEnabled($0) }
                ))
                if state.assistantHandoffEnabled {
                    TextField("Agent command (receives transcript on stdin)", text: Binding(
                        get: { state.assistantHandoffCommand },
                        set: { coordinator.settings.updateAssistantHandoffCommand($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Example: claude -p — the cockpit transcript is piped to this command after you approve a visible preview. The response is only displayed; nothing executes automatically.")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Enable Experimental Translate Mode (EN→DE)",
                    isOn: Binding(
                        get: { state.translationModeEnabled },
                        set: { coordinator.setTranslationModeEnabled($0) }
                    )
                )

                Toggle(
                    "Enable Experimental Meeting Mode",
                    isOn: Binding(
                        get: { state.meetingModeEnabled },
                        set: { coordinator.setMeetingModeEnabled($0) }
                    )
                )

                Toggle(
                    "Enable Experimental Prompt Mode",
                    isOn: Binding(
                        get: { state.promptModeEnabled },
                        set: { coordinator.setPromptModeEnabled($0) }
                    )
                )

                Text("Dictation mode is always enabled as the release-quality core workflow.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)

                Text("Host memory: \(state.hostMemoryGB) GB")
                    .font(VF.labelFont)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(TranslationProfile.allCases) { profile in
                        profileRow(profile)
                    }
                }
                .padding(.top, 4)

                Text(state.translationProfile.runtimeHint(forHostMemoryGB: state.hostMemoryGB).summary)
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)

                Text("Changing translate model restarts backend automatically.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            Section("Backend") {
                HStack {
                    Button("Start Backend") {
                        coordinator.startBackend()
                    }

                    Button("Stop Backend") {
                        coordinator.stopBackend()
                    }
                }

                Button("Recheck Readiness") {
                    coordinator.refreshReadiness()
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(backendStatusColor)
                            .frame(width: 8, height: 8)
                        Text(state.backendReadiness.statusSummary)
                            .font(VF.captionEmphasizedFont)
                            .foregroundStyle(backendStatusColor)
                    }

                    if state.backendReadiness.warmupInProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Backend process is running and waiting to answer readiness checks.")
                                .font(VF.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !state.backendReadiness.activeSTTModel.isEmpty {
                        Text("Active STT path: \(state.backendReadiness.activeSTTModel)")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }

                    if let issue = state.backendReadiness.readinessIssue, !issue.isEmpty {
                        Text("Issue: \(issue)")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Onboarding") {
                Button("Open Setup Wizard") {
                    openWindow(id: "setup")
                }

                Button("Run Calibration Again") {
                    coordinator.restartOnboardingCalibration()
                    openWindow(id: "setup")
                }
            }

        }
        .formStyle(.grouped)
    }

    private var backendStatusColor: Color {
        if !state.backendShouldRun && !state.backendReadiness.processRunning && !state.backendReadiness.warmupInProgress {
            return VF.colorNeutral
        }
        if state.backendReadiness.readyForDictation {
            return VF.colorSuccess
        }
        if state.backendReadiness.warmupInProgress {
            return VF.colorWarning
        }
        return VF.colorError
    }

    private func profileRow(_ profile: TranslationProfile) -> some View {
        let hint = profile.runtimeHint(forHostMemoryGB: state.hostMemoryGB)
        let selected = state.translationProfile == profile

        return Button {
            coordinator.selectTranslationProfile(profile)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)

                Text(profile.displayName)
                    .font(selected ? VF.bodyEmphasizedFont : VF.bodyFont)
                    .foregroundStyle(.primary)

                Spacer()

                Text(hint.badge)
                    .font(VF.captionEmphasizedFont)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(suitabilityColor(hint.suitability).opacity(0.18))
                    .foregroundStyle(suitabilityColor(hint.suitability))
                    .clipShape(Capsule())
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func suitabilityColor(_ suitability: TranslationSuitability) -> Color {
        switch suitability {
        case .recommended:
            return VF.colorSuccess
        case .caution:
            return VF.colorWarning
        case .heavy:
            return VF.colorError
        }
    }
}
