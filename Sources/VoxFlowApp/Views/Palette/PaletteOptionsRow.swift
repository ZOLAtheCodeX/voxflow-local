import SwiftUI

/// One options row (Cleanup, Tone, and a ••• menu for the rest) plus a chip
/// for each setting that is not at its default, because those change what a
/// dictation does. Every item calls the coordinator method the old controls
/// called: `selectCleanupMode`, `selectToneStyle`, `updateAppProfile`,
/// `selectVoiceActionMode`, `selectProviderMode`, `selectWorkflowMode`.
struct PaletteOptionsRow: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var onOpenSetup: () -> Void

    @State private var showProfilePopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            HStack(spacing: VF.spacingLarge) {
                cleanupMenu
                toneMenu
                Spacer(minLength: 0)
                moreMenu
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)

            PaletteOptionChips(
                state: state,
                skillProfiles: coordinator.skillProfiles,
                voiceActions: coordinator.computerActionSettings)

            if privateAPINeedsSettings {
                VFBanner(kind: .warning, message: "Private API needs a base URL, a model and an API key in Settings.")
            }
        }
    }

    // MARK: - Menus

    private var cleanupMenu: some View {
        Menu {
            ForEach(CleanupMode.allCases) { mode in
                Button {
                    coordinator.selectCleanupMode(mode)
                } label: {
                    checked(mode.displayName, state.selectedMode == mode)
                }
            }
        } label: {
            Text("Cleanup: \(state.selectedMode.displayName)")
        }
        .fixedSize()
        .accessibilityLabel("Cleanup: \(state.selectedMode.displayName)")
    }

    private var toneMenu: some View {
        Menu {
            ForEach(ToneStyle.allCases) { tone in
                Button {
                    coordinator.selectToneStyle(tone)
                } label: {
                    checked(tone.displayName, state.toneStyle == tone)
                }
                .accessibilityLabel("\(tone.displayName) tone")
            }
        } label: {
            Text("Tone: \(state.toneStyle.displayName)")
        }
        .fixedSize()
        .accessibilityLabel("Tone: \(state.toneStyle.displayName)")
    }

    private var moreMenu: some View {
        Menu {
            if let appName = state.focusTarget.appName, let bundleID = state.focusTarget.bundleID {
                Button(state.appProfiles[bundleID] != nil
                       ? "Profile for \(appName) (Custom)\u{2026}"
                       : "Profile for \(appName)\u{2026}") {
                    showProfilePopover = true
                }
            }

            SkillProfileMenu(store: coordinator.skillProfiles)
            VoiceActionModeMenu(settings: coordinator.computerActionSettings, selectMode: coordinator.selectVoiceActionMode)

            Picker("Provider: \(state.providerMode.displayName)", selection: Binding(
                get: { state.providerMode },
                set: { coordinator.selectProviderMode($0) }
            )) {
                ForEach(ProviderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if state.availableWorkflowModes.count > 1 {
                Picker("Mode: \(state.workflowMode.displayName)", selection: Binding(
                    get: { state.workflowMode },
                    set: { coordinator.selectWorkflowMode($0) }
                )) {
                    ForEach(state.availableWorkflowModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            Button("Setup\u{2026}") {
                onOpenSetup()
            }
            .keyboardShortcut("1", modifiers: [.command])
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More options")
        .accessibilityLabel("More options")
        .popover(isPresented: $showProfilePopover, arrowEdge: .bottom) {
            if let appName = state.focusTarget.appName, let bundleID = state.focusTarget.bundleID {
                appProfilePopover(bundleID: bundleID, appName: appName)
            }
        }
    }

    @ViewBuilder
    private func checked(_ title: String, _ isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var privateAPINeedsSettings: Bool {
        state.providerMode == .privateAPI
            && (state.privateAPIBaseURL.isEmpty || state.privateAPIModel.isEmpty || !state.privateAPIKeyConfigured)
    }

    // MARK: - App profile

    private func appProfilePopover(bundleID: String, appName: String) -> some View {
        let current = state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
            ?? AppProfile(tone: state.toneStyle, cleanupMode: state.selectedMode, insertBehavior: state.insertBehavior)

        return VStack(alignment: .leading, spacing: VF.spacingSmall + 2) {
            Text("Profile for \(appName)")
                .font(VF.bodyEmphasizedFont)

            Picker("Tone", selection: Binding(
                get: { current.tone },
                set: { newTone in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: newTone, cleanupMode: current.cleanupMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
            }

            Picker("Cleanup", selection: Binding(
                get: { current.cleanupMode },
                set: { newMode in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: newMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
            }

            Picker("Insert", selection: Binding(
                get: { current.insertBehavior },
                set: { newBehavior in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: current.cleanupMode, insertBehavior: newBehavior))
                }
            )) {
                ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
            }

            if state.appProfiles[bundleID] != nil {
                Button("Reset to Default") {
                    coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                    showProfilePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(VF.spacingMedium)
        .frame(width: 260)
    }
}

/// One chip per setting that is not at its default. Observes the skill
/// profile and voice-action stores directly so a change there redraws it.
private struct PaletteOptionChips: View {
    @ObservedObject var state: AppState
    @ObservedObject var skillProfiles: SkillProfileStore
    @ObservedObject var voiceActions: ComputerActionSettings

    private struct Item: Identifiable {
        let id: String
        let text: String
        let symbol: String
        let tint: Color
        let help: String
    }

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            ChipFlowLayout(spacing: VF.spacingXSmall) {
                ForEach(items) { item in
                    VFChip(text: item.text, symbol: item.symbol, tint: item.tint)
                        .help(item.help)
                }
            }
        }
    }

    private var items: [Item] {
        var items: [Item] = []
        if state.autoSubmitMode != .off {
            items.append(Item(
                id: "auto-enter", text: "Automatic Enter: On", symbol: "return", tint: VF.colorWarning,
                help: "Presses Return after \(Self.autoEnterScope(state.autoSubmitMode))"))
        }
        if let profile = skillProfiles.activeProfile {
            items.append(Item(
                id: "skill-profile", text: "Skill profile: \(profile.name)", symbol: "list.bullet.rectangle",
                tint: VF.colorInfo, help: "Skill profile in use"))
        }
        if voiceActions.mode != .off {
            items.append(Item(
                id: "voice-actions", text: "Voice actions: \(voiceActions.mode.displayName)", symbol: "bolt",
                tint: VF.colorInfo, help: "Spoken commands can act on your Mac"))
        }
        if state.providerMode == .privateAPI {
            items.append(Item(
                id: "private-api", text: "Private API", symbol: "network", tint: VF.colorWarning,
                help: "Text is sent to your private API for processing"))
        }
        if state.workflowMode != .dictation {
            items.append(Item(
                id: "workflow", text: state.workflowMode.displayName, symbol: "arrow.triangle.branch",
                tint: VF.colorInfo, help: "Workflow mode"))
        }
        return items
    }

    private static func autoEnterScope(_ mode: AutoSubmitMode) -> String {
        switch mode {
        case .off: return "nothing"
        case .voiceActionPrompts: return "skill profile prompts"
        case .ordinaryDictation: return "ordinary dictation"
        case .both: return "skill profile prompts and ordinary dictation"
        }
    }
}

/// Lays chips out left to right and wraps to a new line when the next one
/// does not fit. A chip wider than the row is offered the row's width, so
/// its one line truncates instead of overflowing.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
