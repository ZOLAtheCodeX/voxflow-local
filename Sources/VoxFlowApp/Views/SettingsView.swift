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
    @State private var localVoxtralModelDraft = ""
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

                Toggle(
                    "Voxtral Safe Mode (recommended on 16GB)",
                    isOn: Binding(
                        get: { state.voxtralSafeModeEnabled },
                        set: { coordinator.setVoxtralSafeModeEnabled($0) }
                    )
                )

                Text(state.voxtralSafeModeEnabled
                     ? "Safe mode is ON: backend skips heavy Voxtral primary load and keeps fallback path active to reduce OOM risk."
                     : "Safe mode is OFF: backend attempts pure Voxtral primary. This may crash under memory pressure on 16GB machines.")
                    .font(.system(size: 11))
                    .foregroundStyle(state.voxtralSafeModeEnabled ? Color.secondary : Color.orange)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Local Voxtral Model", text: $localVoxtralModelDraft)
                        .textFieldStyle(.roundedBorder)
                    TextField("Local Whisper Model", text: $localWhisperModelDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Apply Local Speech Models") {
                        coordinator.updateLocalSpeechModels(
                            voxtralModel: localVoxtralModelDraft,
                            whisperModel: localWhisperModelDraft
                        )
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
            localVoxtralModelDraft = state.localVoxtralModel
            localWhisperModelDraft = state.localWhisperModel
        }
    }

    private var sttBackendNote: String {
        switch state.sttBackend {
        case .voxtral:
            return "Voxtral local STT is optimized for your default offline workflow."
        case .whisper:
            return "Whisper local STT uses an open-source OpenAI Whisper model on-device."
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
