import SwiftUI

/// The top of the palette: one status badge with the target app, a
/// voice-control badge while that lane is active, a second line (the hotkey
/// hint while ready, otherwise the live status line) and any error as a
/// banner. Value-driven: it takes no coordinator.
struct PaletteHeaderView: View {
    let status: VFStatus
    let targetAppName: String?
    let isVoiceControlActive: Bool
    let secondLine: String
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

            Text(secondLine)
                .font(VF.secondaryFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(secondLine)

            if let errorMessage, !errorMessage.isEmpty {
                VFBanner(kind: .error, message: errorMessage)
                    .padding(.top, VF.spacingXSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
