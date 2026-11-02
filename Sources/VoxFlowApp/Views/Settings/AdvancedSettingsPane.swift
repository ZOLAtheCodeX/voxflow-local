import SwiftUI

/// Settings > Advanced: experimental workflows and translate profile, integrations
/// (assistant handoff, Notion token), engine (backend) control, setup.
struct AdvancedSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    let secretLoader: SecretLoader
    @State private var notionToken: String = ""
    @State private var draftsLoaded = false

    var body: some View {
        Form {
            Section("Experimental") {
                Toggle("Protocol commands (experimental)", isOn: Binding(
                    get: { state.protocolCommandsEnabled },
                    set: { coordinator.settings.setProtocolCommandsEnabled($0) }
                ))
                Text("Say \u{201C}run <name> protocol\u{201D} in voice control or cockpit review to run a workflow chain by voice. The whole phrase must match exactly; low-confidence transcriptions never trigger.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)

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

                Text("Changing the translate model restarts the engine automatically.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            Section("Integrations") {
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
                    Text("Example: claude -p. The cockpit transcript is piped to this command after you approve a visible preview. The response is only displayed; nothing executes automatically.")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }

                SecureField("Notion personal access token", text: $notionToken)
                Button("Save Token") {
                    KeychainService.save(account: NotionKeychain.account, value: notionToken)
                }
                if secretLoader(NotionKeychain.account)?.isEmpty == false {
                    Label("Token stored in Keychain", systemImage: "checkmark.seal")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
                Text("Create a personal access token in the Developer portal of Notion, under Personal access tokens, and grant it the \u{201C}Notion API\u{201D} capability. No page sharing is needed: it uses your own access and expires after one year.")
                    .font(VF.captionFont).foregroundStyle(.secondary)
            }

            Section("Engine (backend)") {
                HStack {
                    Button("Start Engine") {
                        coordinator.startBackend()
                    }

                    Button("Stop Engine") {
                        coordinator.stopBackend()
                    }
                }

                Button("Recheck Readiness") {
                    coordinator.refreshReadiness()
                }

                VStack(alignment: .leading, spacing: 6) {
                    VFStatusBadge(
                        status: VFStatus.engine(state.backendReadiness, backendShouldRun: state.backendShouldRun)
                    )

                    Text(state.backendReadiness.statusSummary)
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)

                    if state.backendReadiness.warmupInProgress {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("The engine is running and waiting to answer readiness checks.")
                                .font(VF.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !state.backendReadiness.activeSTTModel.isEmpty {
                        Text("Speech model in use: \(state.backendReadiness.activeSTTModel)")
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

            Section("Setup") {
                Button("Open Setup") {
                    openWindow(id: "setup")
                }

                Button("Run Calibration Again") {
                    coordinator.restartOnboardingCalibration()
                    openWindow(id: "setup")
                }
            }

        }
        .formStyle(.grouped)
        .onAppear {
            guard !draftsLoaded else { return }
            draftsLoaded = true
            notionToken = secretLoader(NotionKeychain.account) ?? ""
        }
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
