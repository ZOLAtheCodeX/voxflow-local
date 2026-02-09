import Foundation

@MainActor protocol OnboardingCoordinating {
    func restartOnboardingCalibration()
    func completeOnboardingManually()
    func handleCalibrationResult(rawText: String)
}

@MainActor
final class OnboardingCoordinator: OnboardingCoordinating {
    private let state: AppState
    private let onboardingKey: String

    init(state: AppState, onboardingKey: String = "voxflow.onboarding.complete") {
        self.state = state
        self.onboardingKey = onboardingKey
    }

    func restartOnboardingCalibration() {
        state.calibrationItems = defaultCalibrationItems()
        state.activeCalibrationIndex = 0
        state.onboardingPhase = .calibrating
        state.sessionState = .onboarding
        state.statusLine = "Calibration mode: hold hotkey, say phrase, release"
    }

    func completeOnboardingManually() {
        state.onboardingPhase = .complete
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state.setIdle()
    }

    func handleCalibrationResult(rawText: String) {
        guard state.calibrationItems.indices.contains(state.activeCalibrationIndex) else {
            completeCalibrationFlow()
            return
        }

        let expected = state.calibrationItems[state.activeCalibrationIndex].expectedPhrase
        let similarity = TextSimilarityService.normalizedSimilarity(lhs: expected, rhs: rawText)

        state.calibrationItems[state.activeCalibrationIndex].heardPhrase = rawText
        state.calibrationItems[state.activeCalibrationIndex].score = similarity

        if state.activeCalibrationIndex + 1 < state.calibrationItems.count {
            state.activeCalibrationIndex += 1
            state.sessionState = .onboarding
            state.statusLine = "Calibration captured. Next phrase ready."
        } else {
            completeCalibrationFlow()
        }
    }

    func defaultCalibrationItems() -> [CalibrationItem] {
        [
            CalibrationItem(expectedPhrase: "Schedule a team sync for Thursday at 2 PM."),
            CalibrationItem(expectedPhrase: "Please summarize today's project updates in three bullets."),
            CalibrationItem(expectedPhrase: "Draft a follow-up email and keep it concise.")
        ]
    }

    private func completeCalibrationFlow() {
        state.onboardingPhase = .complete
        UserDefaults.standard.set(true, forKey: onboardingKey)
        state.setIdle()
        state.statusLine = "Calibration complete. Dictation ready."
    }
}
