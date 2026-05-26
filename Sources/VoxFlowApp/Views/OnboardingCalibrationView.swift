import SwiftUI

struct OnboardingCalibrationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice Calibration")
                .font(VF.largeFont)

            Text("Say each phrase using the hold-to-talk hotkey so the app can calibrate your voice profile.")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)

            if let phrase = state.currentCalibrationPhrase {
                Text("Phrase \(state.activeCalibrationIndex + 1) of \(state.calibrationItems.count)")
                    .font(VF.labelFont)
                    .foregroundStyle(.secondary)

                Text("\"\(phrase)\"")
                    .font(VF.headingFont)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VF.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: VF.cornerMedium))
            }

            if state.sessionState == .recording {
                Text("Recording... release hotkey to process this phrase")
                    .font(VF.labelFont)
                    .foregroundStyle(VF.colorWarning)
            }

            HStack(spacing: 10) {
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
                .help("Skip the voice profile setup. You can rerun calibration any time from the Setup Wizard.")

                Spacer()
            }

            if !state.calibrationItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
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
        .padding(16)
    }
}
