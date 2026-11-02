import SwiftUI

struct OnboardingCalibrationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text("Say each phrase using the hold-to-talk hotkey so the app can calibrate your voice profile.")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)

            if let phrase = state.currentCalibrationPhrase {
                Text("Phrase \(state.activeCalibrationIndex + 1) of \(state.calibrationItems.count)")
                    .font(VF.labelFont)
                    .foregroundStyle(.secondary)

                Text("\"\(phrase)\"")
                    .font(VF.headingFont)
                    .padding(VF.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vfSurface(.elevated, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
            }

            if state.sessionState == .recording {
                Text("Listening. Release the hotkey to process this phrase.")
                    .font(VF.labelFont)
                    .foregroundStyle(VF.colorWarning)
            }

            HStack(spacing: VF.spacingSmall) {
                Button(state.sessionState == .recording ? "Stop" : "Record Phrase") {
                    if state.sessionState == .recording {
                        Task { await coordinator.finishCaptureAndTranscribe() }
                    } else {
                        coordinator.startCapture()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Restart Calibration") {
                    coordinator.restartOnboardingCalibration()
                }
                .buttonStyle(.bordered)

                Button("Skip Calibration") {
                    coordinator.completeOnboardingManually()
                }
                .buttonStyle(.bordered)
                .help("Skip the voice profile setup. You can run calibration any time from Setup.")

                Spacer()
            }

            if !state.calibrationItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: VF.spacingXSmall) {
                    ForEach(Array(state.calibrationItems.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                            Text(item.expectedPhrase)
                                .lineLimit(1)
                            Spacer()
                            if let score = item.score {
                                Text("\(Int(score * 100))%")
                                    .font(VF.captionEmphasizedFont)
                                    .foregroundStyle(score > 0.72 ? VF.colorSuccess : VF.colorWarning)
                            }
                        }
                        .font(VF.secondaryFont)
                    }
                }
            }
        }
        .padding(.vertical, VF.spacingSmall)
    }
}
