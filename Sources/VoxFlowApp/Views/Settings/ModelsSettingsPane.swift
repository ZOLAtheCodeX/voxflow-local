import SwiftUI

/// Settings > Models: local Ollama model, speech models, BYOM providers, translate benchmark.
struct ModelsSettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var providerStore: ProviderConfigStore
    let secretLoader: SecretLoader
    @State private var newProviderID = ""
    @State private var newProviderKind: ProviderKind = .openaiCompat
    @State private var newProviderBaseURL = ""
    @State private var newProviderModel = ""
    @State private var newProviderKey = ""
    @State private var providerTestResults: [String: String] = [:]
    @State private var openAIBaseURLDraft = ""
    @State private var openAIAPIKeyDraft = ""
    @State private var openAISTTModelDraft = ""
    @State private var localWhisperModelDraft = ""
    @State private var draftsLoaded = false
    @State private var ollamaStatus: OllamaModelsResponse?
    @State private var ollamaLoadError: String?
    @State private var ollamaPullProgress: String?
    @State private var ollamaPullActive: Bool = false
    @State private var ollamaPullTargetModel: String = ""

    var body: some View {
        Form {
            Section("Local AI Model") {
                ollamaStatusRow
                if let status = ollamaStatus {
                    if !status.models.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Installed models").font(VF.captionEmphasizedFont)
                            ForEach(status.models) { model in
                                HStack {
                                    Text(model.name).font(VF.captionFont)
                                    Spacer()
                                    Text(formatBytes(model.size))
                                        .font(VF.monoCaptionFont)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let recommended = status.recommendedModel,
                       !status.models.contains(where: { $0.name == recommended }) {
                        HStack {
                            Text("Recommended: \(recommended)")
                                .font(VF.captionFont)
                            Spacer()
                            Button(ollamaPullActive ? "Pulling…" : "Pull Model") {
                                pullModel(recommended)
                            }
                            .disabled(ollamaPullActive || !status.available)
                        }
                        if let progress = ollamaPullProgress {
                            Text(progress)
                                .font(VF.monoMicroFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text("Host memory: \(String(format: "%.1f", status.hostMemoryGb)) GB")
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                }
                if let error = ollamaLoadError {
                    Text(error)
                        .font(VF.captionFont)
                        .foregroundStyle(VF.colorExternal)
                }
            }
            .task { await refreshOllamaStatus() }

            if !state.backendReadiness.ollamaAvailable && !state.ollamaNudgeDismissed {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(VF.colorInfo)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ollama not detected")
                                    .font(VF.labelFont)
                                Text("Install Ollama and pull a Gemma 4 model for higher-quality polish. The dictation flow keeps working without it.")
                                    .font(VF.captionFont)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Dismiss") {
                                state.ollamaNudgeDismissed = true
                                UserDefaults.standard.set(true, forKey: "VoxFlow.ollamaNudgeDismissed")
                            }
                            .buttonStyle(.borderless)
                            .font(VF.captionFont)
                        }
                    }
                    .padding(.vertical, 4)
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
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)

                if state.sttBackend == .whisper {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Local Whisper Model", text: $localWhisperModelDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Apply Local Whisper Model") {
                            coordinator.updateLocalWhisperModel(whisperModel: localWhisperModelDraft)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }

                if state.sttBackend == .openAI {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("OpenAI Base URL", text: $openAIBaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                        SecureField("OpenAI API Key", text: $openAIAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        TextField("OpenAI STT Model", text: $openAISTTModelDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Apply OpenAI Speech Config") {
                            coordinator.updateOpenAIConfig(
                                baseURL: openAIBaseURLDraft,
                                apiKey: openAIAPIKeyDraft,
                                sttModel: openAISTTModelDraft
                            )
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                }
            }

            Section("Model Providers (BYOM)") {
                ForEach(providerStore.providers) { spec in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(spec.id).font(VF.captionEmphasizedFont)
                            Text(spec.kind.rawValue)
                                .font(VF.microFont)
                                .foregroundStyle(.secondary)
                            if let model = spec.model, !model.isEmpty {
                                Text(model).font(VF.monoCaptionFont).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Test") { testProvider(spec.id) }
                            if spec.id != "ollama" {
                                Button(role: .destructive) {
                                    providerStore.remove(id: spec.id)
                                    applyProviderChanges()
                                } label: { Image(systemName: "trash") }
                            }
                        }
                        if let result = providerTestResults[spec.id] {
                            Text(result).font(VF.microFont).foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(ProviderConfigStore.tasks, id: \.self) { task in
                    Picker(task == "polish" ? "Polish provider" : "Smart-action provider", selection: chainPrimaryBinding(for: task)) {
                        ForEach(providerStore.providers.map(\.id), id: \.self) { pid in
                            Text(pid).tag(pid)
                        }
                        if task == "polish" {
                            Text("Local rules only").tag(ProviderConfigStore.rulesSentinel)
                        }
                    }
                }
                Text("Chains fall back to Ollama, then the local regex pipeline — dictation keeps working offline no matter what. \"Local rules only\" skips LLM polish entirely and never loads a model.")
                    .font(VF.microFont)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add provider").font(VF.captionEmphasizedFont)
                    TextField("Identifier (e.g. lmstudio, claude)", text: $newProviderID)
                        .textFieldStyle(.roundedBorder)
                    Picker("Type", selection: $newProviderKind) {
                        ForEach(ProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    if newProviderKind == .ollama || newProviderKind == .openaiCompat {
                        TextField("Base URL (e.g. http://localhost:1234)", text: $newProviderBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField("Model id", text: $newProviderModel)
                        .textFieldStyle(.roundedBorder)
                    if newProviderKind.isCloud {
                        SecureField("API key (stored in Keychain)", text: $newProviderKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Add Provider") { addProvider() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newProviderID.trimmingCharacters(in: .whitespaces).isEmpty)
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
                                    .font(VF.labelFont)
                                Spacer()
                                if result.placeholderDetected {
                                    Text("Model Missing")
                                        .font(VF.captionEmphasizedFont)
                                        .foregroundStyle(VF.colorExternal)
                                } else {
                                    Text("med \(result.medianLatencyMs)ms · p95 \(result.p95LatencyMs)ms")
                                        .font(VF.captionEmphasizedFont)
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
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .onAppear {
            guard !draftsLoaded else { return }
            draftsLoaded = true
            openAIBaseURLDraft = state.openAIBaseURL
            openAIAPIKeyDraft = secretLoader(SettingsCoordinator.keychainOpenAIAPIKeyAccount) ?? ""
            openAISTTModelDraft = state.openAISTTModel
            localWhisperModelDraft = state.localWhisperModel
        }
    }

    private var sttBackendNote: String {
        switch state.sttBackend {
        case .whisper:
            return "Whisper local STT uses an open-source OpenAI Whisper model on-device. If it fails, audio stays local unless you enable the OpenAI fallback (off by default)."
        case .whisperKit:
            return "WhisperKit runs Whisper on Apple Neural Engine. Fastest local option. No network access."
        case .openAI:
            return "OpenAI STT sends microphone audio to your configured OpenAI endpoint."
        }
    }

    @ViewBuilder private var ollamaStatusRow: some View {
        HStack {
            Text("Ollama")
            Spacer()
            if let status = ollamaStatus {
                Text(status.available ? "Reachable" : "Not running")
                    .foregroundStyle(status.available ? .green : .secondary)
            } else if ollamaLoadError != nil {
                Text("Error")
                    .foregroundStyle(VF.colorExternal)
            } else {
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
            Button("Refresh") {
                Task { await refreshOllamaStatus() }
            }
            .buttonStyle(.borderless)
            .font(VF.captionFont)
        }
        .font(VF.secondaryFont)
    }

    @MainActor
    private func chainPrimaryBinding(for task: String) -> Binding<String> {
        Binding(
            get: { providerStore.chains[task]?.first ?? "ollama" },
            set: { newPrimary in
                if newPrimary == ProviderConfigStore.rulesSentinel {
                    // Rules-only is a full stop: no LLM fallback appended.
                    providerStore.setChain(task: task, providerIDs: [newPrimary])
                } else {
                    var chain = [newPrimary]
                    // Keep local Ollama as the availability fallback unless it IS the primary.
                    if newPrimary != "ollama", providerStore.providers.contains(where: { $0.id == "ollama" }) {
                        chain.append("ollama")
                    }
                    providerStore.setChain(task: task, providerIDs: chain)
                }
                applyProviderChanges()
            }
        )
    }

    private func addProvider() {
        let id = newProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = ProviderSpecModel(
            id: id,
            kind: newProviderKind,
            baseURL: newProviderBaseURL.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newProviderBaseURL.trimmingCharacters(in: .whitespaces),
            model: newProviderModel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : newProviderModel.trimmingCharacters(in: .whitespaces)
        )
        guard providerStore.add(spec) else { return }
        let key = newProviderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            KeychainService.save(account: ProviderConfigStore.keychainAccount(for: id), value: key)
        }
        newProviderID = ""; newProviderBaseURL = ""; newProviderModel = ""; newProviderKey = ""
        applyProviderChanges()
    }

    private func applyProviderChanges() {
        // The backend reads providers.json at launch; restart so the new
        // registry takes effect (same pattern as every other config apply).
        coordinator.settings.restartBackendWithCurrentConfiguration(status: "Model providers updated")
    }

    private func testProvider(_ providerID: String) {
        providerTestResults[providerID] = "Testing…"
        Task {
            do {
                let result = try await BackendAPIClient.providerTest(providerID: providerID)
                providerTestResults[providerID] = (result.reachable ? "✓ " : "✕ ") + result.detail
            } catch {
                providerTestResults[providerID] = "✕ " + error.localizedDescription
            }
        }
    }

    private func refreshOllamaStatus() async {
        do {
            ollamaStatus = try await BackendAPIClient.ollamaModels()
            ollamaLoadError = nil
        } catch {
            ollamaLoadError = error.localizedDescription
        }
    }

    private func pullModel(_ model: String) {
        guard !ollamaPullActive else { return }
        ollamaPullActive = true
        ollamaPullProgress = "Starting…"
        ollamaPullTargetModel = model
        Task {
            do {
                try await BackendAPIClient.ollamaPull(model: model) { line in
                    Task { @MainActor in
                        ollamaPullProgress = line
                    }
                }
                await MainActor.run {
                    ollamaPullProgress = "Done."
                    ollamaPullActive = false
                }
                await refreshOllamaStatus()
            } catch {
                await MainActor.run {
                    ollamaPullProgress = "Failed: \(error.localizedDescription)"
                    ollamaPullActive = false
                }
            }
        }
    }

    private func formatBytes(_ size: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}
