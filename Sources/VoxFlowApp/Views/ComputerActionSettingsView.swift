import SwiftUI

struct VoiceActionModeMenu: View {
    @ObservedObject var settings: ComputerActionSettings
    let selectMode: (VoiceActionMode) -> Void

    var body: some View {
        Menu("Voice actions: \(settings.mode.displayName)") {
            ForEach(VoiceActionMode.allCases) { mode in
                Button { selectMode(mode) } label: {
                    if settings.mode == mode { Label(mode.displayName, systemImage: "checkmark") }
                    else { Text(mode.displayName) }
                }
            }
        }
        .accessibilityLabel("Voice actions: \(settings.mode.displayName)")
    }
}

struct ComputerActionSettingsSection: View {
    @ObservedObject var settings: ComputerActionSettings
    let selectMode: (VoiceActionMode) -> Void
    let setEnabled: (Bool, String) -> Void
    let setRequiresPrefix: (Bool) -> Void

    var body: some View {
        Section("Voice action controls") {
            Picker("Allow voice actions", selection: Binding(get: { settings.mode }, set: { selectMode($0) })) {
                ForEach(VoiceActionMode.allCases) { mode in Text(mode.displayName).tag(mode) }
            }
            Text("Custom prompts use your selected skill profile below. Off keeps quick capture as dictation.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            Picker("Command phrases", selection: Binding(get: { settings.requiresPrefix }, set: setRequiresPrefix)) {
                Text("Require ‘Voxflow’").tag(true)
                Text("With or without ‘Voxflow’").tag(false)
            }
            Text(settings.requiresPrefix
                ? "Say the complete command, such as ‘Voxflow, copy that’."
                : "Say ‘copy that’ or ‘Voxflow, copy that’. Only complete commands trigger actions; longer sentences stay dictation. Use your usual dictation hotkey.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            DisclosureGroup("Built-in computer actions (\(settings.enabledIDs.count) selected)") {
                ForEach(settings.catalog.actions) { action in
                    Toggle(isOn: Binding(get: { settings.enabledIDs.contains(action.id) },
                                         set: { setEnabled($0, action.id) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.name).font(VF.bodyFont)
                            Text(action.examples(requiresPrefix: settings.requiresPrefix)).font(VF.captionFont).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Shortcuts act only in the original focused input and use that app’s normal shortcuts. Paste never adds Enter. New tab and Find depend on support in the receiving app.")
                    .font(VF.captionFont).foregroundStyle(.secondary)
            }
            if let error = settings.loadError { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
        }
    }
}
