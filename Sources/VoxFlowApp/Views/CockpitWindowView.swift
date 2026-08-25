import SwiftUI

/// Cockpit Layer 0 — top-level long-form workspace window.
///
/// Document-centric layout per the design spec: top bar (status pills),
/// main pane (transcript + voice prompt strip + chip row), side panel
/// (Target / Notion / Dictionary / Assistant / Recent). Keyboard shortcuts
/// wired via ``KeyEventBridge``
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
                        // Transient failure banner — auto-dismiss after a beat
                        // instead of lingering until the next action succeeds.
                        // task(id:) cancels the previous timer when a new error
                        // replaces this one, so the window restarts per error.
                        .task(id: lastError) {
                            try? await Task.sleep(for: .seconds(8))
                            guard !Task.isCancelled else { return }
                            self.lastError = nil
                        }
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
                let result = try await coordinator.applyAction(action, to: transcript)
                // A soft error (e.g. provider_unavailable) is returned, not
                // thrown — surface it rather than treating it as success.
                lastError = result.error.map {
                    CockpitCoordinator.smartActionErrorMessage(action, error: $0, degradedReason: result.degradedReason)
                }
            } catch {
                lastError = "\(action.label) failed: \(error.localizedDescription)"
            }
        }
    }

    /// Handle ⌘R / ⌘. / ⌘Z / ⌘↩ / ⌘C / ⌘\ / ⌘W / esc.
    /// Returns nil to consume the event, or the event to let SwiftUI handle it.
    /// The routing policy (including the focus-aware ⌘Z/⌘C/esc behavior while
    /// the transcript editor or a search field is focused) lives in
    /// ``CockpitKeyRouter`` — keep this a mechanical dispatch.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers ?? ""

        switch CockpitKeyRouter.route(
            key: key,
            keyCode: event.keyCode,
            modifiers: modifiers,
            isTextEditingActive: isTextEditingActive()
        ) {
        case .record:
            cockpitCapture.startRecording(targetApp: state.focusTarget)
            return nil
        case .stop:
            Task { await cockpitCapture.stopRecording() }
            return nil
        case .undo:
            Task { await coordinator.undoLastAction() }
            return nil
        case .insert:
            Task { await coordinator.insertIntoTarget() }
            return nil
        case .commitThenInsert:
            // Commit the draft DETERMINISTICALLY before inserting: the
            // focused transcript editor's NSTextView.string IS the draft, so
            // write it through setTranscript synchronously rather than
            // resigning focus and racing the editor's async focus-loss
            // handler (a fixed sleep could still insert stale text under
            // main-actor load). A focused TextField (e.g. Notion search)
            // presents as the window's FIELD editor — skip it: no transcript
            // draft is pending there. The later focus-loss commit becomes an
            // idempotent no-op-or-duplicate write of the same text.
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable, !textView.isFieldEditor {
                sessionService.setTranscript(textView.string)
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
            Task { await coordinator.insertIntoTarget() }
            return nil
        case .copy:
            coordinator.copyToClipboard()
            return nil
        case .toggleSidePanel:
            sidePanelHidden.toggle()
            return nil
        case .close:
            coordinator.close()
            return nil
        case .exitEditing:
            // Resigning first responder flips the transcript editor's
            // @FocusState, which commits the draft via its onChange handler.
            NSApp.keyWindow?.makeFirstResponder(nil)
            return nil
        case .passThrough:
            return event
        }
    }

    /// Whether an editable text view (the transcript editor in `.reviewing`,
    /// or a field editor for e.g. the Notion search field) currently has
    /// keyboard focus. Untestable one-liner by design — all routing policy
    /// that consumes this lives in the unit-tested ``CockpitKeyRouter``.
    private func isTextEditingActive() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
    }
}
