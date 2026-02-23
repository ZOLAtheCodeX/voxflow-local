import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var privateAPIBaseURLDraft = ""
    @State private var privateAPIModelDraft = ""
    @State private var privateAPIKeyDraft = ""
    @State private var openAIBaseURLDraft = ""
    @State private var openAIAPIKeyDraft = ""
    @State private var openAISTTModelDraft = ""
    @State private var openAITTSModelDraft = ""
    @State private var openAITTSVoiceDraft = ""
    @State private var localWhisperModelDraft = ""

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(permissions.microphoneAuthorized ? "Granted" : "Missing")
                        .foregroundStyle(permissions.microphoneAuthorized ? .green : .orange)
                    Button("Request") {
                        coordinator.requestMicrophonePermission()
                        refreshPermissions()
                    }
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(permissions.accessibilityAuthorized ? "Granted" : "Missing")
                        .foregroundStyle(permissions.accessibilityAuthorized ? .green : .orange)
                    Button("Request") {
                        coordinator.requestAccessibilityPermission()
                        refreshPermissions()
                    }
                }

                Button("Refresh Permissions") {
                    refreshPermissions()
                }
            }

            Section("Hotkeys") {
                Picker(
                    "Dictation hold-to-talk",
                    selection: Binding(
                        get: { state.dictationHotkeyPreset },
                        set: { coordinator.setDictationHotkeyPreset($0) }
                    )
                ) {
                    ForEach(DictationHotkeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                Picker(
                    "Command lane",
                    selection: Binding(
                        get: { state.commandLaneHotkeyPreset },
                        set: { coordinator.setCommandLaneHotkeyPreset($0) }
                    )
                ) {
                    ForEach(CommandLaneHotkeyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                Text("Hotkey changes apply immediately. Avoid combinations reserved by macOS or other apps.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Provider Mode") {
                Picker(
                    "Inference routing",
                    selection: Binding(
                        get: { state.providerMode },
                        set: { coordinator.selectProviderMode($0) }
                    )
                ) {
                    ForEach(ProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if state.providerMode == .privateAPI {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Private API Base URL", text: $privateAPIBaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                        TextField("Private API Model", text: $privateAPIModelDraft)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Private API Key", text: $privateAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Apply Private API Config") {
                            coordinator.updatePrivateAPIConfig(
                                baseURL: privateAPIBaseURLDraft,
                                model: privateAPIModelDraft,
                                apiKey: privateAPIKeyDraft
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Private API calls always require per-request privacy preview and approval.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section("Speech Models") {
                Picker(
                    "STT Backend",
                    selection: Binding(
                        get: { state.sttBackend },
                        set: { coordinator.selectSTTBackend($0) }
                    )
                ) {
                    ForEach(STTBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }

                Text(sttBackendNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Local Whisper Model", text: $localWhisperModelDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Apply Local Whisper Model") {
                        coordinator.updateLocalWhisperModel(whisperModel: localWhisperModelDraft)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("OpenAI Base URL", text: $openAIBaseURLDraft)
                        .textFieldStyle(.roundedBorder)
                    SecureField("OpenAI API Key", text: $openAIAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    TextField("OpenAI STT Model", text: $openAISTTModelDraft)
                        .textFieldStyle(.roundedBorder)
                    TextField("OpenAI TTS Model", text: $openAITTSModelDraft)
                        .textFieldStyle(.roundedBorder)
                    TextField("OpenAI TTS Voice", text: $openAITTSVoiceDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Apply OpenAI Speech Config") {
                        coordinator.updateOpenAIConfig(
                            baseURL: openAIBaseURLDraft,
                            apiKey: openAIAPIKeyDraft,
                            sttModel: openAISTTModelDraft,
                            ttsModel: openAITTSModelDraft,
                            ttsVoice: openAITTSVoiceDraft
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }

            Section("Dictation") {
                Picker(
                    "Insert behavior",
                    selection: Binding(
                        get: { state.insertBehavior },
                        set: { coordinator.selectInsertBehavior($0) }
                    )
                ) {
                    ForEach(InsertBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(insertBehaviorNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Divider()

                Text("App Profiles")
                    .font(.system(size: 12, weight: .semibold))

                if state.appProfiles.isEmpty {
                    Text("No custom overrides. Apps use your selected settings or built-in defaults (Slack → Concise, Mail → Formal, etc).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.appProfiles.keys.sorted()), id: \.self) { bundleID in
                        if let profile = state.appProfiles[bundleID] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(bundleID.components(separatedBy: ".").last ?? bundleID)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Button("Remove") {
                                        coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                HStack(spacing: 12) {
                                    Picker("Tone", selection: Binding(
                                        get: { profile.tone },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: $0, cleanupMode: profile.cleanupMode, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
                                    }
                                    .frame(width: 110)
                                    Picker("Mode", selection: Binding(
                                        get: { profile.cleanupMode },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: $0, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
                                    }
                                    .frame(width: 90)
                                    Picker("Insert", selection: Binding(
                                        get: { profile.insertBehavior },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: profile.cleanupMode, insertBehavior: $0)) }
                                    )) {
                                        ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
                                    }
                                    .frame(width: 150)
                                }
                                .font(.system(size: 11))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            Section("Activation Targeting") {
                Picker("Dictation target", selection: $state.targetingMode) {
                    ForEach(TargetingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(state.targetingMode == .cursorAware
                     ? "Dictation is enabled when an insertion cursor is active in any text target."
                     : "Dictation is enabled only when a text input field is focused.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("Workflow") {
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("Host memory: \(state.hostMemoryGB) GB")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(TranslationProfile.allCases) { profile in
                        profileRow(profile)
                    }
                }
                .padding(.top, 4)

                Text(state.translationProfile.runtimeHint(forHostMemoryGB: state.hostMemoryGB).summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("Changing translate model restarts backend automatically.")
                    .font(.system(size: 11))
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

                Text(state.backendReadyForDictation
                     ? "Backend ready for dictation."
                     : "Backend not ready: \(state.backendReadinessIssue ?? "unknown issue")")
                    .font(.system(size: 11))
                    .foregroundStyle(state.backendReadyForDictation ? .green : .orange)
            }

            Section("Benchmark") {
                Button {
                    Task { await coordinator.runTranslationBenchmark() }
                } label: {
                    HStack {
                        if state.isBenchmarkRunning {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(state.isBenchmarkRunning ? "Benchmark Running..." : "Run Translate Benchmark")
                    }
                }
                .disabled(state.isBenchmarkRunning)

                if !state.translationBenchmarkResults.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.translationBenchmarkResults) { result in
                            HStack {
                                Text(result.profile.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                if result.placeholderDetected {
                                    Text("Model Missing")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("med \(result.medianLatencyMs)ms · p95 \(result.p95LatencyMs)ms")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)

                    Button("Apply Fastest Profile") {
                        coordinator.applyFastestBenchmarkProfile()
                    }
                    .disabled(state.isBenchmarkRunning)
                }

                if let benchmarkStatusLine = state.benchmarkStatusLine {
                    Text(benchmarkStatusLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
        .padding(16)
        .onAppear {
            refreshPermissions()
            privateAPIBaseURLDraft = state.privateAPIBaseURL
            privateAPIModelDraft = state.privateAPIModel
            privateAPIKeyDraft = state.privateAPIKey
            openAIBaseURLDraft = state.openAIBaseURL
            openAIAPIKeyDraft = state.openAIAPIKey
            openAISTTModelDraft = state.openAISTTModel
            openAITTSModelDraft = state.openAITTSModel
            openAITTSVoiceDraft = state.openAITTSVoice
            localWhisperModelDraft = state.localWhisperModel
        }
    }

    private var insertBehaviorNote: String {
        switch state.insertBehavior {
        case .alwaysReview:
            return "Transcribed text is shown for review before insertion. Default behavior."
        case .autoInsertRaw:
            return "Raw transcription is inserted immediately with no cleanup. Fastest path."
        case .autoInsertLight:
            return "Light cleanup is applied then text is inserted automatically."
        case .autoInsertPolish:
            return "Full polish cleanup is applied then text is inserted automatically."
        }
    }

    private var sttBackendNote: String {
        switch state.sttBackend {
        case .whisper:
            return "Whisper local STT uses an open-source OpenAI Whisper model on-device."
        case .whisperKit:
            return "WhisperKit runs Whisper on Apple Neural Engine. Fastest local option. No network access."
        case .openAI:
            return "OpenAI STT sends microphone audio to your configured OpenAI endpoint."
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
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer()

                Text(hint.badge)
                    .font(.system(size: 11, weight: .semibold))
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
            return .green
        case .caution:
            return .orange
        case .heavy:
            return .red
        }
    }

    private func refreshPermissions() {
        permissions = coordinator.permissionSnapshot()
    }
}
