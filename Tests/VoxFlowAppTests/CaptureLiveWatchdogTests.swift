import XCTest
@testable import VoxFlowApp

/// The "speak now" cue is gated on the first delivered audio buffer. A device
/// that starts but never delivers buffers (wedged CoreAudio, zero-input
/// aggregate device) would leave the user waiting in silence with recording
/// armed until the capture timeout. The watchdog turns that silent hang into
/// a prompt, surfaced failure.
@MainActor
final class CaptureLiveWatchdogTests: XCTestCase {

    func testFiresOnStalledWhenNoBufferArrives() async {
        let watchdog = CaptureLiveWatchdog()
        let stalled = expectation(description: "onStalled fires after the timeout")
        watchdog.arm(timeout: 0.05) { stalled.fulfill() }
        await fulfillment(of: [stalled], timeout: 2.0)
    }

    func testMarkLiveBeforeTimeoutSuppressesStall() async throws {
        let watchdog = CaptureLiveWatchdog()
        var fired = false
        watchdog.arm(timeout: 0.05) { fired = true }
        watchdog.markLive()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fired, "a live buffer must disarm the watchdog")
    }

    func testCancelSuppressesStall() async throws {
        let watchdog = CaptureLiveWatchdog()
        var fired = false
        watchdog.arm(timeout: 0.05) { fired = true }
        watchdog.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(fired, "cancel (capture finished/errored) must disarm")
    }

    func testRearmReplacesPreviousCountdown() async {
        let watchdog = CaptureLiveWatchdog()
        var firstFired = false
        let second = expectation(description: "only the latest arm fires")
        watchdog.arm(timeout: 0.05) { firstFired = true }
        watchdog.arm(timeout: 0.05) { second.fulfill() }
        await fulfillment(of: [second], timeout: 2.0)
        XCTAssertFalse(firstFired, "re-arming must cancel the previous countdown")
    }
}
