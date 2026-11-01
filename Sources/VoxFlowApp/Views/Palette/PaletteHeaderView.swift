import SwiftUI

extension CommandPaletteView {
    var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: VF.spacingSmall) {
                    Text("VoxFlow Local")
                        .font(VF.titleFont)
                    if state.isCommandLaneActive {
                        Text("VOICE CONTROL")
                            .font(VF.captionFont.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(VF.tintedBackground(VF.colorWarning, opacity: 0.24))
                            .foregroundStyle(VF.colorWarning)
                            .clipShape(Capsule())
                    }
                }

                Text(state.statusLine)
                    .font(VF.labelFont)
                    .foregroundStyle(.secondary)

                Text("Dictate: \(state.dictationHotkeyPreset.displayName) · Commands: \(state.commandLaneHotkeyPreset.displayName)")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(dictationReady ? "Ready" : "Not Ready")
                    .font(VF.captionFont.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(readinessBadgeColor.opacity(0.22))
                    .foregroundStyle(readinessBadgeColor)
                    .clipShape(Capsule())

                Text(state.sessionState.rawValue.capitalized)
                    .font(VF.captionFont.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(sessionBadgeColor.opacity(0.22))
                    .foregroundStyle(sessionBadgeColor)
                    .clipShape(Capsule())
                    .scaleEffect(state.sessionState == .recording && recordingBadgeAnimating ? 1.08 : 1.0)
                    .animation(
                        state.sessionState == .recording
                            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: recordingBadgeAnimating
                    )
            }
        }
        .padding(.horizontal, 16)
    }

    func updateRecordingBadgeAnimation() {
        recordingBadgeAnimating = state.sessionState == .recording
    }

    private var sessionBadgeColor: Color {
        if state.isCommandLaneActive {
            return .orange
        }

        switch state.sessionState {
        case .idle, .review:
            return .blue
        case .recording:
            return .orange
        case .transcribing, .inserting:
            return .purple
        case .onboarding:
            return .mint
        case .error:
            return .red
        }
    }

    private var dictationReady: Bool {
        state.canUseSelectedSTTBackend && (!state.workflowNeedsBackend || state.backendReadiness.readyForDictation)
    }

    private var readinessBadgeColor: Color {
        dictationReady ? .green : .orange
    }
}
