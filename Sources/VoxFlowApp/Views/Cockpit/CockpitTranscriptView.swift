import SwiftUI

/// Cockpit transcript pane — editable when the session is in `.reviewing` state;
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
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                if let session = sessionService.currentSession {
                    crumbs(session)
                    if sessionService.state == .reviewing {
                        TextEditor(text: $draft)
                            .font(VF.bodyFont)
                            .frame(minHeight: 200)
                            .focused($editing)
                            .onChange(of: editing) { _, isEditing in
                                if isEditing { baseline = draft }
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
        .onChange(of: sessionService.currentSession?.transcript) { _, new in
            if !editing { draft = new ?? "" }
        }
        .onAppear { draft = sessionService.currentSession?.transcript ?? "" }
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
        return Text("\(words) words · \(paragraphs) paragraph\(paragraphs == 1 ? "" : "s") · auto-saved")
            .font(VF.captionFont)
            .foregroundStyle(.secondary)
    }
}
