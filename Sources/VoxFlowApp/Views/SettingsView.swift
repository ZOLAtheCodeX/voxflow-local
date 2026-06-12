import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var snippetStore: SnippetStore
    @ObservedObject var chainStore: ChainStore
    @ObservedObject var providerStore: ProviderConfigStore
    @State private var newWrong = ""
    @State private var newRight = ""
    @State private var newSnippetKeyword = ""
    @State private var newSnippetText = ""
    @State private var newSnippetScope: SnippetScope = .global
    @State private var editingSnippetId: UUID? = nil
    // Workflow chain editor (Phase E)
    @State private var newChainName = ""
    @State private var newChainSteps: [ChainStep] = []
    @State private var editingChainId: UUID? = nil
    @State private var draftStepKind: ChainStepKind = .action
    @State private var draftActionId: SmartActionId = .memo
    @State private var draftCaptureMode: CaptureMode = .quick
    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var permissionPollTimer: Timer?
    @State private var privateAPIBaseURLDraft = ""
    @State private var privateAPIModelDraft = ""
    @State private var privateAPIKeyDraft = ""
    @State private var newProviderID = ""
    @State private var newProviderKind: ProviderKind = .openaiCompat
    @State private var newProviderBaseURL = ""
    @State private var newProviderModel = ""
    @State private var newProviderKey = ""
    @State private var providerTestResults: [String: String] = [:]
    @State private var openAIBaseURLDraft = ""
    @State private var openAIAPIKeyDraft = ""
    @State private var openAISTTModelDraft = ""
    @State private var openAITTSModelDraft = ""
    @State private var openAITTSVoiceDraft = ""
    @State private var localWhisperModelDraft = ""
    @State private var ollamaStatus: OllamaModelsResponse?
    @State private var ollamaLoadError: String?
    @State private var ollamaPullProgress: String?
    @State private var ollamaPullActive: Bool = false
    @State private var ollamaPullTargetModel: String = ""
    @State private var notionToken: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            modelsTab
                .tabItem { Label("Models", systemImage: "brain") }
            toolsTab
                .tabItem { Label("Dictation Tools", systemImage: "text.badge.star") }
            privacyTab
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            permissionsTab
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 560)
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
        .onAppear {
            refreshPermissions()
            privateAPIBaseURLDraft = state.privateAPIBaseURL
            privateAPIModelDraft = state.privateAPIModel
            privateAPIKeyDraft = KeychainService.load(account: SettingsCoordinator.keychainPrivateAPIKeyAccount) ?? ""
            openAIBaseURLDraft = state.openAIBaseURL
            openAIAPIKeyDraft = KeychainService.load(account: SettingsCoordinator.keychainOpenAIAPIKeyAccount) ?? ""
            openAISTTModelDraft = state.openAISTTModel
            openAITTSModelDraft = state.openAITTSModel
            openAITTSVoiceDraft = state.openAITTSVoice
            localWhisperModelDraft = state.localWhisperModel
            notionToken = KeychainService.load(account: NotionKeychain.account) ?? ""
        }
    }

    private var generalTab: some View {
        Form {
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
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
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
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)

                Divider()

                Text("App Profiles")
                    .font(VF.labelFont)

                if state.appProfiles.isEmpty {
                    Text("No custom overrides. Apps use your selected settings or built-in defaults (Slack → Concise, Mail → Formal, etc).")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.appProfiles.keys.sorted()), id: \.self) { bundleID in
                        if let profile = state.appProfiles[bundleID] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(bundleID.components(separatedBy: ".").last ?? bundleID)
                                        .font(VF.labelFont)
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
                                .font(VF.captionFont)
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
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var modelsTab: some View {
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
                    }
                }
                Text("Chains fall back to Ollama, then the local regex pipeline — dictation keeps working offline no matter what.")
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
    }

    private var toolsTab: some View {
        Form {
            Section("Dictionary") {
                if dictionary.entries.isEmpty {
                    Text("No corrections yet. Fix a mangled term in the cockpit review to teach VoxFlow.")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
                ForEach(dictionary.entries) { entry in
                    HStack {
                        Text(entry.wrong).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(entry.right)
                        Spacer()
                        Button(role: .destructive) { dictionary.remove(entry.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("recognized", text: $newWrong)
                    Image(systemName: "arrow.right")
                    TextField("correct", text: $newRight)
                    Button("Add") {
                        guard !newWrong.isEmpty, !newRight.isEmpty else { return }
                        dictionary.add(wrong: newWrong, right: newRight, context: "manual")
                        newWrong = ""; newRight = ""
                    }
                }
            }

            Section("Voice Snippets") {
                if snippetStore.snippets.isEmpty {
                    Text("No snippets yet. Add a keyword and the expansion VoxFlow inserts when you say it.")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
                ForEach(snippetStore.snippets) { snippet in
                    HStack {
                        Text(snippet.keyword).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(snippet.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(snippet.scope.label)
                            .font(VF.captionFont)
                            .foregroundStyle(.tertiary)
                        Button {
                            newSnippetKeyword = snippet.keyword
                            newSnippetText = snippet.text
                            newSnippetScope = snippet.scope
                            editingSnippetId = snippet.id
                        } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            if editingSnippetId == snippet.id {
                                editingSnippetId = nil
                                newSnippetKeyword = ""
                                newSnippetText = ""
                                newSnippetScope = .global
                            }
                            snippetStore.remove(snippet.id)
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("keyword", text: $newSnippetKeyword)
                    TextField("expansion", text: $newSnippetText)
                    Picker("", selection: $newSnippetScope) {
                        ForEach(SnippetScope.allCases, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }.labelsHidden()
                    Button(editingSnippetId == nil ? "Add" : "Update") {
                        guard !newSnippetKeyword.isEmpty, !newSnippetText.isEmpty else { return }
                        let succeeded: Bool
                        if let id = editingSnippetId {
                            succeeded = snippetStore.update(id: id, keyword: newSnippetKeyword, text: newSnippetText, scope: newSnippetScope)
                        } else {
                            succeeded = snippetStore.add(keyword: newSnippetKeyword, text: newSnippetText, scope: newSnippetScope)
                        }
                        // Only clear the draft on success; on failure (e.g. multi-word keyword)
                        // leave the input populated so the user can correct it.
                        if succeeded {
                            newSnippetKeyword = ""; newSnippetText = ""
                            newSnippetScope = .global
                            editingSnippetId = nil
                        }
                    }
                }
            }

            Section("Workflow Chains") {
                if chainStore.chains.isEmpty {
                    Text("No chains yet. Build a named sequence of actions VoxFlow runs over the captured transcript from the ⌘K palette.")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
                ForEach(chainStore.chains) { chain in
                    HStack {
                        Text(chain.name)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(chain.steps.map(\.summary).joined(separator: " → "))
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button {
                            newChainName = chain.name
                            newChainSteps = chain.steps
                            editingChainId = chain.id
                        } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.borderless)
                        Button(role: .destructive) {
                            if editingChainId == chain.id { resetChainDraft() }
                            chainStore.remove(chain.id)
                        } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }

                // Draft editor: name + an ordered list of steps assembled one at a time.
                TextField("chain name", text: $newChainName)

                if newChainSteps.isEmpty {
                    Text("Add at least one step below.")
                        .font(VF.captionFont).foregroundStyle(.tertiary)
                }
                ForEach(Array(newChainSteps.enumerated()), id: \.offset) { index, step in
                    HStack {
                        Text("\(index + 1). \(step.summary)")
                            .font(VF.captionFont)
                        Spacer()
                        Button(role: .destructive) {
                            newChainSteps.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless)
                    }
                }

                HStack {
                    Picker("", selection: $draftStepKind) {
                        ForEach(ChainStepKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }.labelsHidden()

                    switch draftStepKind {
                    case .capture:
                        Picker("", selection: $draftCaptureMode) {
                            ForEach(CaptureMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }.labelsHidden()
                    case .action:
                        Picker("", selection: $draftActionId) {
                            ForEach(SmartActionId.allCases, id: \.self) { id in
                                Text(id.label).tag(id)
                            }
                        }.labelsHidden()
                    case .insert:
                        Text("inserts current text")
                            .font(VF.captionFont).foregroundStyle(.tertiary)
                    }

                    Button("Add step") {
                        newChainSteps.append(draftStepKind.makeStep(action: draftActionId, mode: draftCaptureMode))
                    }
                }

                HStack {
                    Spacer()
                    Button(editingChainId == nil ? "Add Chain" : "Update Chain") {
                        guard !newChainName.isEmpty, !newChainSteps.isEmpty else { return }
                        let succeeded: Bool
                        if let id = editingChainId {
                            succeeded = chainStore.update(id: id, name: newChainName, steps: newChainSteps)
                        } else {
                            succeeded = chainStore.add(name: newChainName, steps: newChainSteps)
                        }
                        // Only clear the draft on success; on failure (empty/duplicate
                        // name) leave it populated so the user can correct it.
                        if succeeded { resetChainDraft() }
                    }
                    .disabled(newChainName.isEmpty || newChainSteps.isEmpty)
                }
            }

            Section("Notion") {
                SecureField("Personal access token", text: $notionToken)
                Button("Save token") {
                    KeychainService.save(account: NotionKeychain.account, value: notionToken)
                }
                if KeychainService.load(account: NotionKeychain.account)?.isEmpty == false {
                    Label("Token stored in Keychain", systemImage: "checkmark.seal")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
                Text("Create a Personal Access Token in Notion's Developer portal → Personal access tokens (grant the “Notion API” capability). No page-sharing needed — it uses your own access; expires after 1 year.")
                    .font(VF.captionFont).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
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
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
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

    private var permissionsTab: some View {
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
                        startPermissionPolling()
                    }
                }

                Button("Refresh Permissions") {
                    refreshPermissions()
                }
            }

        }
        .formStyle(.grouped)
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
                var chain = [newPrimary]
                // Keep local Ollama as the availability fallback unless it IS the primary.
                if newPrimary != "ollama", providerStore.providers.contains(where: { $0.id == "ollama" }) {
                    chain.append("ollama")
                }
                providerStore.setChain(task: task, providerIDs: chain)
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
                providerTestResults[providerID] = "✕ Backend unreachable — start the backend first"
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

    private func refreshPermissions() {
        permissions = coordinator.permissionSnapshot()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                let snap = coordinator.permissionSnapshot()
                permissions = snap
                if snap.accessibilityAuthorized {
                    permissionPollTimer?.invalidate()
                    permissionPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func resetChainDraft() {
        newChainName = ""
        newChainSteps = []
        editingChainId = nil
        draftStepKind = .action
        draftActionId = .memo
        draftCaptureMode = .quick
    }
}

/// UI-only step-kind selector for the Settings chain editor — keeps the editor's
/// Picker flat (one case per `ChainStep` variant) and builds the concrete step
/// from the editor's draft selections.
private enum ChainStepKind: String, CaseIterable {
    case capture, action, insert

    var label: String {
        switch self {
        case .capture: "Capture"
        case .action: "Action"
        case .insert: "Insert"
        }
    }

    func makeStep(action: SmartActionId, mode: CaptureMode) -> ChainStep {
        switch self {
        case .capture: .capture(mode: mode)
        case .action: .action(actionId: action)
        case .insert: .insert(targetHint: nil)
        }
    }
}
