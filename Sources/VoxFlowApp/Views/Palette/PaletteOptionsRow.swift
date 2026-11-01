import SwiftUI

/// One options row (Tone, the Cleanup level while the review card shows,
/// and a ••• menu for the rest) plus a chip for each setting that is not at
/// its default, because those change what a dictation does. Every item calls
/// the coordinator method the old controls called: `selectCleanupMode`,
/// `selectToneStyle`, `updateAppProfile`, `selectVoiceActionMode`,
/// `selectProviderMode`, `selectWorkflowMode`.
struct PaletteOptionsRow: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var onOpenSetup: () -> Void

    @State private var showProfilePopover = false

    /// The row's controls, each with its own capture-time rule.
    enum Option: CaseIterable {
        case cleanupLevel, tone, appProfile, skillProfile, voiceActions, provider, mode, setup
    }

    /// Ruling R38, which replaces R18's whole-row rule. The Skill profile and
    /// Voice actions menus stay enabled in every state: changing either
    /// revokes captured action permissions and a pending automatic Enter,
    /// a safety control the old palette offered mid-capture. Every other
    /// control is disabled while a capture is in flight (the workflow Mode
    /// picker clears candidates and restarts the backend). The ••• menu
    /// itself stays open so the two revocation menus can be reached; the
    /// chips stay visible.
    nonisolated static func isEnabled(_ option: Option, sessionState: SessionState) -> Bool {
        switch option {
        case .skillProfile, .voiceActions:
            return true
        case .cleanupLevel, .tone, .appProfile, .provider, .mode, .setup:
            return !isCaptureInFlight(sessionState)
        }
    }

    /// Exhaustive on purpose, so a new session state needs a decision here.
    nonisolated static func isCaptureInFlight(_ sessionState: SessionState) -> Bool {
        switch sessionState {
        case .recording, .transcribing, .inserting:
            return true
        case .idle, .review, .onboarding, .error:
            return false
        }
    }

    /// The Cleanup level menu sets `selectedMode`, which picks the variant
    /// the review card shows and inserts; every capture overwrites it, and
    /// auto-insert uses the insert behavior's level instead. So it appears
    /// only with the review card (ruling R33); in idle it would be a dead
    /// control showing a stale level.
    nonisolated static func showsCleanupMenu(sessionState: SessionState, hasPrivacyPreview: Bool) -> Bool {
        CommandPaletteView.showsReviewCard(sessionState: sessionState, hasPrivacyPreview: hasPrivacyPreview)
    }

    /// "Cleanup level", so it is not read as the footer's "Cleanup:" label,
    /// which names what does the cleanup.
    nonisolated static func cleanupMenuTitle(_ mode: CleanupMode) -> String {
        "Cleanup level: \(mode.displayName)"
    }

    private func isEnabled(_ option: Option) -> Bool {
        Self.isEnabled(option, sessionState: state.sessionState)
    }

    private var showsCleanupMenu: Bool {
        Self.showsCleanupMenu(sessionState: state.sessionState, hasPrivacyPreview: state.privacyPreview != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            HStack(spacing: VF.spacingLarge) {
                if showsCleanupMenu {
                    cleanupMenu
                }
                toneMenu
                Spacer(minLength: 0)
                moreMenu
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .onChange(of: state.sessionState) { _, newState in
                // A capture that starts while the app profile popover is
                // open closes it, as the old palette did when its anchor left.
                if Self.isCaptureInFlight(newState) { showProfilePopover = false }
            }

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

    // The Cleanup level and Tone choices are bound inline pickers (ruling
    // R42), so the menu items carry the native checkmark and VoiceOver's
    // selected state; picking one calls the same coordinator method.

    private var cleanupMenu: some View {
        Menu {
            Picker("Cleanup level", selection: Binding(
                get: { state.selectedMode },
                set: { coordinator.selectCleanupMode($0) }
            )) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Self.cleanupMenuTitle(state.selectedMode))
        }
        .fixedSize()
        .disabled(!isEnabled(.cleanupLevel))
        .help("The cleanup level of the text under review")
        .accessibilityLabel(Self.cleanupMenuTitle(state.selectedMode))
    }

    private var toneMenu: some View {
        Menu {
            Picker("Tone", selection: Binding(
                get: { state.toneStyle },
                set: { coordinator.selectToneStyle($0) }
            )) {
                ForEach(ToneStyle.allCases) { tone in
                    Text(tone.displayName).tag(tone)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Tone: \(state.toneStyle.displayName)")
        }
        .fixedSize()
        .disabled(!isEnabled(.tone))
        .accessibilityLabel("Tone: \(state.toneStyle.displayName)")
    }

    private var moreMenu: some View {
        Menu {
            if let appName = state.focusTarget.appName, let bundleID = state.focusTarget.bundleID {
                Button(state.appProfiles[bundleID] != nil
                       ? "Profile for \(appName) (Custom)\u{2026}"
                       : "Profile for \(appName)\u{2026}") {
                    // Ruling R44: present on a later main-actor turn, after
                    // the menu has dismissed, so the popover does not race it.
                    Task { @MainActor in
                        await Task.yield()
                        showProfilePopover = true
                    }
                }
                .disabled(!isEnabled(.appProfile))
            }

            // Always enabled (ruling R38): a change here revokes captured
            // permissions and a pending Enter.
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
            .disabled(!isEnabled(.provider))

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
                .disabled(!isEnabled(.mode))
            }

            Divider()

            // No shortcut here: Cmd-1 is bound once, on the footer's hidden
            // button, so it can never fire twice.
            Button("Setup\u{2026}") {
                onOpenSetup()
            }
            .disabled(!isEnabled(.setup))
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
