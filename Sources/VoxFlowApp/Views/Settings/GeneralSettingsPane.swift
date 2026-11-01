import SwiftUI

/// Settings > General: hotkeys, dictation behavior, automatic Enter, targeting.
struct GeneralSettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
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
                    "Voice control",
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
            }

            Section("Automatic Enter") {
                Picker("Press Enter after", selection: Binding(
                    get: { state.autoSubmitMode },
                    set: { coordinator.selectAutoSubmitMode($0) }
                )) {
                    ForEach(AutoSubmitMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Press Enter once after successful automatic insertion. Depending on the app, Enter submits a message, runs a command, or adds a new line. Off leaves submission to you.")
                    .font(VF.captionFont).foregroundStyle(.secondary)
            }

            Section("Targeting") {
                Picker("Dictation target", selection: $state.targetingMode) {
                    ForEach(TargetingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text(targetingNote)
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var insertBehaviorNote: String {
        switch state.insertBehavior {
        case .alwaysReview:
            return "Text waits in the VoxFlow panel until you insert it."
        case .autoInsertRaw:
            return "Inserts the transcription as heard, with no cleanup."
        case .autoInsertLight:
            return "Applies light cleanup, then inserts."
        case .autoInsertPolish:
            return "Applies full cleanup, then inserts."
        }
    }

    private var targetingNote: String {
        switch state.targetingMode {
        case .anyApp:
            return "Dictation works in any app. When no text field is available, VoxFlow falls back to the clipboard."
        case .cursorAware:
            return "Dictation is enabled when a text field is focused or an insertion cursor is active."
        case .textFieldOnly:
            return "Dictation is enabled only when a text input field is focused."
        }
    }
}
