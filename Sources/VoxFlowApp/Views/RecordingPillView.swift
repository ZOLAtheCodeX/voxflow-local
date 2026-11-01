import SwiftUI

/// The floating pill's content (`RecordingOverlayController` owns the panel).
///
/// - Live: a dot that pulses while the microphone is open (static under
///   Reduce Motion), "Listening" or "Voice control", and the elapsed time.
///   It is an honest "listening" signal, not a level meter.
/// - Working: the word alone, no spinner.
/// - Outcome: one status badge on one line, tail-truncated.
///
/// Cancel is an explicit button that appears on hover and calls the same
/// `onCancel` as before. The capsule itself does nothing on click, so a stray
/// click no longer throws away a long dictation.
struct RecordingPillView: View {
    @ObservedObject var state: AppState
    @ObservedObject var presentation: PillPresentation
    var onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        content
            .padding(.horizontal, VF.spacingMedium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .vfSurface(.hud, in: Capsule())
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let outcome = presentation.outcome {
            VFStatusBadge(status: outcome.badgeStatus)
                .truncationMode(.tail)
        } else if let status = VFStatus.pill(
            sessionState: state.sessionState, isCommandLaneActive: state.isCommandLaneActive
        ) {
            if status.isLive {
                liveRow(status)
            } else {
                workingRow(status)
            }
        }
    }

    private func liveRow(_ status: VFStatus) -> some View {
        let elapsed = Self.elapsedText(state.recordingDuration)
        return HStack(spacing: VF.spacingSmall) {
            HStack(spacing: VF.spacingSmall) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .vfLive(true)
                Text(status.label)
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(status.color)
                Spacer(minLength: VF.spacingSmall)
                // The timer style (semibold, fixed-width digits) at caption size.
                Text(elapsed)
                    .font(VF.captionEmphasizedFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(status.label), \(elapsed)")
            cancelButton
        }
    }

    private func workingRow(_ status: VFStatus) -> some View {
        Text("\(status.label)\u{2026}")
            .font(VF.captionFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                // Same reach as the old pill: a transcription can still be
                // canceled; an insert in progress cannot.
                if state.sessionState == .transcribing {
                    cancelButton
                }
            }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark.circle.fill")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel (esc)")
        .accessibilityLabel("Cancel dictation")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    /// Elapsed recording time as `m:ss`.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
