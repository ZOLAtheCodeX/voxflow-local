import SwiftUI

/// Settings > Voice: vocabulary, voice snippets, skill profiles, voice actions, workflow chains.
struct VoiceSettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var snippetStore: SnippetStore
    @ObservedObject var chainStore: ChainStore
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

    var body: some View {
        Form {
            VocabularySettingsSection(dictionary: dictionary)

            Section("Voice snippets") {
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

            SkillProfileSettingsSection(store: coordinator.skillProfiles)

            ComputerActionSettingsSection(settings: coordinator.computerActionSettings,
                selectMode: coordinator.selectVoiceActionMode, setEnabled: coordinator.setComputerActionEnabled,
                setRequiresPrefix: coordinator.setComputerActionRequiresPrefix)

            Section("Workflow chains") {
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

                    Button("Add Step") {
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
        }
        .formStyle(.grouped)
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
