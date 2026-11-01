import SwiftUI

/// The floating pill's content (`RecordingOverlayController` owns the panel).
///
/// - Live: a dot that pulses while the microphone is open (static under
///   Reduce Motion), "Listening" or "Voice control", and the elapsed time.
///   It is an honest "listening" signal, not a level meter.
/// - Working: the word alone, no spinner. It also stays up while the
///   controller waits for a late status line (ruling R29).
/// - Outcome: one status badge on one line, tail-truncated.
///
/// Cancel is an explicit button that appears on hover and calls the same
/// `onCancel` as before. The capsule itself does nothing on click, so a stray
/// click no longer throws away a long dictation. VoiceOver reaches the same
/// `onCancel` through a "Cancel dictation" action on the live and working
/// rows (R31); the button itself is hidden from accessibility (R43). The pill
/// takes clicks only while it offers cancel (R45).
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
            // The panel ignores the mouse while an outcome or the hold is up,
            // so no exit event resets the hover; the next live pill must not
            // start with the cancel button showing.
            .onChange(of: presentation.outcome) { _, _ in isHovering = false }
            .onChange(of: presentation.awaitingLateStatus) { _, _ in isHovering = false }
    }

    @ViewBuilder
    private var content: some View {
        if let outcome = presentation.outcome {
            VFStatusBadge(status: outcome.badgeStatus)
                .truncationMode(.tail)
        } else if let status = VFStatus.pill(
            // While the controller waits for a late status line the session
            // is already idle; the pill keeps the row it showed while
            // transcribing.
            sessionState: presentation.awaitingLateStatus ? .transcribing : state.sessionState,
            isCommandLaneActive: state.isCommandLaneActive
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
            .modifier(CancelAccessibilityAction(
                isOffered: Self.offersCancel(sessionState: state.sessionState), onCancel: onCancel))
            cancelButton
        }
    }

    private func workingRow(_ status: VFStatus) -> some View {
        Text("\(status.label)\u{2026}")
            .font(VF.captionFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .modifier(CancelAccessibilityAction(
                isOffered: Self.offersCancel(sessionState: state.sessionState), onCancel: onCancel))
            .overlay(alignment: .trailing) {
                if Self.offersCancel(sessionState: state.sessionState) {
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
        // VoiceOver cancels through the row's "Cancel dictation" action
        // (ruling R31); hiding the button keeps it from being listed twice
        // (ruling R43).
        .accessibilityHidden(true)
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    /// Same reach as the old pill: a recording or a transcription can be
    /// canceled; an insert in progress cannot, and neither can an outcome or
    /// the wait for a late status line (the session is idle by then).
    static func offersCancel(sessionState: SessionState) -> Bool {
        sessionState == .recording || sessionState == .transcribing
    }

    /// Elapsed recording time as `m:ss`.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The VoiceOver route to cancel (ruling R31): the hover button is fully
/// transparent until hovered, so it is not in the accessibility tree.
private struct CancelAccessibilityAction: ViewModifier {
    let isOffered: Bool
    let onCancel: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOffered {
            content.accessibilityAction(named: "Cancel dictation") { onCancel() }
        } else {
            content
        }
    }
}
