import SwiftUI

/// Teaching-mode voice-keyword hint.
///
/// Shows below the chip row during the first ~10 captures. Auto-dismisses
/// when ``CockpitCoordinator.didEnterReviewState`` flips
/// ``state.voicePromptStripDismissed``, or the user explicitly dismisses it
/// (persisted to UserDefaults).
struct VoicePromptStripView: View {
    @ObservedObject var state: AppState

    var isVisible: Bool {
        // Shares CockpitCoordinator's constant so this visibility test and the
        // coordinator's persisted-dismiss write stay in lockstep (they were two
        // independent `= 10` literals that could drift apart).
        !state.voicePromptStripDismissed
            && state.totalCaptureCount < CockpitCoordinator.voicePromptStripDismissThreshold
    }

    var body: some View {
        if isVisible {
            VFBanner(
                kind: .info,
                message: "In review, say “memo”, “MECE”, “items”, “cancel” or “undo”.",
                onDismiss: {
                    state.voicePromptStripDismissed = true
                    UserDefaults.standard.set(true, forKey: "VoxFlow.voicePromptStripDismissed")
                })
        }
    }
}
