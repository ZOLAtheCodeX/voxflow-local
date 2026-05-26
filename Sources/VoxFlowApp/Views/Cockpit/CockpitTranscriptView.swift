import SwiftUI

/// Cockpit transcript pane — read-only display today; future task could
/// upgrade to inline editable text. The transcript is sourced from the
/// session service directly so updates flow through the @Published
/// `currentSession` binding.
struct CockpitTranscriptView: View {
    @ObservedObject var sessionService: LongFormSessionService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                if let session = sessionService.currentSession {
                    crumbs(session)
                    Text(session.transcript.isEmpty ? placeholder : session.transcript)
                        .font(VF.bodyFont)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("Press ⌘R to start a long-form capture.")
                        .font(VF.bodyFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(VF.spacingLarge)
        }
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
