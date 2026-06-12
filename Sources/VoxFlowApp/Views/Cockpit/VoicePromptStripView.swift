import SwiftUI

/// Teaching-mode voice-keyword hint strip.
///
/// Shows below the chip row during the first ~10 captures. Auto-dismisses
/// when ``CockpitCoordinator.didEnterReviewState`` flips
/// ``state.voicePromptStripDismissed``, or the user explicitly dismisses it
/// (persisted to UserDefaults).
struct VoicePromptStripView: View {
    @ObservedObject var state: AppState

    private static let dismissThreshold = 10

    var isVisible: Bool {
        !state.voicePromptStripDismissed && state.totalCaptureCount < Self.dismissThreshold
    }

    var body: some View {
        if isVisible {
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: "mic.fill").font(VF.captionFont)
                Text("Voice: memo · MECE · items · cancel · undo")
                    .font(VF.monoCaptionFont)
                Spacer()
                Button("Dismiss") {
                    state.voicePromptStripDismissed = true
                    UserDefaults.standard.set(true, forKey: "VoxFlow.voicePromptStripDismissed")
                }
                .buttonStyle(.plain)
                .font(VF.captionFont)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, VF.spacingMedium)
            .padding(.vertical, 6)
            .background(VF.tintedBackground(.blue, opacity: 0.08), in: RoundedRectangle(cornerRadius: VF.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: VF.cornerSmall)
                    .strokeBorder(.blue.opacity(0.3), lineWidth: 1)
            )
            .foregroundStyle(VF.colorInfo)
        }
    }
}
