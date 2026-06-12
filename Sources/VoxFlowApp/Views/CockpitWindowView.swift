import SwiftUI

/// Cockpit Layer 0 — top-level long-form workspace window.
///
/// Document-centric layout per the design spec: top bar (status pills),
/// main pane (transcript + voice prompt strip + chip row), side panel
/// (Target + Recent). Keyboard shortcuts wired via ``KeyEventBridge``
/// for the ones SwiftUI's `.keyboardShortcut` modifier can't capture
/// cleanly while the cockpit is open.
struct CockpitWindowView: View {
    @ObservedObject var coordinator: CockpitCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var sessionService: LongFormSessionService
    let cockpitCapture: CockpitCaptureCoordinator
    @ObservedObject var dictionary: DictionaryStore
    /// Phase E — workflow chains surfaced in the ⌘K palette, plus the dispatch
    /// closure that runs one. Observing the store (not a snapshot array) keeps
    /// the palette reactive: chains added in Settings while the cockpit is open
    /// refresh immediately, mirroring how `dictionary`/`snippetStore` are threaded.
    @ObservedObject var chainStore: ChainStore
    var onChainTriggered: ((WorkflowChain) -> Void)? = nil

    @State private var showPalette: Bool = false
    @State private var sidePanelHidden: Bool = false
    @State private var lastError: String?

    var body: some View {
        HStack(spacing: 0) {
            mainPane
            if !sidePanelHidden {
                Divider()
                CockpitSidePanelView(state: state, sessionService: sessionService, dictionary: dictionary, coordinator: coordinator)
                    .frame(width: 240)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            // R4.4: spotlight-style overlay, not a sheet — sheets slide from
            // the window chrome and read as modal dialogs.
            if showPalette {
                ActionPaletteView(
                    onActionTriggered: { action in triggerAction(action) },
                    chains: chainStore.chains,
                    onChainTriggered: onChainTriggered,
                    onDismiss: { showPalette = false }
                )
                .padding(.top, 64)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(VF.animationStandard, value: showPalette)
        .overlay {
            // R5.4: preview-before-send gate + response card.
            if let preview = state.handoffPreview {
                handoffCard(
                    title: "Send to assistant?",
                    body: preview,
                    primary: ("Send", { appCoordinator?.confirmAssistantHandoff() }),
                    secondary: ("Cancel", { appCoordinator?.dismissAssistantHandoff() }),
                    footnote: "Runs: \(state.assistantHandoffCommand) — transcript is passed on stdin. Nothing executes automatically."
                )
            } else if state.handoffInFlight {
                ProgressView("Waiting for assistant…")
                    .padding(VF.spacingLarge)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
            } else if let result = state.handoffResult {
                handoffCard(
                    title: "Assistant response",
                    body: result,
                    primary: ("Copy", {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result, forType: .string)
                        appCoordinator?.dismissAssistantHandoff()
                    }),
                    secondary: ("Dismiss", { appCoordinator?.dismissAssistantHandoff() }),
                    footnote: nil
                )
            }
        }
        .background(
            KeyEventBridge { event in
                handleKey(event)
            }
        )
        .onAppear {
            // Wire the session-stop callback into the coordinator so the
            // teaching-mode voice strip counter advances.
        }
        .onChange(of: sessionService.state) { _, newValue in
            if case .reviewing = newValue {
                coordinator.didEnterReviewState()
            }
        }
    }

    /// AppCoordinator reference for the handoff flow (the cockpit otherwise
    /// only knows its own coordinator).
    private var appCoordinator: AppCoordinator? { AppCoordinator.shared }

    private func handoffCard(
        title: String,
        body text: String,
        primary: (String, () -> Void),
        secondary: (String, () -> Void),
        footnote: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text(title).font(VF.titleFont)
            ScrollView {
                Text(text)
                    .font(VF.bodyFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(VF.spacingSmall)
            .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
            if let footnote {
                Text(footnote).font(VF.microFont).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(secondary.0, action: secondary.1)
                    .keyboardShortcut(.escape, modifiers: [])
                Button(primary.0, action: primary.1)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(VF.spacingLarge)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            CockpitTopBarView(state: state, sessionService: sessionService)
                .padding(.horizontal, VF.spacingLarge)
                .padding(.vertical, VF.spacingMedium)
                .background(.thinMaterial)

            CockpitTranscriptView(sessionService: sessionService, onEditCommit: { before, after in
                    dictionary.learnFromEdit(before: before, after: after)
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: VF.spacingSmall) {
                VoicePromptStripView(state: state)
                CockpitChipRowView(
                    state: state,
                    coordinator: coordinator,
                    onActionTriggered: triggerAction,
                    onShowPalette: { showPalette = true }
                )
                if let lastError {
                    Text(lastError)
                        .font(VF.captionFont)
                        .foregroundStyle(VF.colorWarning)
                }
            }
            .padding(VF.spacingMedium)
            .background(.thinMaterial)
        }
    }

    private func triggerAction(_ action: SmartActionId) {
        Task {
            guard let transcript = sessionService.currentSession?.transcript,
                  !transcript.isEmpty else { return }
            do {
                _ = try await coordinator.applyAction(action, to: transcript)
                lastError = nil
            } catch {
                lastError = "\(action.label) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Handle ⌘R / ⌘. / ⌘Z / ⌘↩ / ⌘C / ⌘\ / ⌘W / esc.
    /// Returns nil to consume the event, or the event to let SwiftUI handle it.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers ?? ""

        if modifiers == .command {
            switch key {
            case "r":
                cockpitCapture.startRecording(targetApp: state.focusTarget)
                return nil
            case ".":
                Task { await cockpitCapture.stopRecording() }
                return nil
            case "z":
                Task { await coordinator.undoLastAction() }
                return nil
            case "\r":
                Task { await coordinator.insertIntoTarget() }
                return nil
            case "c":
                coordinator.copyToClipboard()
                return nil
            case "\\":
                sidePanelHidden.toggle()
                return nil
            case "w":
                coordinator.close()
                return nil
            default:
                break
            }
        }

        // Plain escape closes the cockpit.
        if event.keyCode == 53 {  // escape
            coordinator.close()
            return nil
        }

        return event
    }
}
