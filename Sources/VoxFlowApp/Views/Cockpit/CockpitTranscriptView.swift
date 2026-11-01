import SwiftUI

/// Cockpit transcript pane: editable when the session is in `.reviewing` state;
/// read-only during recording and idle. Focus-loss commits the edit via
/// `LongFormSessionService.setTranscript(_:)` and fires `onEditCommit` for
/// downstream consumers (e.g. dictionary learning).
struct CockpitTranscriptView: View {
    @ObservedObject var sessionService: LongFormSessionService
    var onEditCommit: ((_ before: String, _ after: String) -> Void)? = nil

    @State private var draft: String = ""
    @State private var baseline: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        Group {
            if let session = sessionService.currentSession {
                if sessionService.state == .reviewing {
                    // The editor scrolls itself, so it is not nested in a
                    // ScrollView (which proposes no height and left it at its
                    // minimum): it fills the pane, and a long transcript
                    // shows as much as fits and scrolls inside (ruling R32).
                    VStack(alignment: .leading, spacing: VF.spacingSmall) {
                        crumbs(session)
                        page(session)
                    }
                    // A capped line length, centered when the window is wide.
                    .frame(maxWidth: VF.readingMaxWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .padding(VF.spacingLarge)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: VF.spacingSmall) {
                            crumbs(session)
                            page(session)
                        }
                        // A capped line length, centered when the window is wide.
                        .frame(maxWidth: VF.readingMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(VF.spacingLarge)
                    }
                }
            } else {
                VFEmptyState(
                    title: "No capture yet",
                    symbol: "waveform",
                    message: "Press ⌘R to start a long-form capture.",
                    shortcuts: [
                        VFShortcutHint(keys: "⌘R", label: "Record"),
                        VFShortcutHint(keys: "⌘.", label: "Stop"),
                        VFShortcutHint(keys: "⌘↩", label: "Insert"),
                        VFShortcutHint(keys: "⌘K", label: "Actions"),
                    ])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: sessionService.currentSession?.transcript) { _, new in
            if !editing { draft = new ?? "" }
        }
        .onAppear { draft = sessionService.currentSession?.transcript ?? "" }
    }

    /// The writing surface: an opaque text background in reading type.
    private func page(_ session: LongFormSession) -> some View {
        Group {
            if sessionService.state == .reviewing {
                TextEditor(text: $draft)
                    .font(VF.readingFont)
                    .lineSpacing(VF.readingLineSpacing)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .focused($editing)
                    .onChange(of: editing) { _, isEditing in
                        if isEditing { baseline = draft }
                        else { commitEdit() }
                    }
            } else {
                Text(session.transcript.isEmpty ? placeholder : session.transcript)
                    .font(VF.readingFont)
                    .lineSpacing(VF.readingLineSpacing)
                    .foregroundStyle(session.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(VF.spacingMedium)
        .vfSurface(.content, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
    }

    private func commitEdit() {
        let after = draft
        guard after != baseline else { return }
        sessionService.setTranscript(after)
        onEditCommit?(baseline, after)
    }

    private var placeholder: String {
        switch sessionService.state {
        case .recording: return "Listening…"
        default: return "(empty)"
        }
    }

    private func crumbs(_ session: LongFormSession) -> some View {
        let words = session.transcript.split(whereSeparator: { $0.isWhitespace }).count
        let paragraphs = session.transcript
            .components(separatedBy: "\n\n")
            .filter { !$0.isEmpty }
            .count
        // "auto-saved" only once there is content — an empty, never-saved
        // session showing "0 words · 0 paragraphs · auto-saved" was misleading.
        let saved = session.transcript.isEmpty ? "" : " · auto-saved"
        return Text("\(words) words · \(paragraphs) paragraph\(paragraphs == 1 ? "" : "s")\(saved)")
            .font(VF.captionFont)
            .foregroundStyle(.secondary)
    }
}
