import SwiftUI

extension CommandPaletteView {
    var recordingStateCard: some View {
        VStack(alignment: .center, spacing: VF.spacingMedium) {
            TimelineView(.animation(minimumInterval: 0.08)) { context in
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(VF.colorError.gradient)
                            .frame(width: 8, height: waveformHeight(index: index, time: context.date.timeIntervalSinceReferenceDate))
                    }
                }
                .frame(height: 54)
            }
            .accessibilityLabel("Live recording level")

            Text(String(format: "%.1f", state.recordingDuration))
                .font(VF.timerFont)
                .foregroundStyle(.primary)

            Text("Release hotkey to transcribe")
                .font(VF.captionFont)
                .foregroundStyle(.secondary)

            if let appName = state.focusTarget.appName, !appName.isEmpty {
                Label("Inserting into \(appName)", systemImage: "arrow.right.circle")
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Target application: \(appName)")
            }

            Button("Cancel Capture") {
                coordinator.cancelActiveCapture()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
    }

    private func waveformHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = (time * 3.2) + (Double(index) * 0.9)
        let value = abs(sin(phase))
        return 12 + CGFloat(value * 36)
    }
}
