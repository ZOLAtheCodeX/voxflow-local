import XCTest
@testable import VoxFlowApp

final class OnboardingCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (OnboardingCoordinator, AppState) {
        let state = AppState()
        let sut = OnboardingCoordinator(state: state, onboardingKey: "voxflow.test.onboarding.complete")
        return (sut, state)
    }

    @MainActor
    func testRestartCalibrationResetsItemsAndPhase() {
        let (sut, state) = makeSUT()
        state.onboardingPhase = .complete
        state.activeCalibrationIndex = 2

        sut.restartOnboardingCalibration()

        XCTAssertEqual(state.onboardingPhase, .calibrating)
        XCTAssertEqual(state.sessionState, .onboarding)
        XCTAssertEqual(state.activeCalibrationIndex, 0)
        XCTAssertEqual(state.calibrationItems.count, 3)
    }

    @MainActor
    func testCompleteManuallyPersistsAndIdles() {
        let (sut, state) = makeSUT()
        state.onboardingPhase = .calibrating

        sut.completeOnboardingManually()

        XCTAssertEqual(state.onboardingPhase, .complete)
        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "voxflow.test.onboarding.complete"))

        UserDefaults.standard.removeObject(forKey: "voxflow.test.onboarding.complete")
    }

    @MainActor
    func testCalibrationResultAdvancesIndex() {
        let (sut, state) = makeSUT()
        sut.restartOnboardingCalibration()

        sut.handleCalibrationResult(rawText: "Schedule a team sync for Thursday at 2 PM.")

        XCTAssertEqual(state.activeCalibrationIndex, 1)
        XCTAssertNotNil(state.calibrationItems[0].heardPhrase)
        XCTAssertNotNil(state.calibrationItems[0].score)
        XCTAssertEqual(state.sessionState, .onboarding)
    }

    @MainActor
    func testCalibrationCompletesAfterAllItems() {
        let (sut, state) = makeSUT()
        sut.restartOnboardingCalibration()

        for i in 0..<3 {
            sut.handleCalibrationResult(rawText: state.calibrationItems[i].expectedPhrase)
        }

        XCTAssertEqual(state.onboardingPhase, .complete)
        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertTrue(state.statusLine.contains("Calibration complete"))

        UserDefaults.standard.removeObject(forKey: "voxflow.test.onboarding.complete")
    }

    @MainActor
    func testDefaultCalibrationItemsReturnsThree() {
        let (sut, _) = makeSUT()
        let items = sut.defaultCalibrationItems()
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { !$0.expectedPhrase.isEmpty })
    }
}
