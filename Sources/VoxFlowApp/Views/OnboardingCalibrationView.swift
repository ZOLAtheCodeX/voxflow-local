import SwiftUI

struct OnboardingCalibrationView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Voice Calibration")
                .font(.system(size: 18, weight: .semibold))

            Text("Say each phrase using the hold-to-talk hotkey so the app can calibrate your voice profile.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let phrase = state.currentCalibrationPhrase {
                Text("Phrase \(state.activeCalibrationIndex + 1) of \(state.calibrationItems.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("\"\(phrase)\"")
                    .font(.system(size: 16, weight: .medium))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if state.sessionState == .recording {
                Text("Recording... release hotkey to process this phrase")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
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
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(score > 0.72 ? .green : .orange)
                            }
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
        .padding(16)
    }
}
