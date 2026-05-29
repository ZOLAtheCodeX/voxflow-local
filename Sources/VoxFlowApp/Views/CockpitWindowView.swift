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
        .sheet(isPresented: $showPalette) {
            ActionPaletteView(
                onActionTriggered: { action in triggerAction(action) },
                chains: chainStore.chains,
                onChainTriggered: onChainTriggered
            )
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
