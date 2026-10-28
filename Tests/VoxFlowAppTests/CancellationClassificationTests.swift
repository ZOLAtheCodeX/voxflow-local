import XCTest
@testable import VoxFlowApp

/// User/system cancellation must be classified quietly (no error banner). Both
/// CancellationError (structured-concurrency cancel) and URLError.cancelled (a
/// cancelled URLSession request, e.g. a superseded backend call) count; genuine
/// network failures must NOT, so they still surface to the user.
final class CancellationClassificationTests: XCTestCase {

    func testCancellationErrorIsUserCancellation() {
        XCTAssertTrue(AppCoordinator.isUserCancellation(CancellationError()))
    }

    func testURLErrorCancelledIsUserCancellation() {
        XCTAssertTrue(AppCoordinator.isUserCancellation(URLError(.cancelled)))
    }

    /// Action, skill, and snippet captures short-circuit straight back to idle.
    /// A cancelled one may finish its insertion wait after a newer capture
    /// started; resetting to idle then would make the `.idle` sink clear the
    /// NEW capture's frozen target, focus, and permissions.
    @MainActor
    func testCancelledShortCircuitCaptureNeverResetsANewerCapture() {
        let state = AppState()
        state.sessionState = .recording
        state.recordingDuration = 2.5

        AppCoordinator.finishShortCircuitCapture(state, taskCancelled: true)

        XCTAssertEqual(state.sessionState, .recording)
        XCTAssertEqual(state.recordingDuration, 2.5)
    }

    @MainActor
    func testCompletedShortCircuitCaptureReturnsToIdle() {
        let state = AppState()
        state.sessionState = .inserting
        state.recordingDuration = 2.5

        AppCoordinator.finishShortCircuitCapture(state, taskCancelled: false)

        XCTAssertEqual(state.sessionState, .idle)
        XCTAssertEqual(state.recordingDuration, 0)
    }

    func testGenuineNetworkErrorsAreNotCancellation() {
        XCTAssertFalse(AppCoordinator.isUserCancellation(URLError(.timedOut)))
        XCTAssertFalse(AppCoordinator.isUserCancellation(URLError(.cannotConnectToHost)))
        XCTAssertFalse(AppCoordinator.isUserCancellation(AudioCaptureError.deviceChanged))
    }

    /// Session 29: a mid-capture device change used to discard the whole
    /// dictation with only a transient status line — no insertions.jsonl
    /// receipt, so the loss mode was invisible in the forensics log. The
    /// classifier maps it to an audit reason; quiet cancels and generic
    /// errors stay receipt-less (cancels are deliberate, generic errors
    /// already surface loudly as .error state).
    func testDeviceChangedMapsToAuditReason() {
        XCTAssertEqual(
            AppCoordinator.captureErrorAuditReason(AudioCaptureError.deviceChanged),
            "device_changed")
    }

    func testCancellationAndGenericErrorsGetNoAuditReason() {
        XCTAssertNil(AppCoordinator.captureErrorAuditReason(CancellationError()))
        XCTAssertNil(AppCoordinator.captureErrorAuditReason(URLError(.cancelled)))
        XCTAssertNil(AppCoordinator.captureErrorAuditReason(URLError(.timedOut)))
        XCTAssertNil(AppCoordinator.captureErrorAuditReason(AudioCaptureError.captureNotRunning))
    }
}
