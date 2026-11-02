import SwiftUI

/// Cockpit transcript pane — editable when the session is in `.reviewing` state;
/// read-only during recording and idle. Focus-loss commits the edit via
/// `LongFormSessionService.setTranscript(_:sessionID:)`, bound to the session
/// the edit was taken from (``TranscriptDraft``), and fires `onEditCommit` for
/// downstream consumers (e.g. dictionary learning).
struct CockpitTranscriptView: View {
    @ObservedObject var sessionService: LongFormSessionService
    var onEditCommit: ((_ before: String, _ after: String) -> Void)? = nil

    @State private var draft = TranscriptDraft()
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                if let session = sessionService.currentSession {
                    crumbs(session)
                    if sessionService.state == .reviewing {
                        TextEditor(text: Binding(get: { draft.text }, set: { draft.edit($0) }))
                            .font(VF.bodyFont)
                            .frame(minHeight: 200)
                            .focused($editing)
                            .onChange(of: editing) { _, isEditing in
                                if isEditing { draft.beginEditing() }
                                else { commitEdit() }
                            }
                    } else {
                        Text(session.transcript.isEmpty ? placeholder : session.transcript)
                            .font(VF.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Press ⌘R to start a long-form capture.")
                        .font(VF.bodyFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(VF.spacingLarge)
        }
        .onChange(of: sessionService.currentSession?.transcript) { _, _ in syncDraft() }
        .onChange(of: sessionService.currentSession?.id) { _, _ in syncDraft() }
        .onChange(of: sessionService.state) { _, _ in syncDraft() }
        .onAppear { syncDraft() }
    }

    private func syncDraft() {
        draft.observe(
            transcript: sessionService.currentSession?.transcript,
            sessionID: sessionService.currentSession?.id,
            reviewing: sessionService.state == .reviewing,
            editing: editing
        )
    }

    private func commitEdit() {
        guard let commit = draft.pendingCommit,
              sessionService.setTranscript(commit.after, sessionID: commit.sessionID) else { return }
        onEditCommit?(commit.before, commit.after)
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
