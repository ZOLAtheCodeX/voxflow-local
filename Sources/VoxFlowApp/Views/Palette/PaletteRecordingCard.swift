import SwiftUI

/// The palette while the microphone is open: the listening status with a
/// live dot (static under Reduce Motion), the elapsed time, the target app
/// and Cancel (esc). The dot is an honest "listening" signal, not a level
/// meter, matching the pill.
struct PaletteRecordingCard: View {
    let duration: TimeInterval
    let targetAppName: String?
    let isVoiceControl: Bool
    let onCancel: () -> Void

    private var status: VFStatus { isVoiceControl ? .voiceControl : .listening }

    var body: some View {
        VStack(spacing: VF.spacingMedium) {
            HStack(spacing: VF.spacingSmall) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                    .vfLive(true)
                Text(status.label)
                    .font(VF.headingFont)
                    .foregroundStyle(status.color)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(status.label), \(elapsed)")

            Text(elapsed)
                .font(VF.timerFont)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text("Release the hotkey to transcribe")
                .font(VF.captionFont)
                .foregroundStyle(.secondary)

            // A voice-control command acts on the app; it inserts nothing.
            if !isVoiceControl, let targetAppName, !targetAppName.isEmpty {
                Label("Inserting into \(targetAppName)", systemImage: "arrow.right.circle")
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Target application: \(targetAppName)")
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Cancel this capture (esc)")
        }
        .frame(maxWidth: .infinity)
        .padding(VF.spacingLarge)
        .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))
    }

    private var elapsed: String { RecordingPillView.elapsedText(duration) }
}
