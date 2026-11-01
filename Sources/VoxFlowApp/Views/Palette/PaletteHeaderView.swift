import SwiftUI

/// The top of the palette: one status badge with the target app, a
/// voice-control badge while that lane is active, the live status line in
/// every state (it carries the coordinator's lost-text warnings, ruling
/// R28), the hotkey hint as a third line on first run, and any error as a
/// banner. Value-driven: it takes no coordinator.
struct PaletteHeaderView: View {
    let status: VFStatus
    let targetAppName: String?
    let isVoiceControlActive: Bool
    let lines: PaletteHeaderLines
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            HStack(spacing: VF.spacingSmall) {
                VFStatusBadge(status: status, detail: targetAppName)
                    .truncationMode(.tail)
                Spacer(minLength: VF.spacingSmall)
                // The status already says "Voice control" while that lane
                // is listening; the extra badge covers the states after it.
                if isVoiceControlActive && status.kind != .voiceControl {
                    VFStatusBadge(status: .voiceControl)
                        .fixedSize()
                }
            }

            // Up to three lines (ruling R39): the coordinator appends its
            // lost-text warnings to the end of this line, so one line
            // truncated exactly the part that matters.
            Text(lines.statusLine)
                .font(VF.secondaryFont)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(lines.statusLine)

            if let hint = lines.hint {
                Text(hint)
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(hint)
            }

            if let errorMessage, !errorMessage.isEmpty {
                VFBanner(kind: .error, message: errorMessage)
                    .padding(.top, VF.spacingXSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
