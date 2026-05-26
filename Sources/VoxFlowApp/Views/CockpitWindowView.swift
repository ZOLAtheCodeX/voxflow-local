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

    @State private var showPalette: Bool = false
    @State private var sidePanelHidden: Bool = false
    @State private var lastError: String?

    var body: some View {
        HStack(spacing: 0) {
            mainPane
            if !sidePanelHidden {
                Divider()
                CockpitSidePanelView(state: state, sessionService: sessionService)
                    .frame(width: 240)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(.regularMaterial)
        .sheet(isPresented: $showPalette) {
            ActionPaletteView { action in
                triggerAction(action)
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

    private var mainPane: some View {
        VStack(spacing: 0) {
            CockpitTopBarView(state: state, sessionService: sessionService)
                .padding(.horizontal, VF.spacingLarge)
                .padding(.vertical, VF.spacingMedium)
                .background(.thinMaterial)

            CockpitTranscriptView(sessionService: sessionService)
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
                sessionService.start(targetApp: state.focusTarget)
                return nil
            case ".":
                sessionService.stop()
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
