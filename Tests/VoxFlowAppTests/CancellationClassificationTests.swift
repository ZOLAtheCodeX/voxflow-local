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

    func testGenuineNetworkErrorsAreNotCancellation() {
        XCTAssertFalse(AppCoordinator.isUserCancellation(URLError(.timedOut)))
        XCTAssertFalse(AppCoordinator.isUserCancellation(URLError(.cannotConnectToHost)))
        XCTAssertFalse(AppCoordinator.isUserCancellation(AudioCaptureError.deviceChanged))
    }
}
