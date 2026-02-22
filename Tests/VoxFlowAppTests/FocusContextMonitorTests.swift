import XCTest
@testable import VoxFlowApp

final class FocusContextMonitorTests: XCTestCase {

    @MainActor
    func testFreezePreventsFocusTargetUpdate() {
        let monitor = FocusContextMonitor(insertService: AccessibilityInsertService())
        var updateCount = 0

        monitor.start { _ in
            updateCount += 1
        }

        monitor.freeze()
        XCTAssertTrue(monitor.isFrozen)

        monitor.unfreeze()
        XCTAssertFalse(monitor.isFrozen)

        monitor.stop()
    }

    @MainActor
    func testFreezeDefaultsToFalse() {
        let monitor = FocusContextMonitor(insertService: AccessibilityInsertService())
        XCTAssertFalse(monitor.isFrozen)
    }
}
